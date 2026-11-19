// The floating HUD, in two pieces:
//   • a notch "island" (`HUDView`) — a solid black shape that grows out of the
//     camera notch (Dynamic Island style) when dictation starts and shrinks
//     back into it when it ends, showing only the recording status: amplitude
//     meter left of the camera housing, elapsed time right (pulsing dots +
//     label while the transcript is finalized/polished). The timer turns
//     amber/red as the model's single-pass limit approaches/passes. Black, not
//     glass, so it merges with the physical notch; on a screen without one it
//     hangs from the top edge the same way.
//   • the live transcript (`TranscriptPanelView`, opt-out in Settings) — the
//     content of a separate panel at the top or bottom of the screen whose
//     window IS the system's Liquid Glass (`NSGlassEffectView`, set up by
//     `HUDController`, forced to its active look), so it samples the desktop
//     like Control Center does.
//     The text sits on the glass and renders as plain, crisply antialiased text.

import SwiftUI
import PrivoVoiceKit

struct HUDView: View {
    @Bindable var appState: AppState
    @Bindable var presentation: HUDPresentation

    var body: some View {
        // Tick ~15×/s while listening so the clock and limit tint stay live;
        // paused otherwise.
        TimelineView(.animation(minimumInterval: 1.0 / 15.0,
                                paused: appState.phase != .listening)) { context in
            NotchIsland(
                appState: appState,
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
    let isOpen: Bool
    let notch: NotchMetrics
    let progress: RecordingProgress

    /// Width of each wing beside the camera housing.
    private static let wingWidth: CGFloat = 84
    /// The concave "shoulders" where the island meets the top edge.
    private static let topRadius: CGFloat = 8

    private var isFinalizing: Bool {
        appState.phase == .transcribing || appState.phase == .polishing
    }

    /// A failed session's notice, shown once dictation is over.
    private var notice: String? {
        appState.phase.isActive ? nil : appState.notice
    }

    private var rowHeight: CGFloat { max(notch.height, 28) }

    private var openWidth: CGFloat {
        notch.width + 2 * Self.wingWidth + 2 * (Self.topRadius + 12)
    }

    /// Collapsed: exactly the notch's silhouette, or a sliver at the top edge
    /// of a notch-less screen (so it reads as retracting off-screen).
    private var collapsedSize: CGSize {
        notch.hasNotch ? CGSize(width: notch.width, height: notch.height)
                       : CGSize(width: 120, height: 0)
    }

    private var shape: NotchShape {
        NotchShape(topRadius: isOpen ? Self.topRadius : 4,
                   bottomRadius: isOpen ? rowHeight / 2 : 10)
    }

    var body: some View {
        topRow
        .padding(.horizontal, Self.topRadius + 12)
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
    }

    private var glowColor: Color {
        guard isOpen else { return .clear }
        if notice != nil { return AppTheme.danger.opacity(0.35) }
        if isFinalizing { return AppTheme.progress.opacity(0.35) }
        return progress.tint.opacity(0.18 + 0.4 * Double(min(1, max(0, appState.level))))
    }

    /// The row level with the notch: one wing each side of the camera housing.
    private var topRow: some View {
        HStack(spacing: 0) {
            Group {
                if notice != nil {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.danger)
                } else if isFinalizing {
                    TranscribingIndicator(tint: AppTheme.progress)
                } else {
                    AmplitudeMeter(level: appState.level, tint: progress.tint)
                }
            }
            .frame(width: Self.wingWidth, alignment: .leading)

            Spacer(minLength: notch.width)

            Group {
                if let notice {
                    Text(notice)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(AppTheme.danger)
                } else if isFinalizing {
                    Text(appState.phase == .polishing ? "Polishing"
                         : appState.isModelWarming ? "Warming up" : "Transcribing")
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

// MARK: - Transcript panel

/// The live transcript, hosted inside the transcript panel's glass. Sized to
/// its text at a fixed width; reports its height so `HUDController` can fit
/// the glass window to it (growing away from its screen edge as lines wrap).
struct TranscriptPanelView: View {
    @Bindable var appState: AppState
    @Bindable var settings: AppSettings
    /// The panel fell back to the dark blur material (no Liquid Glass), which
    /// always needs white text.
    var onDarkMaterial = false
    let width: CGFloat
    let onHeightChange: (CGFloat) -> Void

    private var whiteText: Bool { onDarkMaterial || settings.transcriptGlass == .clear }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0,
                                paused: appState.phase != .listening)) { context in
            TranscriptBox(
                appState: appState,
                progress: RecordingProgress(start: appState.recordingStartDate,
                                            limit: appState.recordingLimitSeconds,
                                            now: context.date),
                whiteText: whiteText)
        }
        // White text on the dimmed clear glass: dark-scheme status colors.
        .environment(\.colorScheme, whiteText ? .dark : .light)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct TranscriptBox: View {
    @Bindable var appState: AppState
    let progress: RecordingProgress
    let whiteText: Bool

    private var isEmpty: Bool { appState.partialText.isEmpty }
    private var isFinalizing: Bool {
        appState.phase == .transcribing || appState.phase == .polishing
    }
    // Show only the most recent 50 words: the tail is sliced verbatim (original
    // spacing/newlines) and prefixed with "…" once earlier words drop off, so the
    // newest words hold a steady position instead of scrolling the whole caption.
    private var displayText: String {
        isEmpty ? placeholder : TranscriptWindow.lastWords(appState.partialText, maxWords: 50)
    }

    var body: some View {
        VStack(spacing: 6) {
            // The near/over-limit or minute-mark note — the notch only has
            // room for the timer.
            if !isFinalizing, let note = progress.secondaryText {
                Text(note)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(progress.secondaryColor)
                    .transition(.opacity)
            }
            // A SINGLE Text (not an if/else that swaps views): swapping views
            // made the incoming transcript lay out at its ideal 2-line size for
            // a frame before settling to one line. No .contentTransition either
            // (it reflows wrapped captions). Height still animates smoothly.
            Text(displayText)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(textColor)
                .shadow(color: .black.opacity(whiteText ? 0.3 : 0), radius: 1, y: 0.5)
                .lineLimit(8)                    // grows with the text, up to a cap
                .truncationMode(.head)           // keep the latest words visible
                .frame(maxWidth: .infinity, alignment: isEmpty ? .center : .topLeading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        // No fixed/minimum height — start at one line and grow as text wraps.
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth(duration: 0.25), value: appState.partialText)
        .animation(.easeInOut(duration: 0.2), value: progress.secondaryText)
    }

    /// Explicit colors, never `.primary`/`.secondary`: inside the glass those
    /// hierarchical styles render as *vibrant* text, recolored pixel by pixel
    /// from the backdrop — soft, speckled edges and a muddy color. Label
    /// colors stay plain, crisp text yet still flip black/white with the
    /// adaptive glass (it signals the flip through NSAppearance).
    private var textColor: Color {
        if whiteText { return .white.opacity(isEmpty ? 0.7 : 1) }
        return Color(nsColor: isEmpty ? .secondaryLabelColor : .labelColor)
    }

    private var placeholder: String {
        switch appState.phase {
        case .transcribing, .polishing: return appState.statusLabel
        default:
            return appState.isModelWarming ? "Warming up the model… keep speaking" : "Listening… speak now"
        }
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
@MainActor private func hudPreview(_ appState: AppState,
                                   notch: NotchMetrics = NotchMetrics(width: 185, height: 32, hasNotch: true))
    -> some View {
    let presentation = HUDPresentation()
    presentation.notch = notch
    presentation.isOpen = true
    return ZStack(alignment: .top) {
        // The real panel's glass is AppKit's (see HUDController); a material
        // stands in for it here.
        TranscriptPanelView(appState: appState, settings: AppSettings(storeURL: .temporaryDirectory.appending(path: "hud-preview.json")),
                            width: HUDController.transcriptWidth) { _ in }
            .fixedSize()
            .background(.regularMaterial, in: .rect(cornerRadius: HUDController.transcriptCornerRadius))
            .padding(.top, 60)
        HUDView(appState: appState, presentation: presentation)
    }
    .frame(width: 560, height: 320)
    .background(.gray.gradient)   // a stand-in desktop
}

#Preview("Listening · no words yet") {
    hudPreview(.preview(phase: .listening, partialText: "", elapsed: 3, limitSeconds: 1440))
}

#Preview("Listening · long text (grows)") {
    hudPreview(.preview(
        phase: .listening,
        partialText: "This is a much longer dictation that wraps across several lines so you "
            + "can see the panel grow to fit however many lines the words currently need.",
        elapsed: 47, limitSeconds: 1440))
}

#Preview("Near limit") {
    hudPreview(.preview(
        phase: .listening, partialText: "Almost at the model's single-pass limit now",
        elapsed: 33, limitSeconds: 40))
}

#Preview("Transcribing") {
    hudPreview(.preview(phase: .transcribing, partialText: "Finalizing the transcript"))
}

#Preview("No notch (external display)") {
    hudPreview(.preview(
        phase: .listening, partialText: "Hanging from the top edge instead",
        elapsed: 8, limitSeconds: nil), notch: .fallback)
}
#endif
