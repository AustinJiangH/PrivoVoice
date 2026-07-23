// The Settings pane: push-to-talk shortcut, auto-copy, models location, version.

import SwiftUI
import AppKit
import VoixfulKit

struct SettingsPane: View {
    @Environment(AppEnvironment.self) private var env

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
                     + "chord works — `fn` alone is cleanest (nothing types). No Input Monitoring "
                     + "needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Copy transcript to clipboard automatically", isOn: $settings.autoCopy)

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
                Text("Accessibility powers pasting, and `fn` / bare-key shortcuts. "
                     + "Modifier+key and function-key shortcuts (⌥Space, F5) need no permission at all.")
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

            Section {
                LabeledContent("Version", value: "\(AppInfo.name) \(AppInfo.version)")
                if let err = env.appState.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private func presetButton(_ title: String, _ combo: KeyCombo) -> some View {
        Button(title) { env.settings.hotkey = combo }
            .buttonStyle(.borderless)
            .font(.caption2)
    }

    private func statusRow(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
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
