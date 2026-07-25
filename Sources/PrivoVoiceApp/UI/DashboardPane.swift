// The Dashboard: how much you've dictated, made tangible.
//
// Leads with two hero totals (time + words), keeps the beloved playful
// equivalence ("≈ 1.3× the movie Titanic 🚢") so the raw hours mean something,
// then charts your usage over time, then the opt-in telemetry control with full
// disclosure. Everything shown is computed LOCALLY from `UsageStats` /
// `DictationLog` — nothing leaves the Mac unless you turn telemetry on.

import SwiftUI
import PrivoVoiceKit

struct DashboardPane: View {
    @Environment(AppEnvironment.self) private var env

    private var stats: UsageStats { env.telemetry.stats }
    private var log: DictationLog { env.telemetry.log }

    /// Mean audio length per dictation (0 when nothing has been recorded).
    private var avgSeconds: Double {
        stats.totalSessions > 0 ? stats.totalSeconds / Double(stats.totalSessions) : 0
    }
    /// Mean word count per dictation (0 when nothing has been recorded).
    private var avgWords: Int {
        stats.totalSessions > 0 ? Int((Double(stats.totalWords) / Double(stats.totalSessions)).rounded()) : 0
    }

    /// Days shown in the "Usage by day" chart.
    private static let chartDays = 14

    var body: some View {
        @Bindable var settings = env.settings

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // The playful equivalences — a beloved feature, and the delightful
                // centerpiece of the page: what you've dictated, made tangible,
                // BEFORE any raw numbers.
                equivalenceHero

                // Then the hard numbers: the two totals, 50/50, as the anchor of
                // the stats block below the playful hero.
                HStack(spacing: 14) {
                    BigStatCard(
                        icon: "clock.fill", tint: AppTheme.meterIn,
                        value: Self.durationText(stats.totalSeconds),
                        label: "Dictated")
                    BigStatCard(
                        icon: "text.word.spacing", tint: AppTheme.meterOut,
                        value: Self.countText(stats.totalWords),
                        label: stats.totalWords == 1 ? "Word" : "Words")
                }

                // Supporting hard numbers — the ones the two hero cards don't
                // already show, so nothing is repeated: total dictations, and the
                // average length + words per dictation.
                HStack(spacing: 14) {
                    StatCard(icon: "waveform", tint: AppTheme.meterHot,
                             value: Self.countText(stats.totalSessions),
                             label: stats.totalSessions == 1 ? "Dictation" : "Dictations")
                    StatCard(icon: "gauge.with.needle", tint: AppTheme.meterIn,
                             value: Self.durationText(avgSeconds),
                             label: "Avg length")
                    StatCard(icon: "text.word.spacing", tint: AppTheme.meterOut,
                             value: Self.countText(avgWords),
                             label: "Avg words")
                }

                // Charts, driven by the local per-dictation history.
                chartsSection

                telemetrySection(isOn: $settings.telemetryEnabled)

                if stats.totalSessions > 0 || !log.records.isEmpty {
                    Button("Reset statistics", role: .destructive) {
                        stats.reset()
                        log.reset()
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

    // MARK: Hero equivalence

    @ViewBuilder
    private var equivalenceHero: some View {
        let equivalent = UsageEquivalents.forDuration(seconds: stats.totalSeconds)
        let words = UsageEquivalents.forWords(stats.totalWords)
        VStack(alignment: .leading, spacing: 14) {
            if let e = equivalent {
                Text(e.emoji)
                    .font(.system(size: 64))
                    .shadow(color: AppTheme.accent.opacity(0.25), radius: 10, y: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text("You've dictated")
                        .font(.system(.title3, design: .rounded).weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(e.phrase)   // already includes the anchor name
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("— that's \(Self.durationText(stats.totalSeconds)) of speech turned into text, entirely on your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                // The words equivalence, folded into the hero as its playful
                // companion line (only when we have a comparison to draw).
                if let w = words {
                    HStack(spacing: 10) {
                        Text(w.emoji)
                            .font(.system(size: 26))
                        Text(Self.wordsLine(phrase: w.phrase))
                    }
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.background.opacity(0.35)))
                }
            } else {
                Text("🎙️").font(.system(size: 64))
                Text("Nothing dictated yet")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                Text("Hold your push-to-talk shortcut and speak. Your totals — and a fun comparison — show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(26)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(
                    colors: [AppTheme.accent.opacity(0.22), AppTheme.accent.opacity(0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(AppTheme.accent.opacity(0.18), lineWidth: 1)))
    }

    // MARK: Charts

    private var chartsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            UsageByDayChart(buckets: log.dailyTotals(days: Self.chartDays))
            HStack(alignment: .top, spacing: 14) {
                WhenYouDictateChart(buckets: log.hourlyDistribution())
                ByModelChart(buckets: log.modelTotals())
            }
        }
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

    /// The words-equivalence companion line with the phrase accented and bold,
    /// built as an `AttributedString` so only the phrase carries the emphasis.
    static func wordsLine(phrase: String) -> AttributedString {
        var line = AttributedString("That's ")
        var accented = AttributedString(phrase)
        accented.foregroundColor = AppTheme.accent
        accented.font = .system(.body, design: .rounded).weight(.bold)
        line += accented
        line += AttributedString(" worth of words.")
        return line
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

/// A large hero metric tile — half the width, tinted, the visual anchor of the
/// Dashboard.
private struct BigStatCard: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(
                    colors: [tint.opacity(0.20), tint.opacity(0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)))
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
