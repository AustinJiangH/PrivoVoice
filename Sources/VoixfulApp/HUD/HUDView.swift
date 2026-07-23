// The HUD contents: a capsule that shows an amplitude meter while listening and
// an indeterminate shimmer while transcribing. Animations only — no live text by
// default, though the latest partial is shown faintly underneath when present.

import SwiftUI
import VoixfulKit

struct HUDView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.08)))

                HStack(spacing: 10) {
                    Image(systemName: appState.phase == .transcribing
                          ? "ellipsis" : "mic.fill")
                        .foregroundStyle(tint)
                        .font(.system(size: 14, weight: .semibold))
                        .symbolEffect(.pulse, isActive: appState.phase == .transcribing)

                    Group {
                        if appState.phase == .transcribing {
                            TranscribingIndicator(tint: tint)
                        } else {
                            AmplitudeMeter(level: appState.level, tint: tint)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 44)

            if !appState.partialText.isEmpty {
                Text(appState.partialText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 240, alignment: .center)
            }
        }
        .padding(.top, 2)
        .animation(.easeInOut(duration: 0.2), value: appState.phase)
    }

    private var tint: Color {
        appState.phase == .transcribing ? .orange : .green
    }
}

/// A row of bars whose heights track the live input amplitude, with a little
/// idle jitter so it always feels alive.
private struct AmplitudeMeter: View {
    let level: Float
    let tint: Color
    private let bars = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: 3, height: barHeight(i, t: t))
                }
            }
            .frame(height: 28)
        }
    }

    private func barHeight(_ i: Int, t: TimeInterval) -> CGFloat {
        // Bell-shaped envelope centered in the row, scaled by the amplitude,
        // modulated by a per-bar sine so the bars shimmer rather than move as one.
        let center = Double(bars - 1) / 2
        let dist = abs(Double(i) - center) / center
        let envelope = 1.0 - dist * 0.6
        let wobble = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 6 + Double(i)))
        let amp = Double(max(0.05, min(1, level)))
        let h = 4 + 24 * amp * envelope * wobble
        return CGFloat(h)
    }
}

/// Three dots cycling while the final transcript is being produced.
private struct TranscribingIndicator: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 2
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * (0.5 + 0.5 * sin(phase - Double(i) * 0.6)))
                }
            }
        }
    }
}
