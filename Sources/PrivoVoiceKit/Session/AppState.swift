// The global dictation state — one observable source of truth the whole app
// (sidebar, HUD, menu bar) reads from.

import Foundation
import Observation

/// What the app is doing right now. Drives every status surface.
public enum DictationPhase: String, Sendable, Hashable {
    /// Not dictating.
    case idle
    /// Mic is live and capturing (push-to-talk held).
    case listening
    /// Key released; finalizing the transcript.
    case transcribing

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        }
    }

    public var isActive: Bool { self != .idle }
}

@MainActor
@Observable
public final class AppState {
    /// Current phase — the value every status surface renders from.
    public private(set) var phase: DictationPhase = .idle
    /// Live input amplitude, 0…1, for the HUD level meter (valid while listening).
    public private(set) var level: Float = 0
    /// The evolving partial transcript while a session runs.
    public private(set) var partialText: String = ""
    /// The most recently completed transcript (what got pasted).
    public private(set) var lastTranscript: String = ""
    /// A user-facing error from the last session, if any.
    public var lastError: String?

    /// When the current recording started (set on `.listening`, cleared on reset).
    /// The HUD derives elapsed/remaining time from this via a timeline.
    public private(set) var recordingStartDate: Date?
    /// The active model's single-pass audio limit in seconds, or `nil` for an
    /// unbounded streaming model. Drives the HUD countdown "lens".
    public private(set) var recordingLimitSeconds: Double?

    /// The global push-to-talk hotkey is registered with the system.
    public private(set) var hotkeyActive = false
    /// Accessibility is granted — needed only to paste the transcript.
    public private(set) var pasteAuthorized = false

    public init() {}

    public func setHotkeyActive(_ v: Bool) { hotkeyActive = v }
    public func setPasteAuthorized(_ v: Bool) { pasteAuthorized = v }

    // Mutators are funnelled through the controller; kept internal to the module.
    func setPhase(_ p: DictationPhase) { phase = p }
    func setLevel(_ l: Float) { level = l }
    func setPartial(_ t: String) { partialText = t }
    func commitTranscript(_ t: String) { lastTranscript = t; partialText = "" }
    /// Start the recording clock at "now" for a model whose single-pass limit is
    /// `limitSeconds` (nil ⇒ unbounded streaming).
    func startRecordingClock(limitSeconds: Double?) {
        recordingStartDate = Date()
        recordingLimitSeconds = limitSeconds
    }
    func reset() {
        level = 0; partialText = ""
        recordingStartDate = nil
        recordingLimitSeconds = nil
    }

    #if DEBUG
    /// Seed an `AppState` in a specific state for SwiftUI previews and snapshot
    /// tests. `elapsed` backdates the recording clock so the HUD lens renders as
    /// if we've been recording that long.
    public static func preview(
        phase: DictationPhase = .listening,
        level: Float = 0.5,
        partialText: String = "",
        elapsed: TimeInterval = 0,
        limitSeconds: Double? = nil
    ) -> AppState {
        let state = AppState()
        state.phase = phase
        state.level = level
        state.partialText = partialText
        state.recordingStartDate = Date().addingTimeInterval(-elapsed)
        state.recordingLimitSeconds = limitSeconds
        return state
    }
    #endif
}
