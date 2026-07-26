// The individual onboarding step screens — one question each. Every step is a
// thin view over `OnboardingScaffold` that takes only plain values/bindings and
// navigation closures, so each previews without the app's singleton environment.

import SwiftUI
import PrivoVoiceKit

// MARK: - 1. Welcome

struct WelcomeStep: View {
    var onGetStarted: () -> Void
    var onSkip: () -> Void

    var body: some View {
        OnboardingScaffold(
            systemImage: "waveform",
            title: "Welcome to PrivoVoice",
            subtitle: "Private, on-device push-to-talk dictation.",
            primaryTitle: "Get started",
            onPrimary: onGetStarted,
            secondaryTitle: "Skip setup",
            onSecondary: onSkip,
            onBack: nil
        ) {
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    systemImage: "lock.shield",
                    title: "Stays on your Mac",
                    detail: "Audio is transcribed locally — nothing is uploaded.")
                FeatureRow(
                    systemImage: "hand.tap",
                    title: "Hold to talk",
                    detail: "Press and hold your hotkey, speak, and release to paste.")
                FeatureRow(
                    systemImage: "bolt",
                    title: "Fast and hands-free",
                    detail: "Talk instead of type, anywhere text goes.")
            }
            .padding(.horizontal, 8)
        }
    }
}

private struct FeatureRow: View {
    var systemImage: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.headline, design: .rounded))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 2. Use case

struct UseCaseStep: View {
    @Binding var selectedID: String?
    /// ISO-639 code used to resolve the language-aware recommended model label.
    var languageCode: String = "en"
    var onSelect: (UseCaseProfile) -> Void
    var onContinue: () -> Void
    var onSkip: () -> Void
    var onBack: () -> Void

    var body: some View {
        OnboardingScaffold(
            systemImage: "sparkles",
            title: "What will you use it for?",
            subtitle: "We'll recommend a model to match.",
            primaryTitle: "Continue",
            primaryDisabled: selectedID == nil,
            onPrimary: onContinue,
            secondaryTitle: "Skip",
            onSecondary: onSkip,
            onBack: onBack
        ) {
            VStack(spacing: 10) {
                ForEach(UseCaseCatalog.all) { profile in
                    UseCaseCard(
                        profile: profile,
                        isSelected: selectedID == profile.id,
                        onTap: { onSelect(profile) })
                }

                if let id = selectedID,
                   let model = UseCaseCatalog.profile(id: id)?.recommendedModel(for: languageCode) {
                    Label("Recommended: \(model.displayName)", systemImage: "checkmark.seal.fill")
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.top, 4)
                        .transition(.opacity)
                }
            }
            .animation(.smooth, value: selectedID)
        }
    }
}

private struct UseCaseCard: View {
    var profile: UseCaseProfile
    var isSelected: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: profile.systemImage)
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.title).font(.system(.headline, design: .rounded))
                    Text(profile.tagline).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.tertiary))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                isSelected ? AppTheme.accent : Color.secondary.opacity(0.18),
                                lineWidth: isSelected ? 2 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 3. Model

struct ModelStep: View {
    var spec: ModelSpec?
    var state: InstallState
    var onDownload: () -> Void
    var onContinue: () -> Void
    var onBack: () -> Void

    var body: some View {
        OnboardingScaffold(
            systemImage: "square.stack.3d.up",
            title: "Your recommended model",
            subtitle: spec == nil
                ? "You can pick a model anytime in Models."
                : "Download it now, or grab it later.",
            primaryTitle: "Continue",
            onPrimary: onContinue,
            secondaryTitle: spec == nil ? nil : "Choose in Models later",
            onSecondary: spec == nil ? nil : onContinue,
            onBack: onBack
        ) {
            if let spec {
                ModelCardBody(spec: spec, state: state, onDownload: onDownload)
            } else {
                Text("No use case selected — no problem. Head to the Models tab whenever "
                     + "you're ready and pick the one that fits.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
    }
}

private struct ModelCardBody: View {
    var spec: ModelSpec
    var state: InstallState
    var onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(spec.displayName).font(.system(.title3, design: .rounded).weight(.semibold))
                Spacer()
                Text(Self.sizeLabel(spec.approxSizeMB))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(spec.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            installRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)))
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var installRow: some View {
        switch state {
        case .installed:
            Label("Ready", systemImage: "checkmark.seal.fill")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(AppTheme.positive)

        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                if fraction >= 0 {
                    ProgressView(value: min(max(fraction, 0), 1))
                    Text("Downloading… \(Int((min(max(fraction, 0), 1)) * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                }
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing…").font(.caption).foregroundStyle(.secondary)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again", action: onDownload)
                    .buttonStyle(.bordered)
            }

        case .notInstalled:
            Button {
                onDownload()
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
        }
    }

    /// "330 MB" / "1.1 GB".
    static func sizeLabel(_ mb: Int) -> String {
        mb >= 1000
            ? String(format: "%.1f GB", Double(mb) / 1000)
            : "\(mb) MB"
    }
}

// MARK: - 4. Hotkey

struct HotkeyStep: View {
    @Binding var hotkey: KeyCombo
    var onContinue: () -> Void
    var onBack: () -> Void

    var body: some View {
        OnboardingScaffold(
            systemImage: "keyboard",
            title: "Pick your talk key",
            subtitle: "Hold it to record, release to transcribe and paste.",
            primaryTitle: "Continue",
            onPrimary: onContinue,
            secondaryTitle: "Not now",
            onSecondary: onContinue,
            onBack: onBack
        ) {
            VStack(spacing: 16) {
                ShortcutRecorderView(combo: $hotkey)
                    .frame(maxWidth: 320)

                HStack(spacing: 8) {
                    Text("Presets:").font(.caption).foregroundStyle(.secondary)
                    presetButton("fn", KeyCombo(keyCode: nil, modifiers: [.function]))
                    presetButton("⌥Space", KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [.option]))
                    presetButton("F5", KeyCombo(keyCode: 96, keyLabel: "F5", modifiers: []))
                }

                Text("Any key or chord works — including `fn` on its own. The trigger is "
                     + "consumed while held, so it never types.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func presetButton(_ title: String, _ combo: KeyCombo) -> some View {
        Button(title) { hotkey = combo }
            .buttonStyle(.bordered)
            .font(.caption)
    }
}

// MARK: - 5. Options

struct OptionsStep: View {
    @Binding var autoCopy: Bool
    @Binding var showLiveTranscription: Bool
    var onContinue: () -> Void
    var onBack: () -> Void

    var body: some View {
        OnboardingScaffold(
            systemImage: "slider.horizontal.3",
            title: "A couple of options",
            subtitle: "You can change these anytime in Settings.",
            primaryTitle: "Continue",
            onPrimary: onContinue,
            secondaryTitle: "Not now",
            onSecondary: onContinue,
            onBack: onBack
        ) {
            VStack(alignment: .leading, spacing: 18) {
                OptionToggle(
                    isOn: $autoCopy,
                    title: "Copy transcript to clipboard automatically",
                    detail: "Every finished transcript lands on your clipboard, ready to paste.")
                OptionToggle(
                    isOn: $showLiveTranscription,
                    title: "Show live transcription in the HUD",
                    detail: "Watch your words appear while you talk. When off, the HUD is just "
                        + "the amplitude meter and timer.")
            }
            .padding(.horizontal, 8)
        }
    }
}

private struct OptionToggle: View {
    @Binding var isOn: Bool
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isOn) {
                Text(title).font(.system(.headline, design: .rounded))
            }
            .tint(AppTheme.accent)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 6. Transcript cleanup (optional extra)

struct FormattingStep: View {
    /// Whether the user has already opted in (mirrors `settings.formatFinalTranscript`).
    var enabled: Bool
    /// Live install state of the cleanup model (mirrors `FormatterStore.shared.phase`).
    var phase: FormatterStore.Phase
    var modelName: String
    var sizeDescription: String
    var onEnable: () -> Void
    var onContinue: () -> Void
    var onBack: () -> Void

    var body: some View {
        OnboardingScaffold(
            systemImage: "wand.and.stars",
            title: "Want polished transcripts?",
            subtitle: "An optional extra: a small on-device AI tidies up each dictation.",
            primaryTitle: "Continue",
            onPrimary: onContinue,
            secondaryTitle: enabled ? nil : "No thanks, keep it off",
            onSecondary: enabled ? nil : onContinue,
            onBack: onBack
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(modelName)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                    Spacer()
                    Text(sizeDescription)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Fixes punctuation, capitalization, and obvious mis-hearings — "
                     + "all on your Mac, nothing uploaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                tradeoffRow(systemImage: "clock",
                            text: "Each dictation takes noticeably longer to deliver.")
                tradeoffRow(systemImage: "arrow.down.circle",
                            text: "One-time \(sizeDescription) model download.")

                Divider()

                if enabled {
                    enabledStatus
                        .transition(.opacity)
                } else {
                    Button {
                        onEnable()
                    } label: {
                        Label("Turn on & download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)))
            .padding(.horizontal, 4)
            .animation(.smooth, value: enabled)
            .animation(.smooth, value: phase)
        }
    }

    /// Live post-opt-in state: progress while downloading, the positive "ready"
    /// treatment once installed, and a pointer to Settings on failure.
    @ViewBuilder
    private var enabledStatus: some View {
        switch phase {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Label("On — downloading the model", systemImage: "arrow.down.circle")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(AppTheme.accent)
                ProgressView(value: min(max(fraction, 0), 1))
                Text("\(Int(min(max(fraction, 0), 1) * 100))% — dictation works normally "
                     + "in the meantime; you'll get raw transcripts until it's ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .installed:
            Label("On — the model is ready", systemImage: "checkmark.seal.fill")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(AppTheme.positive)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can retry the download anytime in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .notInstalled:
            // Opted in but no download running — e.g. the app quit mid-download
            // and relaunched into onboarding. Offer to pick it back up
            // (`download()` is idempotent, so a stray tap is harmless).
            VStack(alignment: .leading, spacing: 6) {
                Label("The download didn't finish.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                Button("Resume download", action: onEnable)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func tradeoffRow(systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(AppTheme.warning)
                .frame(width: 20)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 7. Try it

struct TryItStep: View {
    var phase: DictationPhase
    var lastTranscript: String
    var pasteAuthorized: Bool
    var hotkeyDisplay: String
    var onFinish: () -> Void
    var onBack: () -> Void

    var body: some View {
        OnboardingScaffold(
            systemImage: "mic.fill",
            title: "Give it a try",
            subtitle: "Hold \(hotkeyDisplay) and say something.",
            primaryTitle: "Finish",
            onPrimary: onFinish,
            secondaryTitle: nil,
            onSecondary: nil,
            onBack: onBack
        ) {
            VStack(spacing: 16) {
                phaseIndicator

                if !lastTranscript.isEmpty {
                    VStack(spacing: 8) {
                        Label("Nice — you're all set!", systemImage: "checkmark.circle.fill")
                            .font(.system(.headline, design: .rounded))
                            .foregroundStyle(AppTheme.positive)
                        Text("\u{201C}\(lastTranscript)\u{201D}")
                            .font(.callout)
                            .italic()
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(AppTheme.positive.opacity(0.12)))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                if !pasteAuthorized {
                    Label {
                        Text("Pasting needs Accessibility. Grant it in "
                             + "System Settings → Privacy & Security → Accessibility so your "
                             + "words paste automatically.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                }
            }
            .animation(.smooth, value: lastTranscript)
            .animation(.smooth, value: phase)
        }
    }

    private var phaseIndicator: some View {
        HStack(spacing: 10) {
            Circle().fill(phase.statusColor).frame(width: 12, height: 12)
            Text(phaseLabel)
                .font(.system(.title3, design: .rounded).weight(.medium))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 22)
        .background(Capsule().fill(.regularMaterial))
    }

    private var phaseLabel: String {
        switch phase {
        case .idle: return "Ready when you are"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .polishing: return "Polishing…"
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Welcome") {
    WelcomeStep(onGetStarted: {}, onSkip: {})
        .frame(width: 560, height: 640).padding(28)
}

#Preview("Use case") {
    UseCaseStepPreview()
        .frame(width: 560, height: 720).padding(28)
}

private struct UseCaseStepPreview: View {
    @State private var id: String?
    var body: some View {
        UseCaseStep(
            selectedID: $id,
            onSelect: { id = $0.id },
            onContinue: {}, onSkip: {}, onBack: {})
    }
}

#Preview("Model") {
    ModelStep(
        spec: ModelCatalog.spec(id: "parakeet-tdt-0.6b-v2"),
        state: .notInstalled,
        onDownload: {}, onContinue: {}, onBack: {})
    .frame(width: 560, height: 640).padding(28)
}

#Preview("Formatting") {
    FormattingStep(
        enabled: false,
        phase: .notInstalled,
        modelName: "Transcript Polish (Qwen3 1.7B, 4-bit)",
        sizeDescription: "~1 GB",
        onEnable: {}, onContinue: {}, onBack: {})
    .frame(width: 560, height: 640).padding(28)
}

#Preview("Try it") {
    TryItStep(
        phase: .idle,
        lastTranscript: "Hello from PrivoVoice.",
        pasteAuthorized: false,
        hotkeyDisplay: "fn",
        onFinish: {}, onBack: {})
    .frame(width: 560, height: 640).padding(28)
}
#endif
