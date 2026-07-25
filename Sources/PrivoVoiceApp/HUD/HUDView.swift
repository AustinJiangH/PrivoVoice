// The floating HUD, redesigned in Liquid Glass.
//
// Two stacked glass panes:
//   • a status capsule with a circular countdown "lens" (time remaining until the
//     current model's single-pass limit), an amplitude meter, and a live label —
//     the lens turns RED with a warning under 10s left, and flashes a "N min"
//     reminder at each minute mark. Streaming models (no limit) show a count-up
//     with an indeterminate spinner instead.
//   • a larger box below that animates the live transcript as it forms.
// A subtle shimmer sweeps both panes while active. No hard limit is imposed —
// past the model's window we keep recording and flag that it will be segmented.

import SwiftUI
import PrivoVoiceKit

struct HUDView: View {
    @Bindable var appState: AppState
    @Bindable var settings: AppSettings

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                StatusCapsule(appState: appState)
                // The live transcript is opt-out (Settings → "Show live
                // transcription"). Off ⇒ just the small amplitude + timer pill.
                if settings.showLiveTranscription {
                    TranscriptBox(appState: appState)
                }
            }
        }
        .padding(14)
        // Fixed width, height driven by content (the transcript box grows with
        // its line count). Top-anchored in the panel's transparent canvas so the
        // HUD sits just under the menu bar and the empty space below is invisible.
        .frame(width: 400, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.28), value: appState.phase)
    }
}

// MARK: - Status capsule

private struct StatusCapsule: View {
    @Bindable var appState: AppState

    var body: some View {
        // Tick ~15×/s while listening so the lens/clock stay live; paused otherwise.
        TimelineView(.animation(minimumInterval: 1.0 / 15.0,
                                paused: appState.phase != .listening)) { context in
            let progress = RecordingProgress(start: appState.recordingStartDate,
                                             limit: appState.recordingLimitSeconds,
                                             now: context.date)
            HStack(spacing: 7) {
                if appState.phase == .transcribing {
                    TranscribingIndicator(tint: AppTheme.progress)
                    Text("Transcribing…")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    // A deliberately tiny single-line pill: amplitude + how long
                    // we've been recording. The transcript box below holds the words.
                    AmplitudeMeter(level: appState.level, tint: progress.tint)
                    Text(progress.centerText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(progress.tint)
                    if let text = progress.secondaryText {
                        Text(text)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(progress.secondaryColor)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            // Shimmer BEHIND the content (on the glass), never over the text —
            // an overlay here drew the sweep across the glyphs and made them
            // look rough/streaky.
            .background { Shimmer(active: appState.phase.isActive).clipShape(.capsule) }
            .glassEffect(.regular.tint(progress.tint.opacity(0.16)), in: .capsule)
            .fixedSize()   // hug content → a small centered pill, not full width
            .animation(.easeInOut(duration: 0.2), value: progress.secondaryText)
        }
    }
}

// MARK: - Transcript box

private struct TranscriptBox: View {
    @Bindable var appState: AppState

    private var isEmpty: Bool { appState.partialText.isEmpty }
    private var displayText: String { isEmpty ? placeholder : appState.partialText }

    var body: some View {
        // A SINGLE Text (not an if/else that swaps views): swapping views made
        // the incoming transcript lay out at its ideal 2-line size for a frame
        // before settling to one line — the "shows two lines then shrinks" jump.
        // No .contentTransition here either (it's for morphing glyphs like
        // numbers, and reflows wrapped captions). Height still animates smoothly.
        Text(displayText)
            .font(.system(size: 15, weight: .regular, design: .rounded))
            .foregroundStyle(isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(8)                    // grows with the text, up to a cap
            .truncationMode(.head)           // keep the latest words visible
            .frame(maxWidth: .infinity, alignment: isEmpty ? .center : .topLeading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // No fixed/minimum height — start at one line and grow as text wraps.
            .fixedSize(horizontal: false, vertical: true)
            // Shimmer behind the text (on the glass), not over it — keeps the
            // transcript crisp instead of washing the sweep across the glyphs.
            .background { Shimmer(active: appState.phase.isActive).clipShape(.rect(cornerRadius: 22)) }
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .animation(.smooth(duration: 0.25), value: appState.partialText)
    }

    private var placeholder: String {
        appState.phase == .transcribing ? "Transcribing…" : "Listening… speak now"
    }
}

// MARK: - Shared bits

/// A soft highlight that sweeps left→right, giving the glass a living sheen.
private struct Shimmer: View {
    let active: Bool

    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = (t.truncatingRemainder(dividingBy: 2.4)) / 2.4   // 0…1 loop
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.10), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: (CGFloat(phase) * 1.8 - 0.4) * geo.size.width)
                    // No .blendMode here: a non-normal blend promotes this box to
                    // an offscreen compositing group, which rasterizes the
                    // transcript text and makes it look unsmoothed. Plain alpha
                    // blending keeps the glyphs crisply live-rendered.
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// A row of bars whose heights track the live input amplitude, with a little
/// idle jitter so it always feels alive.
private struct AmplitudeMeter: View {
    let level: Float
    let tint: Color
    private let bars = 11

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: 2.5, height: barHeight(i, t: t))
                }
            }
            .frame(height: 16)   // small, single-line
        }
    }

    private func barHeight(_ i: Int, t: TimeInterval) -> CGFloat {
        let center = Double(bars - 1) / 2
        let dist = abs(Double(i) - center) / center
        let envelope = 1.0 - dist * 0.6
        let wobble = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 6 + Double(i)))
        let amp = Double(max(0.05, min(1, level)))
        let h = 2 + 12 * amp * envelope * wobble
        return CGFloat(h)
    }
}

/// Three dots cycling while the final transcript is being produced.
private struct TranscribingIndicator: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 2
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * (0.5 + 0.5 * sin(phase - Double(i) * 0.6)))
                }
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
@MainActor private func hudPreview(_ appState: AppState, showTranscript: Bool = true) -> some View {
    let settings = AppSettings(storeURL: FileManager.default.temporaryDirectory
        .appending(path: "hud-preview-\(UUID().uuidString)/settings.json"))
    settings.showLiveTranscription = showTranscript
    return HUDView(appState: appState, settings: settings)
        .padding(40)
        .background(.black.gradient)   // a stand-in desktop so the glass reads
}

#Preview("Listening · short") {
    hudPreview(.preview(
        phase: .listening, partialText: "Add milk and eggs to the shopping list",
        elapsed: 12, limitSeconds: 1440))
}

#Preview("Listening · long text (grows)") {
    hudPreview(.preview(
        phase: .listening,
        partialText: "This is a much longer dictation that wraps across several lines so you "
            + "can see the transcript box grow to fit however many lines the words currently "
            + "need, instead of sitting at a fixed height the whole time.",
        elapsed: 47, limitSeconds: 1440))
}

#Preview("Near limit (red)") {
    hudPreview(.preview(
        phase: .listening, partialText: "Almost at the model's single-pass limit now",
        elapsed: 33, limitSeconds: 40))
}

#Preview("Over limit") {
    hudPreview(.preview(
        phase: .listening, partialText: "Past the window — still recording",
        elapsed: 46, limitSeconds: 40))
}

#Preview("Streaming (count-up)") {
    hudPreview(.preview(
        phase: .listening, partialText: "Words appear while you speak",
        elapsed: 75, limitSeconds: nil))
}

#Preview("Transcribing") {
    hudPreview(.preview(phase: .transcribing, partialText: "Finalizing the transcript"))
}

#Preview("Live transcription OFF (pill only)") {
    hudPreview(.preview(
        phase: .listening, partialText: "This text is hidden when the setting is off",
        elapsed: 20, limitSeconds: 1440), showTranscript: false)
}
#endif
