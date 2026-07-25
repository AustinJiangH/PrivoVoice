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
    /// Insert a single leading space before each delivered transcript so
    /// back-to-back dictations don't run together (some models omit boundary
    /// whitespace). Default on.
    public var autoSpacing: Bool {
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
    /// Opt-in: share anonymous aggregate usage (counts + device metadata) with
    /// the collector. OFF by default — the local Dashboard works regardless, and
    /// nothing is ever sent while this is false. Never includes transcript text.
    public var telemetryEnabled: Bool {
        didSet { scheduleSave() }
    }
    /// Show the growing live transcript in the floating HUD while dictating. When
    /// off, the HUD is just the small amplitude + timer pill. Default on.
    public var showLiveTranscription: Bool {
        didSet { scheduleSave() }
    }
    /// Whether the first-run onboarding flow has been completed (or skipped). Once
    /// true the flow never shows again. Default false so a fresh install onboards.
    public var hasCompletedOnboarding: Bool {
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
            self.autoSpacing = persisted.autoSpacing ?? true
            self.hotkey = persisted.hotkey ?? .defaultCombo
            self.localeIdentifier = persisted.localeIdentifier ?? "en-US"
            self.huggingFaceToken = persisted.huggingFaceToken
            self.telemetryEnabled = persisted.telemetryEnabled ?? false
            self.showLiveTranscription = persisted.showLiveTranscription ?? true
            self.hasCompletedOnboarding = persisted.hasCompletedOnboarding ?? false
        } else {
            self.modelsDirectory = Self.defaultModelsDirectory
            self.selectedModelID = nil
            self.autoCopy = true
            self.autoSpacing = true
            self.hotkey = .defaultCombo
            self.localeIdentifier = "en-US"
            self.huggingFaceToken = nil
            self.telemetryEnabled = false
            self.showLiveTranscription = true
            self.hasCompletedOnboarding = false
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
            autoSpacing: autoSpacing,
            hotkey: hotkey,
            localeIdentifier: localeIdentifier,
            huggingFaceToken: huggingFaceToken,
            telemetryEnabled: telemetryEnabled,
            showLiveTranscription: showLiveTranscription,
            hasCompletedOnboarding: hasCompletedOnboarding
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
        var autoSpacing: Bool?
        var hotkey: KeyCombo?
        var localeIdentifier: String?
        var huggingFaceToken: String?
        var telemetryEnabled: Bool?
        var showLiveTranscription: Bool?
        var hasCompletedOnboarding: Bool?

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
