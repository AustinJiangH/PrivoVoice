// The floating HUD as a notch "island".
//
// A solid black shape that grows out of the camera notch (Dynamic Island
// style) when dictation starts and shrinks back into it when it ends:
//   • a top row flanking the camera housing — amplitude meter on the left,
//     elapsed time on the right (a pulsing dots indicator + label while the
//     transcript is finalized/polished). The timer turns amber/red as the
//     current model's single-pass limit approaches/passes.
//   • below it, the island expands downward to show the live transcript once
//     words arrive (opt-out in Settings), plus a transient note near/over the
//     limit or at each minute mark.
// Solid black — not Liquid Glass — so it merges with the physical notch and the
// text renders as plain, crisply antialiased glyphs: text drawn inside a glass
// effect is composited through the glass layer and looked rough. On a screen
// without a notch the island hangs from the top edge the same way.

import SwiftUI
import PrivoVoiceKit

struct HUDView: View {
    @Bindable var appState: AppState
    @Bindable var settings: AppSettings
    @Bindable var presentation: HUDPresentation

    var body: some View {
        // Tick ~15×/s while listening so the clock and limit tint stay live;
        // paused otherwise.
        TimelineView(.animation(minimumInterval: 1.0 / 15.0,
                                paused: appState.phase != .listening)) { context in
            NotchIsland(
                appState: appState,
                showTranscript: settings.showLiveTranscription,
                isOpen: presentation.isOpen,
                notch: presentation.notch,
                progress: RecordingProgress(start: appState.recordingStartDate,
                                            limit: appState.recordingLimitSeconds,
                                            now: context.date))
        }
        // Top-anchored in the panel's transparent canvas, flush with the
        // screen's top edge so the island meets the notch.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        // The island is always black, so always use the dark-appearance
        // variants of the status colors.
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Island

private struct NotchIsland: View {
    @Bindable var appState: AppState
    let showTranscript: Bool
    let isOpen: Bool
    let notch: NotchMetrics
    let progress: RecordingProgress

    /// Width of each wing beside the camera housing.
    private static let wingWidth: CGFloat = 84
    /// The concave "shoulders" where the island meets the top edge.
    private static let topRadius: CGFloat = 8
    /// Fixed island width once the transcript body is showing.
    private static let bodyWidth: CGFloat = 440

    private var isFinalizing: Bool {
        appState.phase == .transcribing || appState.phase == .polishing
    }

    /// Expand below the top row only once there's something to show — words
    /// (if live transcription is on) or a limit/minute note.
    private var showsBody: Bool {
        isOpen && ((showTranscript && !appState.partialText.isEmpty)
                   || (!isFinalizing && progress.secondaryText != nil))
    }

    private var rowHeight: CGFloat { max(notch.height, 28) }

    private var openWidth: CGFloat {
        let compact = notch.width + 2 * Self.wingWidth + 2 * (Self.topRadius + 12)
        return showsBody ? max(compact, Self.bodyWidth) : compact
    }

    /// Collapsed: exactly the notch's silhouette, or a sliver at the top edge
    /// of a notch-less screen (so it reads as retracting off-screen).
    private var collapsedSize: CGSize {
        notch.hasNotch ? CGSize(width: notch.width, height: notch.height)
                       : CGSize(width: 120, height: 0)
    }

    private var shape: NotchShape {
        NotchShape(topRadius: isOpen ? Self.topRadius : 4,
                   bottomRadius: !isOpen ? 10 : (showsBody ? 24 : rowHeight / 2))
    }

    var body: some View {
        VStack(spacing: 0) {
            topRow
            if showsBody {
                islandBody
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .padding(.horizontal, Self.topRadius + 12)
        .padding(.bottom, showsBody ? 14 : 0)
        // Content fades in once the island has started to open, and out first
        // on close, so nothing spills past the shrinking shape.
        .opacity(isOpen ? 1 : 0)
        .blur(radius: isOpen ? 0 : 6)
        .frame(width: isOpen ? openWidth : collapsedSize.width,
               height: isOpen ? nil : collapsedSize.height,
               alignment: .top)
        .background(shape.fill(.black))
        .clipShape(shape)
        // A soft glow in the status color that breathes with the voice.
        .shadow(color: glowColor, radius: 16, y: 6)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: isOpen)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: showsBody)
        .animation(.smooth(duration: 0.25), value: appState.partialText)
        .animation(.easeInOut(duration: 0.2), value: progress.secondaryText)
    }

    private var glowColor: Color {
        guard isOpen else { return .clear }
        if isFinalizing { return AppTheme.progress.opacity(0.35) }
        return progress.tint.opacity(0.18 + 0.4 * Double(min(1, max(0, appState.level))))
    }

    /// The row level with the notch: one wing each side of the camera housing.
    private var topRow: some View {
        HStack(spacing: 0) {
            Group {
                if isFinalizing {
                    TranscribingIndicator(tint: AppTheme.progress)
                } else {
                    AmplitudeMeter(level: appState.level, tint: progress.tint)
                }
            }
            .frame(width: Self.wingWidth, alignment: .leading)

            Spacer(minLength: notch.width)

            Group {
                if isFinalizing {
                    Text(appState.phase == .polishing ? "Polishing" : "Transcribing")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Text(progress.centerText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(progress.tint)
                        .contentTransition(.numericText())
                }
            }
            .lineLimit(1)
            .frame(width: Self.wingWidth, alignment: .trailing)
        }
        .frame(height: rowHeight)
    }

    private var islandBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isFinalizing, let note = progress.secondaryText {
                Text(note)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(progress.secondaryColor)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
            }
            if showTranscript && !appState.partialText.isEmpty {
                // Only the most recent 50 words: the tail is sliced verbatim
                // and prefixed with "…" once earlier words drop off, so the
                // newest words hold a steady position. A single Text (no view
                // swapping) so it never flashes at its ideal size for a frame.
                Text(TranscriptWindow.lastWords(appState.partialText, maxWords: 50))
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(6)
                    .truncationMode(.head)        // keep the latest words visible
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 4)
    }
}

/// The island's outline: flush with the top edge, with small concave
/// "shoulders" flaring into it (like the hardware notch) and rounded bottom
/// corners. Both radii animate, so the shape morphs as it opens/closes.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        // Clamp so a tiny (collapsing) rect never produces crossed curves.
        let top = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let bottom = max(0, min(bottomRadius, (rect.width - 2 * top) / 2, rect.height - top))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                       control: CGPoint(x: rect.minX + top, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                       control: CGPoint(x: rect.minX + top, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                       control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - top, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Shared bits

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
@MainActor private func hudPreview(_ appState: AppState, showTranscript: Bool = true,
                                   notch: NotchMetrics = NotchMetrics(width: 185, height: 32, hasNotch: true))
    -> some View {
    let settings = AppSettings(storeURL: FileManager.default.temporaryDirectory
        .appending(path: "hud-preview-\(UUID().uuidString)/settings.json"))
    settings.showLiveTranscription = showTranscript
    let presentation = HUDPresentation()
    presentation.notch = notch
    presentation.isOpen = true
    return HUDView(appState: appState, settings: settings, presentation: presentation)
        .frame(width: HUDController.size.width, height: 260)
        .background(.gray.gradient)   // a stand-in desktop
}

#Preview("Listening · no words yet (compact)") {
    hudPreview(.preview(phase: .listening, partialText: "", elapsed: 3, limitSeconds: 1440))
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
            + "can see the island grow to fit however many lines the words currently "
            + "need, instead of sitting at a fixed height the whole time.",
        elapsed: 47, limitSeconds: 1440))
}

#Preview("Near limit (amber note)") {
    hudPreview(.preview(
        phase: .listening, partialText: "Almost at the model's single-pass limit now",
        elapsed: 33, limitSeconds: 40))
}

#Preview("Over limit") {
    hudPreview(.preview(
        phase: .listening, partialText: "Past the window — still recording",
        elapsed: 46, limitSeconds: 40))
}

#Preview("Transcribing") {
    hudPreview(.preview(phase: .transcribing, partialText: "Finalizing the transcript"))
}

#Preview("Live transcription OFF (compact)") {
    hudPreview(.preview(
        phase: .listening, partialText: "This text is hidden when the setting is off",
        elapsed: 20, limitSeconds: 1440), showTranscript: false)
}

#Preview("No notch (external display)") {
    hudPreview(.preview(
        phase: .listening, partialText: "Hanging from the top edge instead",
        elapsed: 8, limitSeconds: nil), notch: .fallback)
}
#endif
