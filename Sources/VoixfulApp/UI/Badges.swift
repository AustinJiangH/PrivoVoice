// Small reusable capability indicators for the model cards.

import SwiftUI
import VoixfulKit

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

/// A labelled 1–3 rating shown as filled/empty pips (e.g. Speed ●●○).
struct RatingBadge: View {
    let label: String
    let rating: Rating
    var tint: Color = .blue

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
