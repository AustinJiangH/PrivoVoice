// Builds the right `Transcribing` module for a model, configured for live
// (push-to-talk) dictation. This is the app-side mirror of the CLI's `mic`
// switch: Nemotron streams natively; every full-context backend gets live
// partials via `LiveFullContextTranscriber`.

import Foundation
import VoixfulSpeech
import VoixfulEngine
import VoixfulNemotronStreaming
import VoixfulParakeetTDT
import VoixfulCohereTranscribe
import VoixfulGraniteNAR
import VoixfulCanaryQwen
import VoixfulFullContext

public enum TranscriberFactory {
    /// Construct a live-dictation transcriber for an installed `.aimodel`.
    ///
    /// - Parameters:
    ///   - modelURL: the installed `.aimodel` directory.
    ///   - backend: the model's backend (from the catalog; the engine still
    ///     validates against the asset on load).
    ///   - locale: BCP-47 locale to request.
    public static func makeLive(
        modelURL: URL, backend: ModelBackend, locale: Locale
    ) throws -> any Transcribing {
        // Full-context backends read a sibling `pieces.txt` bundled in the asset.
        let pieces = modelURL.appending(path: "pieces.txt")
        switch backend {
        case .nemotron:
            return try NemotronStreamingTranscriber(
                modelURL: modelURL, locale: locale, chunkSizeMS: 320,
                mode: .streaming, reportingOptions: [.volatileResults], attributeOptions: [])
        case .parakeet:
            return LiveFullContextTranscriber<ParakeetTDTEngine>(
                modelURL: modelURL, piecesURL: pieces, locale: locale)
        case .cohere:
            return LiveFullContextTranscriber<CohereTranscribeEngine>(
                modelURL: modelURL, piecesURL: pieces, locale: locale)
        case .granite:
            return LiveFullContextTranscriber<GraniteNAREngine>(
                modelURL: modelURL, piecesURL: pieces, locale: locale)
        case .canary:
            return LiveFullContextTranscriber<CanaryQwenEngine>(
                modelURL: modelURL, piecesURL: pieces, locale: locale)
        }
    }
}
