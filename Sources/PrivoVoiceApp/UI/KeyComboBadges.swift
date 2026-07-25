// Renders a `KeyCombo` as per-key "key cap" badges joined by a dimmed "+".
//
// E.g. Control+M → [⌃] + [M]; ⌥Space → [⌥] + [Space]; the default `fn` → [fn]
// (a single badge, no plus). An empty combo renders a subtle "Not set" badge.
// Sized for inline use (caption-ish). Consumes `KeyCombo.badgeComponents` from
// PrivoVoiceKit, so it stays AppKit-free and previewable.

import SwiftUI
import PrivoVoiceKit

struct KeyComboBadges: View {
    let combo: KeyCombo

    var body: some View {
        let tokens = combo.badgeComponents
        HStack(spacing: 5) {
            if tokens.isEmpty {
                cap("Not set", muted: true)
            } else {
                ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                    if index > 0 {
                        Text("+")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    cap(token, muted: false)
                }
            }
        }
    }

    /// One rounded, monospaced key cap with a subtle fill and hairline border.
    private func cap(_ text: String, muted: Bool) -> some View {
        Text(text)
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)))
    }
}

#if DEBUG
#Preview("KeyComboBadges") {
    VStack(alignment: .leading, spacing: 14) {
        KeyComboBadges(combo: KeyCombo(keyCode: nil, modifiers: [.function]))
        KeyComboBadges(combo: KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [.option]))
        KeyComboBadges(combo: KeyCombo(keyCode: 46, keyLabel: "M", modifiers: [.control]))
        KeyComboBadges(combo: KeyCombo(keyCode: nil, modifiers: []))
    }
    .padding(28)
}
#endif
