// Install lifecycle for the transcript-formatter model — download from Hugging
// Face, detect installed-ness, remove. Observable so the Settings pane and
// onboarding can render a progress bar directly.
//
// The heavy lifting (snapshot download, deletes) runs off the main actor; only
// the observable `phase` mutations hop back.

import Foundation
import Hub
import Observation

@MainActor
@Observable
public final class FormatterStore {
    /// The app-wide store, rooted at `~/Library/PrivoVoice/Formatters`.
    public static let shared = FormatterStore()

    /// Install state of the (single) formatter model.
    public enum Phase: Equatable {
        case notInstalled
        case downloading(Double)   // 0…1 fractional progress
        case installed
        case failed(String)
    }

    public private(set) var phase: Phase

    public var isInstalled: Bool { phase == .installed }
    public var displayName: String { FormatterCatalog.displayName }
    public var approxSizeDescription: String { FormatterCatalog.approxSizeDescription }

    /// Supplies a Hugging Face token for the download (the repo is public, so
    /// this is only needed behind proxies/quotas). The app wires this to
    /// `AppSettings.huggingFaceToken`; standard env vars are the fallback so
    /// `HF_TOKEN=… swift run` works too.
    public var tokenProvider: () -> String? = { nil }

    /// Where the model snapshot lives once installed (config.json + weights).
    public let installDirectory: URL

    private var downloadTask: Task<Void, Never>?
    /// Monotonic id of the current download attempt. Every completion hop
    /// (progress, success, failure) carries the generation it belongs to and
    /// no-ops when stale — a cancelled attempt's late callbacks must never
    /// clobber a newer download's (or a remove()'s) state.
    private var downloadGeneration = 0

    /// `~/Library/PrivoVoice/Formatters` — sibling of the Models directory.
    public static var defaultRootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/PrivoVoice/Formatters", directoryHint: .isDirectory)
    }

    public init(rootDirectory: URL = FormatterStore.defaultRootDirectory) {
        self.installDirectory = rootDirectory
            .appending(path: FormatterCatalog.installSlug, directoryHint: .isDirectory)
        self.phase = Self.looksInstalled(at: installDirectory) ? .installed : .notInstalled
        // A crash mid-download strands a ~1 GB `<slug>.partial-<gen>` staging
        // directory. Enumerate orphans NOW (cheap; no download can be running
        // yet) and delete them in the background — capturing the list up front
        // means the detached delete can't race a download() started later.
        let orphans = Self.stagingOrphans(root: rootDirectory)
        if !orphans.isEmpty {
            Task.detached(priority: .utility) {
                for url in orphans { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    // MARK: Download

    /// Kick off (or resume after a failure) the model download. Idempotent: a
    /// no-op while a download is in flight or once installed.
    public func download() {
        switch phase {
        case .downloading, .installed: return
        case .notInstalled, .failed: break
        }
        let generation = beginDownload()

        let dest = installDirectory
        // The Hub snapshot lays files out as <base>/models/<repo>/…; stage under
        // a sibling ".partial-<generation>" dir, then move the snapshot into
        // place so a failed download never leaves a half-installed model. The
        // staging dir is per-generation so a cancelled attempt's cleanup can
        // never delete a newer attempt's files.
        let staging = Self.stagingDirectory(
            root: installDirectory.deletingLastPathComponent(), generation: generation)
        let token = effectiveToken()

        downloadTask = Task.detached(priority: .utility) { [weak self] in
            let fm = FileManager.default
            do {
                let hub = HubApi(downloadBase: staging, hfToken: token)
                let snapshot = try await hub.snapshot(
                    from: Hub.Repo(id: FormatterCatalog.repoID),
                    revision: FormatterCatalog.revision,
                    matching: FormatterCatalog.filePatterns
                ) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        self?.downloadDidProgress(fraction, generation: generation)
                    }
                }
                // NB: on cooperative cancellation (remove(), or a superseding
                // download) HubApi.snapshot RETURNS the partial directory
                // instead of throwing — and a partial can even pass
                // `looksInstalled`. Never move anything into place for a
                // cancelled attempt.
                try Task.checkCancellation()
                guard Self.looksInstalled(at: snapshot) else {
                    throw FormatterStoreError.incompleteSnapshot
                }
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: snapshot, to: dest)
                try? fm.removeItem(at: staging)
                await MainActor.run { [weak self] in
                    self?.downloadDidSucceed(generation: generation)
                }
            } catch {
                try? fm.removeItem(at: staging)
                let message = (error as? FormatterStoreError)?.description
                    ?? (error as NSError).localizedDescription
                await MainActor.run { [weak self] in
                    self?.downloadDidFail(message, generation: generation)
                }
            }
        }
    }

    /// Delete the installed model (and abort any in-flight download).
    public func remove() {
        downloadTask?.cancel()
        downloadTask = nil
        // Stale-ify any late callbacks from the cancelled attempt.
        downloadGeneration += 1
        phase = .notInstalled
        let dir = installDirectory
        // Enumerate staging orphans NOW so the detached delete can't race a
        // fresh download() (whose staging dir doesn't exist yet, so it can't
        // be in this list).
        let orphans = Self.stagingOrphans(root: dir.deletingLastPathComponent())
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: dir)
            for url in orphans { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Download state machine (internal so tests can drive it directly)

    /// Enter `.downloading` under a fresh generation; returns the generation
    /// the spawned task must tag its completion hops with.
    func beginDownload() -> Int {
        downloadGeneration += 1
        phase = .downloading(0)
        return downloadGeneration
    }

    /// Progress hop: only advances while THIS generation is still the current
    /// download (a concurrent remove() or a superseding download must not be
    /// overwritten by a late callback).
    func downloadDidProgress(_ fraction: Double, generation: Int) {
        guard generation == downloadGeneration else { return }
        if case .downloading = phase { phase = .downloading(fraction) }
    }

    /// Success hop — the snapshot was verified and moved into place.
    func downloadDidSucceed(generation: Int) {
        guard generation == downloadGeneration else { return }
        guard case .downloading = phase else { return }
        phase = .installed
        downloadTask = nil
    }

    /// Failure hop. A cancelled attempt (remove()) also lands here via
    /// `CancellationError`; the generation/phase guards keep it a no-op.
    func downloadDidFail(_ message: String, generation: Int) {
        guard generation == downloadGeneration else { return }
        guard case .downloading = phase else { return }
        phase = .failed(message)
        downloadTask = nil
    }

    // MARK: Helpers

    /// The token from the injected provider, else the standard env vars.
    private func effectiveToken() -> String? {
        if let t = tokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        let env = ProcessInfo.processInfo.environment
        return env["HF_TOKEN"] ?? env["HUGGING_FACE_HUB_TOKEN"]
    }

    /// Where download attempt `generation` stages its snapshot before the
    /// atomic move into place. Per-generation so attempts can never collide.
    nonisolated static func stagingDirectory(root: URL, generation: Int) -> URL {
        root.appending(path: FormatterCatalog.installSlug + ".partial-\(generation)",
                       directoryHint: .isDirectory)
    }

    /// Every `<slug>.partial*` staging directory under `root` — orphans from
    /// crashed or superseded download attempts (also matches the un-numbered
    /// `.partial` dir older builds staged into).
    nonisolated static func stagingOrphans(root: URL) -> [URL] {
        let prefix = FormatterCatalog.installSlug + ".partial"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }
            .map { root.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// A directory is an installed model iff it has a config, weights, AND the
    /// tokenizer. The tokenizer requirement closes a real gap: a cancelled
    /// HubApi snapshot returns a PARTIAL directory (config + weights download
    /// first) that would otherwise pass and then fail at first format.
    /// Keep this list in sync with `FormatterCatalog.filePatterns`.
    nonisolated static func looksInstalled(at directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appending(path: "config.json").path),
              fm.fileExists(atPath: directory.appending(path: "tokenizer.json").path) else {
            return false
        }
        let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    private enum FormatterStoreError: Error, CustomStringConvertible {
        case incompleteSnapshot
        var description: String {
            "The download finished but the model files are incomplete — try again."
        }
    }
}
