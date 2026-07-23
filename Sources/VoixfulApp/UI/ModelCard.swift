// One model in the Models pane: identity, capabilities, and install actions
// (download / import / delete / select).

import SwiftUI
import AppKit
import VoixfulKit

struct ModelCard: View {
    let spec: ModelSpec
    @Environment(AppEnvironment.self) private var env

    @State private var confirmingDelete = false

    private var isInstalled: Bool { env.store.isInstalled(spec) }
    private var isSelected: Bool { env.settings.selectedModelID == spec.id }
    private var installState: InstallState { env.downloader.state(for: spec) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(spec.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            badges
            languageChips
            Divider()
            actionRow
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(spec.displayName)
                .font(.headline)
            if isSelected {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            Text(spec.parameters)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Badges

    private var badges: some View {
        // Wrapping row of capability badges.
        FlowLayout(spacing: 6) {
            if spec.streaming {
                CapabilityBadge(icon: "dot.radiowaves.left.and.right", text: "Streaming", tint: .green)
            } else {
                CapabilityBadge(icon: "arrow.triangle.2.circlepath", text: "Re-transcribe", tint: .secondary)
            }
            RatingBadge(label: "Speed", rating: spec.speed, tint: .green)
            RatingBadge(label: "Accuracy", rating: spec.accuracy, tint: .blue)
            CapabilityBadge(
                icon: "globe",
                text: spec.languages.count == 1 ? spec.languages[0].displayName : "\(spec.languages.count) languages",
                tint: .teal)
            CapabilityBadge(icon: "internaldrive", text: sizeText, tint: .secondary)
            if let wer = spec.werLeaderboard {
                CapabilityBadge(icon: "chart.bar", text: "WER \(String(format: "%.2f", wer))", tint: .purple)
            }
            CapabilityBadge(icon: "doc.text", text: spec.weightsLicense, tint: .orange)
        }
    }

    private var sizeText: String {
        if let installed = env.store.formattedSize(for: spec) { return installed }
        return "≈ \(spec.approxSizeMB) MB"
    }

    @ViewBuilder private var languageChips: some View {
        if spec.languages.count > 1 {
            FlowLayout(spacing: 4) {
                ForEach(spec.languages.prefix(12)) { lang in
                    Text(lang.code.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                if spec.languages.count > 12 {
                    Text("+\(spec.languages.count - 12)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Actions

    @ViewBuilder private var actionRow: some View {
        HStack(spacing: 10) {
            switch installState {
            case .installed:
                Button {
                    env.settings.selectedModelID = spec.id
                } label: {
                    Label(isSelected ? "Selected" : "Use this model",
                          systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSelected)

                Spacer()

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this model from disk")
                .confirmationDialog(
                    "Delete \(spec.displayName)?",
                    isPresented: $confirmingDelete, titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive, action: delete)
                } message: {
                    Text("Removes the downloaded asset. You can re-download it later.")
                }

            case let .downloading(fraction):
                if fraction < 0 {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: fraction) {
                        Text("Downloading… \(Int(fraction * 100))%").font(.caption)
                    }
                    .frame(maxWidth: 220)
                }
                Spacer()
                Button("Cancel") { env.downloader.cancel(spec) }

            case .installing:
                ProgressView().controlSize(.small)
                Text("Installing…").font(.caption).foregroundStyle(.secondary)
                Spacer()

            case let .failed(message):
                VStack(alignment: .leading, spacing: 2) {
                    Label("Failed", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Retry") { env.downloader.download(spec) }
                importButton

            case .notInstalled:
                Button {
                    env.downloader.download(spec)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(spec.download == nil)
                importButton
                Spacer()
            }
        }
    }

    private var importButton: some View {
        Button("Import…", action: importLocal)
            .help("Install from a local .aimodel directory")
    }

    private func importLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the \(spec.assetName) directory (or any converted .aimodel for this model)."
        if panel.runModal() == .OK, let url = panel.url {
            env.downloader.importLocal(spec, from: url)
        }
    }

    private func delete() {
        try? env.store.delete(spec)
        if isSelected { env.settings.selectedModelID = nil }
    }
}
