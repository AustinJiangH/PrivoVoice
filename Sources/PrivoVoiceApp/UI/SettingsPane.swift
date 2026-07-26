// The Settings pane: push-to-talk shortcut, auto-copy, models location, version.

import SwiftUI
import AppKit
import PrivoVoiceKit

struct SettingsPane: View {
    @Environment(AppEnvironment.self) private var env

    /// Shown when the formatting toggle is switched on without the model
    /// installed — the ~700 MB download needs explicit consent first.
    @State private var confirmFormatterDownload = false

    var body: some View {
        @Bindable var settings = env.settings

        Form {
            Section("Dictation") {
                LabeledContent("Push-to-talk") {
                    VStack(alignment: .trailing, spacing: 6) {
                        ShortcutRecorderView(combo: $settings.hotkey)
                        HStack(spacing: 6) {
                            Text("Presets:").font(.caption2).foregroundStyle(.secondary)
                            presetButton("fn", KeyCombo(keyCode: nil, modifiers: [.function]))
                            presetButton("⌥Space", KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [.option]))
                            presetButton("F5", KeyCombo(keyCode: 96, keyLabel: "F5", modifiers: []))
                        }
                    }
                }
                Text("Hold the shortcut to record; release to transcribe and paste. Any key or "
                     + "chord works — including `fn`+Space — and the trigger is consumed so it "
                     + "doesn't type. Needs Accessibility (same as pasting); no Input Monitoring.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Copy transcript to clipboard automatically", isOn: $settings.autoCopy)

                Toggle("Add a space before each dictation", isOn: $settings.autoSpacing)
                Text("Prepends a single space to each transcript so back-to-back "
                     + "dictations don't run together (some models omit boundary spaces).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show live transcription in the floating HUD", isOn: $settings.showLiveTranscription)
                Text("When off, the HUD is just the small amplitude meter and recording timer — "
                     + "your words are still pasted when you release the key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Hotkey") {
                    statusRow(ok: env.appState.hotkeyActive,
                              okText: "Active", badText: "Inactive")
                }
                LabeledContent("Accessibility") {
                    HStack(spacing: 6) {
                        statusRow(ok: env.appState.pasteAuthorized,
                                  okText: "Granted", badText: "Not granted")
                        if !env.appState.pasteAuthorized {
                            Button("Open Accessibility") { openPrivacy("Privacy_Accessibility") }
                        }
                    }
                }
                Text("Accessibility powers the push-to-talk hotkey (any key/chord) and pasting. "
                     + "No Input Monitoring is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Models") {
                LabeledContent("Storage location") {
                    HStack {
                        Text(settings.modelsDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Change…", action: chooseModelsDirectory)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([settings.modelsDirectory])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Reveal in Finder")
                    }
                }
                if settings.modelsDirectory != AppSettings.defaultModelsDirectory {
                    Button("Reset to default location") {
                        settings.modelsDirectory = AppSettings.defaultModelsDirectory
                        env.store.refresh()
                    }
                }

                LabeledContent("Hugging Face token") {
                    SecureField("hf_… (optional)", text: Binding(
                        get: { settings.huggingFaceToken ?? "" },
                        set: { settings.huggingFaceToken = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                }
                Text("Only needed to download gated or private model repos. "
                     + "Overridden by the HF_TOKEN environment variable if set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            advancedSection

            Section {
                LabeledContent("Version", value: "\(AppInfo.name) \(AppInfo.version)")
                if let err = env.appState.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)   // let the panel tint show through
        .navigationTitle("Settings")
        .alert("Download formatting model?", isPresented: $confirmFormatterDownload) {
            Button("Download") { FormatterStore.shared.download() }
            Button("Cancel", role: .cancel) { env.settings.formatFinalTranscript = false }
        } message: {
            Text("PrivoVoice will download \(FormatterStore.shared.displayName) "
                 + "(\(FormatterStore.shared.approxSizeDescription)) from Hugging Face "
                 + "to your Mac.")
        }
    }

    /// The transcript-formatting section: master toggle, capability sub-toggles,
    /// and the cleanup-model management row. Split out of `body` to keep the Form
    /// expression type-checkable.
    @ViewBuilder
    private var advancedSection: some View {
        @Bindable var settings = env.settings
        Section("Advanced") {
            Toggle("Format & correct transcripts", isOn: $settings.formatFinalTranscript)
                .onChange(of: settings.formatFinalTranscript) { _, enabled in
                    // Turning it on without the model installed asks before
                    // downloading; Cancel reverts the toggle. Once confirmed
                    // the toggle stays on and the core falls back to raw
                    // transcripts until the model is ready.
                    if enabled && !FormatterStore.shared.isInstalled {
                        confirmFormatterDownload = true
                    }
                }
            Text("Runs each finished dictation through a small on-device language "
                 + "model that fixes punctuation, capitalization, and obvious "
                 + "mis-hearings. Transcripts take noticeably longer to deliver "
                 + "while this is on. Applies once the model below finishes "
                 + "downloading — until then you get the raw transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Capability sub-toggles — children of the master switch above.
            Group {
                Toggle("Remove filler words", isOn: $settings.formatterRemovesFillers)
                Text("Drops \u{201C}um\u{201D}, \u{201C}uh\u{201D}, \u{201C}ah\u{201D}, and stutters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Format spoken lists", isOn: $settings.formatterFormatsLists)
                Text("Turns \u{201C}first… second… third…\u{201D} into a list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Apply verbal corrections", isOn: $settings.formatterAppliesCorrections)
                Text("\u{201C}Monday — no wait, Tuesday\u{201D} keeps only Tuesday.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 20)
            .disabled(!settings.formatFinalTranscript)

            formatterModelRow
        }
    }

    /// The cleanup-model management row, driven by `FormatterStore.shared`.
    @ViewBuilder
    private var formatterModelRow: some View {
        let store = FormatterStore.shared
        LabeledContent(store.displayName) {
            switch store.phase {
            case .notInstalled:
                HStack(spacing: 8) {
                    Text(store.approxSizeDescription)
                        .foregroundStyle(.secondary)
                    Button("Download") { store.download() }
                }

            case .downloading(let fraction):
                HStack(spacing: 8) {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .frame(width: 140)
                    Text("\(Int(min(max(fraction, 0), 1) * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

            case .installed:
                HStack(spacing: 8) {
                    statusRow(ok: true, okText: "Installed", badText: "")
                    Button("Remove") { store.remove() }
                        .controlSize(.small)
                }

            case .failed(let message):
                HStack(spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .lineLimit(2)
                    Button("Retry") { store.download() }
                }
            }
        }
    }

    private func presetButton(_ title: String, _ combo: KeyCombo) -> some View {
        Button(title) { env.settings.hotkey = combo }
            .buttonStyle(.borderless)
            .font(.caption2)
    }

    private func statusRow(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? AppTheme.positive : AppTheme.warning)
                .frame(width: 8, height: 8)
            Text(ok ? okText : badText)
        }
    }

    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func chooseModelsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = env.settings.modelsDirectory
        if panel.runModal() == .OK, let url = panel.url {
            env.settings.modelsDirectory = url
            env.store.refresh()
        }
    }
}
