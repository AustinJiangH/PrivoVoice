// User settings, persisted as JSON under Application Support.
//
// `@Observable` so SwiftUI views bind directly; every mutation writes through to
// disk on the next runloop tick (debounced). Kept in PrivoVoiceKit (not the app
// target) so the same settings model is reusable on iOS.

import Foundation
import Observation

/// Where the floating live-transcript panel sits on screen.
public enum TranscriptPosition: String, Sendable, Codable, CaseIterable {
    /// Just under the menu bar / notch.
    case top
    /// Just above the Dock.
    case bottom
}

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
    /// Push-to-talk hotkey: hold to record, release to transcribe.
    public var hotkey: KeyCombo {
        didSet { scheduleSave() }
    }
    /// Toggle-recording hotkey: press once to start, again to stop. Optional
    /// (empty by default) and must not conflict with `hotkey`.
    public var toggleHotkey: KeyCombo {
        didSet { scheduleSave() }
    }
    /// Mouse button or button chord for push-to-talk (hold to record).
    /// Optional.
    public var mousePushToTalkButton: MouseChord? {
        didSet { scheduleSave() }
    }
    /// Mouse button or button chord that toggles recording on/off. Optional;
    /// must not overlap `mousePushToTalkButton` (see `MouseChord.conflicts`).
    public var mouseToggleButton: MouseChord? {
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
    /// Post-process the final transcript through the on-device formatter LLM
    /// (punctuation, casing, obvious mis-hearings, spoken enumerations →
    /// lists). OFF by default; only takes effect once the formatter model is
    /// installed (see `FormatterStore`).
    public var formatFinalTranscript: Bool {
        didSet { scheduleSave() }
    }
    /// Formatter capability: strip filler words and stutters (um, uh, ah, er).
    /// Default on; only meaningful while `formatFinalTranscript` is on.
    public var formatterRemovesFillers: Bool {
        didSet { scheduleSave() }
    }
    /// Formatter capability: render spoken enumerations as lists. Default on.
    public var formatterFormatsLists: Bool {
        didSet { scheduleSave() }
    }
    /// Formatter capability: apply verbal self-corrections ("monday no wait
    /// tuesday" → "Tuesday"). Default on.
    public var formatterAppliesCorrections: Bool {
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
    /// Where the live-transcript panel appears (the recording status always
    /// sits in the notch). Default top.
    public var transcriptPosition: TranscriptPosition {
        didSet { scheduleSave() }
    }
    /// Whether the first-run onboarding flow has been completed (or skipped). Once
    /// true the flow never shows again. Default false so a fresh install onboards.
    public var hasCompletedOnboarding: Bool {
        didSet { scheduleSave() }
    }

    /// Whether at least one dictation trigger (keyboard or mouse) is bound.
    public var hasAnyTrigger: Bool {
        !hotkey.isEmpty || !toggleHotkey.isEmpty
            || mousePushToTalkButton != nil || mouseToggleButton != nil
    }

    private var saveScheduled = false
    private let storeURL: URL

    // MARK: Defaults

    /// `~/Library/PrivoVoice/Models` — the documented default install location.
    public static var defaultModelsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "Library/PrivoVoice/Models", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/PrivoVoice/settings.json` (`PrivoVoice Dev/` for a dev build).
    public static var defaultStoreURL: URL {
        AppInfo.supportDirectory.appending(path: "settings.json")
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
            self.toggleHotkey = persisted.toggleHotkey ?? .unset
            self.mousePushToTalkButton = persisted.mousePushToTalkButton
            self.mouseToggleButton = persisted.mouseToggleButton
            self.localeIdentifier = persisted.localeIdentifier ?? "en-US"
            self.huggingFaceToken = persisted.huggingFaceToken
            self.formatFinalTranscript = persisted.formatFinalTranscript ?? false
            self.formatterRemovesFillers = persisted.formatterRemovesFillers ?? true
            self.formatterFormatsLists = persisted.formatterFormatsLists ?? true
            self.formatterAppliesCorrections = persisted.formatterAppliesCorrections ?? true
            self.telemetryEnabled = persisted.telemetryEnabled ?? false
            self.showLiveTranscription = persisted.showLiveTranscription ?? true
            self.transcriptPosition = persisted.transcriptPosition ?? .top
            self.hasCompletedOnboarding = persisted.hasCompletedOnboarding ?? false
        } else {
            self.modelsDirectory = Self.defaultModelsDirectory
            self.selectedModelID = nil
            self.autoCopy = true
            self.autoSpacing = true
            self.hotkey = .defaultCombo
            self.toggleHotkey = .unset
            self.mousePushToTalkButton = nil
            self.mouseToggleButton = nil
            self.localeIdentifier = "en-US"
            self.huggingFaceToken = nil
            self.formatFinalTranscript = false
            self.formatterRemovesFillers = true
            self.formatterFormatsLists = true
            self.formatterAppliesCorrections = true
            self.telemetryEnabled = false
            self.showLiveTranscription = true
            self.transcriptPosition = .top
            self.hasCompletedOnboarding = false
        }

        // Guard against an unsafe shortcut (e.g. a bare key from an older build)
        // that the consuming tap would swallow system-wide. Property observers
        // don't fire during init, so persist explicitly. An empty push-to-talk
        // is a deliberate "unset" as long as another trigger is bound; with
        // nothing bound at all there'd be no way to dictate, so restore `fn`.
        var healed = false
        if !hotkey.isEmpty, !hotkey.isValidGlobalShortcut {
            hotkey = .defaultCombo
            healed = true
        }
        // The optional bindings heal to "unset" instead: an unsafe or
        // conflicting toggle chord, a left/right-click mouse binding, or two
        // mouse bindings where one would fire the other.
        if !toggleHotkey.isEmpty,
           !toggleHotkey.isValidGlobalShortcut || toggleHotkey.conflicts(with: hotkey) {
            toggleHotkey = .unset
            healed = true
        }
        if let b = mousePushToTalkButton, !b.isAssignable {
            mousePushToTalkButton = nil
            healed = true
        }
        if let b = mouseToggleButton, !b.isAssignable || b.conflicts(with: mousePushToTalkButton) {
            mouseToggleButton = nil
            healed = true
        }
        if !hasAnyTrigger {
            hotkey = .defaultCombo
            healed = true
        }
        if healed { saveNow() }
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
            toggleHotkey: toggleHotkey,
            mousePushToTalkButton: mousePushToTalkButton,
            mouseToggleButton: mouseToggleButton,
            localeIdentifier: localeIdentifier,
            huggingFaceToken: huggingFaceToken,
            formatFinalTranscript: formatFinalTranscript,
            formatterRemovesFillers: formatterRemovesFillers,
            formatterFormatsLists: formatterFormatsLists,
            formatterAppliesCorrections: formatterAppliesCorrections,
            telemetryEnabled: telemetryEnabled,
            showLiveTranscription: showLiveTranscription,
            transcriptPosition: transcriptPosition,
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
        var toggleHotkey: KeyCombo?
        var mousePushToTalkButton: MouseChord?
        var mouseToggleButton: MouseChord?
        var localeIdentifier: String?
        var huggingFaceToken: String?
        var formatFinalTranscript: Bool?
        var formatterRemovesFillers: Bool?
        var formatterFormatsLists: Bool?
        var formatterAppliesCorrections: Bool?
        var telemetryEnabled: Bool?
        var showLiveTranscription: Bool?
        var transcriptPosition: TranscriptPosition?
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
