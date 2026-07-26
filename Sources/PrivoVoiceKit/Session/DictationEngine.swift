// The transcription backend, abstracted so the dictation session doesn't care
// whether it runs in-process or in a separate sidecar process.
//
//   • InProcessDictationEngine   — drives VoixfulAnalyzer directly. Portable
//     (iOS, or a single-process macOS build).
//   • HelperProcessDictationEngine (app target) — forwards to the engine sidecar
//     over IPC, for crash isolation of the Core AI model runtime.
//
// The dictation session feeds mono Float32 audio and reads back partial/final
// transcripts, identically for both.

import Foundation
import VoixfulEngine

/// Sample format of the audio stream handed to an engine (`begin`-constant).
public struct AudioStreamFormat: Sendable, Codable, Equatable {
    public var sampleRate: Double
    public var channels: Int
    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public protocol DictationEngine: Sendable {
    /// Begin an utterance: load/prepare the model and start accepting audio.
    /// Partials are delivered via `onPartial`. Should return promptly — a slow
    /// model cold-start happens in the background and surfaces at `end()`.
    func begin(
        modelURL: URL,
        backend: ModelBackend,
        locale: Locale,
        format: AudioStreamFormat,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws

    /// Feed a chunk of mono Float32 audio at the `begin` sample rate.
    func feed(_ samples: [Float]) async

    /// Stop and finalize; returns the committed transcript.
    func end() async throws -> String

    /// Abort without finalizing.
    func cancel() async

    /// Clean up a final transcript with the formatter model installed at
    /// `modelPath`, applying the enabled capabilities (see
    /// `TranscriptFormatter`). Runs wherever the engine runs, so in the
    /// two-process app the LLM stays inside the sidecar.
    func format(text: String, modelPath: String, options: FormatterOptions) async throws -> String

    /// Best-effort: proactively load the formatter model at `modelPath` (and
    /// warm its kernels/prompt cache, anchored for `options` so the user's
    /// actual toggles don't re-anchor on the first real format) so the first
    /// `format` after app launch doesn't pay the ~2 s cold model load. Never
    /// throws — a failed warm-up just means the first format is cold, as
    /// before. Callers should treat it as fire-and-forget (wrap in a `Task`),
    /// and only send it at quiet moments (startup, setting/install changes) —
    /// never per-dictation.
    func warmFormatter(modelPath: String, options: FormatterOptions) async

    /// Drop the resident formatter model (the ~1 GB counterpart of
    /// `warmFormatter`) — sent when formatting turns off or the model is
    /// removed. Best-effort and a no-op when nothing is resident.
    func unloadFormatter() async
}

public extension DictationEngine {
    /// Formatting is optional; engines (and test fakes) that don't support it
    /// pass the transcript through unchanged.
    func format(text: String, modelPath: String, options: FormatterOptions) async throws -> String {
        text
    }

    /// Warm-up is optional; engines that don't format ignore it.
    func warmFormatter(modelPath: String, options: FormatterOptions) async {}

    /// Unload is optional; engines that don't format have nothing resident.
    func unloadFormatter() async {}
}
