// User settings, persisted as JSON under Application Support.
//
// `@Observable` so SwiftUI views bind directly; every mutation writes through to
// disk on the next runloop tick (debounced). Kept in PrivoVoiceKit (not the app
// target) so the same settings model is reusable on iOS.

import Foundation
import Observation

@MainActor
@Observable
public final class AppSettings {
    /// Where downloaded/imported `.aimodel` assets live. User-changeable.
    public var modelsDirectory: URL {
        didSet { scheduleSave() }
    }
    /// The catalog id of the model to dictate with (`nil` until one is chosen).
    public var selectedModelID: String? {
        didSet { scheduleSave() }
    }
    /// Copy the finished transcript to the clipboard automatically.
    public var autoCopy: Bool {
        didSet { scheduleSave() }
    }
    /// Push-to-talk hotkey.
    public var hotkey: KeyCombo {
        didSet { scheduleSave() }
    }
    /// BCP-47 locale to request from the transcriber.
    public var localeIdentifier: String {
        didSet { scheduleSave() }
    }
    /// Optional Hugging Face access token for gated/private model repos.
    public var huggingFaceToken: String? {
        didSet { scheduleSave() }
    }

    private var saveScheduled = false
    private let storeURL: URL

    // MARK: Defaults

    /// `~/Library/PrivoVoice/Models` — the documented default install location.
    public static var defaultModelsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "Library/PrivoVoice/Models", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/PrivoVoice/settings.json`.
    public static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "PrivoVoice/settings.json")
    }

    // MARK: Init / persistence

    public init(storeURL: URL = AppSettings.defaultStoreURL) {
        self.storeURL = storeURL
        if let persisted = try? Persisted.load(from: storeURL) {
            self.modelsDirectory = persisted.modelsDirectory ?? Self.defaultModelsDirectory
            self.selectedModelID = persisted.selectedModelID
            self.autoCopy = persisted.autoCopy ?? true
            self.hotkey = persisted.hotkey ?? .defaultCombo
            self.localeIdentifier = persisted.localeIdentifier ?? "en-US"
            self.huggingFaceToken = persisted.huggingFaceToken
        } else {
            self.modelsDirectory = Self.defaultModelsDirectory
            self.selectedModelID = nil
            self.autoCopy = true
            self.hotkey = .defaultCombo
            self.localeIdentifier = "en-US"
            self.huggingFaceToken = nil
        }

        // Guard against an unsafe shortcut (e.g. a bare key from an older build)
        // that the consuming tap would swallow system-wide. Property observers
        // don't fire during init, so persist explicitly.
        if !hotkey.isValidGlobalShortcut {
            hotkey = .defaultCombo
            saveNow()
        }
    }

    /// Coalesce rapid mutations into one write on the next runloop tick.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor in
            self.saveScheduled = false
            self.saveNow()
        }
    }

    public func saveNow() {
        let snapshot = Persisted(
            modelsDirectory: modelsDirectory,
            selectedModelID: selectedModelID,
            autoCopy: autoCopy,
            hotkey: hotkey,
            localeIdentifier: localeIdentifier,
            huggingFaceToken: huggingFaceToken
        )
        try? snapshot.save(to: storeURL)
    }

    // MARK: On-disk shape

    /// Every field optional so adding new settings never fails to decode an old
    /// file (forward/backward compatible).
    struct Persisted: Codable {
        var modelsDirectory: URL?
        var selectedModelID: String?
        var autoCopy: Bool?
        var hotkey: KeyCombo?
        var localeIdentifier: String?
        var huggingFaceToken: String?

        static func load(from url: URL) throws -> Persisted {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Persisted.self, from: data)
        }

        func save(to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }
}
