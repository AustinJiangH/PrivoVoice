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

    /// `~/Library/PrivoVoice/Formatters` — sibling of the Models directory.
    public static var defaultRootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/PrivoVoice/Formatters", directoryHint: .isDirectory)
    }

    public init(rootDirectory: URL = FormatterStore.defaultRootDirectory) {
        self.installDirectory = rootDirectory
            .appending(path: FormatterCatalog.installSlug, directoryHint: .isDirectory)
        self.phase = Self.looksInstalled(at: installDirectory) ? .installed : .notInstalled
    }

    // MARK: Download

    /// Kick off (or resume after a failure) the model download. Idempotent: a
    /// no-op while a download is in flight or once installed.
    public func download() {
        switch phase {
        case .downloading, .installed: return
        case .notInstalled, .failed: break
        }
        phase = .downloading(0)

        let dest = installDirectory
        // The Hub snapshot lays files out as <base>/models/<repo>/…; stage under
        // a sibling ".partial" dir, then move the snapshot into place so a
        // failed download never leaves a half-installed model.
        let staging = installDirectory.deletingLastPathComponent()
            .appending(path: FormatterCatalog.installSlug + ".partial", directoryHint: .isDirectory)
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
                        // Only advance while still downloading (a concurrent
                        // remove() must not be overwritten by a late callback).
                        if case .downloading = self?.phase { self?.phase = .downloading(fraction) }
                    }
                }
                guard Self.looksInstalled(at: snapshot) else {
                    throw FormatterStoreError.incompleteSnapshot
                }
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: snapshot, to: dest)
                try? fm.removeItem(at: staging)
                await MainActor.run { [weak self] in
                    self?.phase = .installed
                    self?.downloadTask = nil
                }
            } catch {
                try? fm.removeItem(at: staging)
                let message = (error as? FormatterStoreError)?.description
                    ?? (error as NSError).localizedDescription
                await MainActor.run { [weak self] in
                    // remove() during a download cancels the task; stay removed.
                    if case .downloading = self?.phase { self?.phase = .failed(message) }
                    self?.downloadTask = nil
                }
            }
        }
    }

    /// Delete the installed model (and abort any in-flight download).
    public func remove() {
        downloadTask?.cancel()
        downloadTask = nil
        phase = .notInstalled
        let dir = installDirectory
        let staging = dir.deletingLastPathComponent()
            .appending(path: FormatterCatalog.installSlug + ".partial", directoryHint: .isDirectory)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: staging)
        }
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

    /// A directory is an installed model iff it has a config plus weights.
    nonisolated static func looksInstalled(at directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appending(path: "config.json").path) else {
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
