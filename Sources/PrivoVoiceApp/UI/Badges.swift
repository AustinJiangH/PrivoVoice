// Small reusable capability indicators for the model cards.

import SwiftUI
import PrivoVoiceKit

/// A pill with an icon + label, tinted by role.
struct CapabilityBadge: View {
    let icon: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .imageScale(.small)
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Marks a model's rank within a use-case section: #1 reads "Recommended"
/// (accent), alternates show their numeric rank (#2, #3, …).
struct RankBadge: View {
    let rank: Int

    private var isTop: Bool { rank == 1 }
    private var tint: Color { isTop ? AppTheme.accent : .secondary }

    var body: some View {
        HStack(spacing: 4) {
            if isTop {
                Image(systemName: "star.fill").imageScale(.small)
                Text("Recommended")
            } else {
                Text("#\(rank)")
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.16), in: Capsule())
        .help(isTop ? "Recommended for this use case" : "Also good — alternate #\(rank)")
    }
}

/// A labelled 1–3 rating shown as filled/empty pips (e.g. Speed ●●○).
struct RatingBadge: View {
    let label: String
    let rating: Rating
    var tint: Color = AppTheme.info

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .fill(i <= rating.rawValue ? tint : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .help("\(label): \(rating.label)")
    }
}
