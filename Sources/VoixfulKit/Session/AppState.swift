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

    public init() {}

    // Mutators are funnelled through the controller; kept internal to the module.
    func setPhase(_ p: DictationPhase) { phase = p }
    func setLevel(_ l: Float) { level = l }
    func setPartial(_ t: String) { partialText = t }
    func commitTranscript(_ t: String) { lastTranscript = t; partialText = "" }
    func reset() { level = 0; partialText = "" }
}
