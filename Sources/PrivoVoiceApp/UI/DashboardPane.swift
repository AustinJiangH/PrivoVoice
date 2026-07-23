// The Dashboard: how much you've dictated, made tangible.
//
// Leads with a playful equivalence ("≈ 1.3× the movie Titanic 🚢") so the raw
// hours mean something, then the hard numbers, then the opt-in telemetry control
// with full disclosure. Everything shown is computed locally from `UsageStats`.

import SwiftUI
import PrivoVoiceKit

struct DashboardPane: View {
    @Environment(AppEnvironment.self) private var env

    private var stats: UsageStats { env.telemetry.stats }

    var body: some View {
        @Bindable var settings = env.settings

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroCard

                // The hard numbers.
                HStack(spacing: 14) {
                    StatCard(icon: "clock.fill", tint: .blue,
                             value: Self.durationText(stats.totalSeconds),
                             label: "Transcribed")
                    StatCard(icon: "text.word.spacing", tint: .green,
                             value: Self.countText(stats.totalWords),
                             label: stats.totalWords == 1 ? "Word" : "Words")
                    StatCard(icon: "waveform", tint: .purple,
                             value: Self.countText(stats.totalSessions),
                             label: stats.totalSessions == 1 ? "Dictation" : "Dictations")
                }

                if let words = UsageEquivalents.forWords(stats.totalWords) {
                    equivalenceRow(
                        symbol: "books.vertical.fill",
                        text: "That's \(words.phrase) \(words.emoji) worth of words.")
                }

                telemetrySection(isOn: $settings.telemetryEnabled)

                if stats.totalSessions > 0 {
                    Button("Reset statistics", role: .destructive) {
                        stats.reset()
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Dashboard")
    }

    // MARK: Hero

    @ViewBuilder
    private var heroCard: some View {
        let equivalent = UsageEquivalents.forDuration(seconds: stats.totalSeconds)
        VStack(alignment: .leading, spacing: 8) {
            if let e = equivalent {
                Text(e.emoji)
                    .font(.system(size: 44))
                Text("You've dictated")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(e.phrase)   // already includes the anchor name
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text("— that's \(Self.durationText(stats.totalSeconds)) of speech turned into text, entirely on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                Text("🎙️").font(.system(size: 44))
                Text("Nothing dictated yet")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Hold your push-to-talk shortcut and speak. Your totals — and a fun comparison — show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private func equivalenceRow(symbol: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .font(.title3)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5)))
    }

    // MARK: Telemetry opt-in

    private func telemetrySection(isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isOn) {
                Text("Share anonymous usage stats")
                    .font(.headline)
            }
            Text("PrivoVoice is private by default — this is **off**, and nothing is ever sent unless you turn it on. "
                 + "When enabled, only anonymous **counts** (words, seconds, dictations) and **device info** "
                 + "(OS version, app version, model) leave your Mac. Your transcripts and audio never do. "
                 + "Turn it off any time, and it stays off — the Dashboard above keeps working either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5)))
    }

    // MARK: Formatting

    /// "3h 14m" / "12m 30s" / "45s" / "0s".
    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Grouped integer, e.g. "12,480".
    static func countText(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }
}

/// A single number tile in the stat row.
private struct StatCard: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5)))
    }
}
