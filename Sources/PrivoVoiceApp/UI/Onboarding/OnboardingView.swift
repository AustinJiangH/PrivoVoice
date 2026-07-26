// First-run onboarding — an animated, skippable, one-question-per-screen flow
// shown over the main UI until the user completes (or skips) it. The container
// owns navigation, the animated slide/fade transitions, the progress indicator,
// and the global "Skip" affordance; it reads everything it needs from
// `AppEnvironment` and hands each step view only the plain data/bindings it needs
// (so the individual steps stay previewable without the singleton env).

import SwiftUI
import PrivoVoiceKit

/// The ordered steps of the first-run flow. `allCases` order == screen order.
enum OnboardingStep: Int, CaseIterable {
    case welcome, useCase, model, hotkey, options, formatting, tryIt
}

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env

    /// Called when the flow finishes or is skipped. The host sets the persisted
    /// `hasCompletedOnboarding` flag and animates the overlay away.
    let onComplete: () -> Void

    @State private var stepIndex = 0
    @State private var forward = true
    /// The chosen use-case id (drives the Model step). Selecting also writes the
    /// recommended model into settings; kept here to highlight the card + resolve
    /// the recommended model on the next screen.
    @State private var selectedUseCaseID: String?

    var body: some View {
        ZStack {
            background

            VStack(spacing: 20) {
                topBar

                // The one animated question. Re-keyed per step so SwiftUI runs the
                // asymmetric slide+fade as one screen leaves and the next enters.
                Group {
                    stepContent
                }
                .id(stepIndex)
                .transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                .frame(maxWidth: 560, maxHeight: .infinity)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Chrome

    private var background: some View {
        ZStack {
            // Opaque themed base so the main split view behind is fully hidden.
            Rectangle().fill(AppTheme.backgroundTint)
            // A soft accent wash at the top for a little warmth.
            LinearGradient(
                colors: [AppTheme.accent.opacity(0.14), .clear],
                startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            ProgressDots(count: OnboardingStep.allCases.count, current: stepIndex)
            Spacer()
            Button("Skip", action: skipAll)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 560)
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        @Bindable var settings = env.settings
        switch OnboardingStep(rawValue: stepIndex) ?? .welcome {
        case .welcome:
            WelcomeStep(onGetStarted: advance, onSkip: skipAll)

        case .useCase:
            UseCaseStep(
                selectedID: $selectedUseCaseID,
                languageCode: languageCode,
                onSelect: { profile in
                    selectedUseCaseID = profile.id
                    // Language-aware: e.g. Parakeet v2 for English, v3 otherwise.
                    env.settings.selectedModelID =
                        profile.recommendedModel(for: languageCode)?.id ?? profile.recommendedModelID
                },
                onContinue: advance,
                onSkip: advance,
                onBack: back)

        case .model:
            ModelStep(
                spec: recommendedSpec,
                state: recommendedSpec.map { env.downloader.state(for: $0) } ?? .notInstalled,
                onDownload: {
                    if let spec = recommendedSpec { env.downloader.download(spec) }
                },
                onContinue: advance,
                onBack: back)

        case .hotkey:
            HotkeyStep(hotkey: $settings.hotkey, onContinue: advance, onBack: back)

        case .options:
            OptionsStep(
                autoCopy: $settings.autoCopy,
                showLiveTranscription: $settings.showLiveTranscription,
                onContinue: advance,
                onBack: back)

        case .formatting:
            FormattingStep(
                enabled: settings.formatFinalTranscript,
                phase: FormatterStore.shared.phase,
                modelName: FormatterStore.shared.displayName,
                sizeDescription: FormatterStore.shared.approxSizeDescription,
                onEnable: {
                    // Opt in and start the download in the background; onboarding
                    // keeps moving and Settings has the full management UI.
                    env.settings.formatFinalTranscript = true
                    FormatterStore.shared.download()
                },
                onContinue: advance,
                onBack: back)

        case .tryIt:
            TryItStep(
                phase: env.appState.phase,
                lastTranscript: env.appState.lastTranscript,
                pasteAuthorized: env.appState.pasteAuthorized,
                hotkeyDisplay: settings.hotkey.displayString,
                onFinish: finish,
                onBack: back)
        }
    }

    /// The model to feature on the Model step: the chosen use case's pick, else
    /// whatever is currently selected, else nothing (a gentle "choose later").
    private var recommendedSpec: ModelSpec? {
        if let id = selectedUseCaseID, let profile = UseCaseCatalog.profile(id: id) {
            return profile.recommendedModel(for: languageCode)
        }
        if let id = env.settings.selectedModelID { return ModelCatalog.spec(id: id) }
        return nil
    }

    /// The user's ISO-639 language code (e.g. "en", "de") for language-aware model
    /// recommendations; defaults to English.
    private var languageCode: String {
        Locale(identifier: env.settings.localeIdentifier).language.languageCode?.identifier ?? "en"
    }

    // MARK: Navigation

    private func advance() {
        forward = true
        if stepIndex >= OnboardingStep.allCases.count - 1 {
            finish()
        } else {
            withAnimation(.smooth) { stepIndex += 1 }
        }
    }

    private func back() {
        forward = false
        withAnimation(.smooth) { stepIndex = max(0, stepIndex - 1) }
    }

    /// Global skip = accept every default, change nothing, mark complete.
    private func skipAll() { finish() }

    private func finish() { onComplete() }
}

// MARK: - Shared chrome

/// A little row of progress dots; the current (and prior) steps read as accent.
struct ProgressDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<max(count, 1), id: \.self) { i in
                Capsule()
                    .fill(i <= current ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.quaternary))
                    .frame(width: i == current ? 20 : 7, height: 7)
                    .animation(.smooth, value: current)
            }
        }
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// The shared layout every step composes: an accent-tinted icon header, a big
/// rounded title + subtitle, a (scrollable) content region, and a footer with an
/// optional Back, an optional secondary "skip"-style action, and a primary button.
struct OnboardingScaffold<Content: View>: View {
    var systemImage: String
    var title: String
    var subtitle: String
    var primaryTitle: String
    var primaryDisabled: Bool = false
    var onPrimary: () -> Void
    var secondaryTitle: String?
    var onSecondary: (() -> Void)?
    var onBack: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical) {
                content()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
                .padding(.top, 12)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.accent.opacity(0.16))
                    .frame(width: 68, height: 68)
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            Text(title)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let secondaryTitle, let onSecondary {
                Button(secondaryTitle, action: onSecondary)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Button(primaryTitle, action: onPrimary)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .controlSize(.large)
                .disabled(primaryDisabled)
                .keyboardShortcut(.defaultAction)
        }
    }
}

#if DEBUG
#Preview("Scaffold") {
    OnboardingScaffold(
        systemImage: "sparkles",
        title: "A sample step",
        subtitle: "One clear question per screen.",
        primaryTitle: "Continue",
        onPrimary: {},
        secondaryTitle: "Skip",
        onSecondary: {},
        onBack: {},
        content: {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .frame(height: 160)
        })
    .frame(width: 560, height: 640)
    .padding(28)
}
#endif
