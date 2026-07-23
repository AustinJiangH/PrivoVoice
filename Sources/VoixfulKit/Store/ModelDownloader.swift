// Fetches installable assets into the models directory.
//
// Two install paths:
//   • download(spec:)      — pull every file of the model's Hugging Face repo
//                            (the repo mirrors the `.aimodel` directory) into a
//                            staging dir, then atomically swap it into place.
//   • importLocal(_:from:) — copy an existing local `.aimodel` directory in.
//
// Per-model progress is observable so the Models page can show a bar. Downloads
// are cancellable. `@MainActor` throughout; the network work is `await`ed so the
// main actor is never blocked.

import Foundation
import Observation

/// Install progress for one model. Rendered by the model card.
public enum InstallState: Sendable, Equatable {
    case notInstalled
    case downloading(fraction: Double)   // 0…1, or <0 when total size is unknown
    case installing                      // moving staged files into place
    case installed
    case failed(String)
}

@MainActor
@Observable
public final class ModelDownloader {
    /// Live state per catalog id (absent ⇒ `.notInstalled`).
    public private(set) var states: [String: InstallState] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]
    private let store: ModelStore
    private let settings: AppSettings

    public init(store: ModelStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    public func state(for spec: ModelSpec) -> InstallState {
        if store.isInstalled(spec) { return .installed }
        return states[spec.id] ?? .notInstalled
    }

    public func isBusy(_ spec: ModelSpec) -> Bool {
        switch states[spec.id] {
        case .downloading, .installing: return true
        default: return false
        }
    }

    public func cancel(_ spec: ModelSpec) {
        tasks[spec.id]?.cancel()
        tasks[spec.id] = nil
        states[spec.id] = .notInstalled
    }

    /// Kick off a download for `spec`. No-op if already installed or in flight.
    public func download(_ spec: ModelSpec) {
        guard !store.isInstalled(spec), tasks[spec.id] == nil else { return }
        guard let source = spec.download else {
            states[spec.id] = .failed("No download source — install by importing a local .aimodel.")
            return
        }
        states[spec.id] = .downloading(fraction: -1)
        let task = Task { @MainActor in
            defer { self.tasks[spec.id] = nil }
            do {
                switch source {
                case let .huggingFace(repo, revision):
                    try await self.downloadHuggingFace(spec: spec, repo: repo, revision: revision)
                }
                self.states[spec.id] = .installed
                self.store.refresh()
            } catch is CancellationError {
                self.states[spec.id] = .notInstalled
            } catch {
                self.states[spec.id] = .failed(Self.friendly(error))
            }
        }
        tasks[spec.id] = task
    }

    /// Install by copying a local `.aimodel` directory into the models dir.
    public func importLocal(_ spec: ModelSpec, from source: URL) {
        guard tasks[spec.id] == nil else { return }
        states[spec.id] = .installing
        let task = Task { @MainActor in
            defer { self.tasks[spec.id] = nil }
            do {
                let dest = self.store.installURL(for: spec)
                let fm = FileManager.default
                try fm.createDirectory(at: self.settings.modelsDirectory, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: source, to: dest)
                self.states[spec.id] = .installed
                self.store.refresh()
            } catch {
                self.states[spec.id] = .failed(Self.friendly(error))
            }
        }
        tasks[spec.id] = task
    }

    // MARK: Hugging Face

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    private func downloadHuggingFace(spec: ModelSpec, repo: String, revision: String) async throws {
        let fm = FileManager.default
        // 1. List the repo tree.
        let treeURL = URL(string:
            "https://huggingface.co/api/models/\(repo)/tree/\(revision)?recursive=true")!
        let (treeData, treeResp) = try await URLSession.shared.data(from: treeURL)
        guard let http = treeResp as? HTTPURLResponse else {
            throw DownloadError.message("No response from Hugging Face.")
        }
        if http.statusCode == 404 {
            throw DownloadError.message(
                "Not yet published on Hugging Face (\(repo)). Import a converted .aimodel instead.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.message("Hugging Face returned HTTP \(http.statusCode).")
        }
        let entries = try JSONDecoder().decode([TreeEntry].self, from: treeData)
        let files = entries.filter { $0.type == "file" }
        guard !files.isEmpty else {
            throw DownloadError.message("Repo \(repo) has no files.")
        }
        let totalBytes = files.compactMap(\.size).reduce(0, +)

        // 2. Stage into a sibling temp dir, then swap into place atomically.
        let dest = store.installURL(for: spec)
        let staging = settings.modelsDirectory
            .appending(path: spec.assetName + ".partial", directoryHint: .isDirectory)
        try fm.createDirectory(at: settings.modelsDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var downloaded: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let fileURL = URL(string:
                "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
            let (tmp, resp) = try await URLSession.shared.download(from: fileURL)
            guard let fh = resp as? HTTPURLResponse, (200..<300).contains(fh.statusCode) else {
                throw DownloadError.message("Failed to download \(file.path).")
            }
            let target = staging.appending(path: file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: tmp, to: target)

            downloaded += file.size ?? 0
            states[spec.id] = totalBytes > 0
                ? .downloading(fraction: Double(downloaded) / Double(totalBytes))
                : .downloading(fraction: -1)
        }

        // 3. Swap staging → final.
        states[spec.id] = .installing
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: staging, to: dest)
    }

    private enum DownloadError: Error { case message(String) }

    private static func friendly(_ error: Error) -> String {
        if case DownloadError.message(let m) = error { return m }
        return (error as NSError).localizedDescription
    }
}
