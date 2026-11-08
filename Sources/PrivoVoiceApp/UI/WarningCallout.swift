// A legible inline warning: a tinted, outlined box with a solid warning icon,
// the message in normal text, and an optional action button. Replaces bare
// amber caption labels, which were barely readable on light backgrounds.

import SwiftUI

struct WarningCallout: View {
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warningText)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.warning.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AppTheme.warning.opacity(0.55), lineWidth: 1)))
    }
}

#if DEBUG
#Preview("WarningCallout") {
    VStack(spacing: 12) {
        WarningCallout(message: "Formatting is on but the model isn't installed — "
                       + "transcripts are delivered unformatted.",
                       actionTitle: "Download", action: {})
        WarningCallout(message: "No microphone is configured.")
    }
    .padding(24)
    .frame(width: 520)
}
#endif
