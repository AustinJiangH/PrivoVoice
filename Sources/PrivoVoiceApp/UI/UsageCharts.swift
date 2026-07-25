// The Dashboard's usage charts, driven entirely by the LOCAL `DictationLog`.
//
// Three Swift Charts views — usage by day, when-of-day, and by model — each
// wrapped in a titled card that matches the Dashboard's other cards. All data is
// computed on-device; nothing here ever leaves the Mac.

import SwiftUI
import Charts
import PrivoVoiceKit

/// A titled card wrapper matching the Dashboard's card styling, with a tasteful
/// empty state when there's no data to plot yet.
struct ChartCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isEmpty: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.accent)
                Text(title)
                    .font(.headline)
            }
            if isEmpty {
                emptyState
            } else {
                content
                    .frame(height: 180)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5)))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No data yet")
                .font(.subheadline.weight(.medium))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
    }
}

/// Bar chart of dictation time per day over the last `days` days.
struct UsageByDayChart: View {
    let buckets: [DayBucket]

    private var hasData: Bool { buckets.contains { $0.count > 0 } }

    var body: some View {
        ChartCard(
            title: "Usage by day",
            subtitle: "Dictate something and your daily minutes show up here.",
            systemImage: "calendar",
            isEmpty: !hasData
        ) {
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Day", bucket.day, unit: .day),
                    y: .value("Minutes", bucket.seconds / 60))
                .foregroundStyle(AppTheme.meterIn)
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let m = value.as(Double.self) {
                            Text("\(Int(m))m")
                        }
                    }
                }
            }
        }
    }
}

/// Bar chart of dictation count by hour of day (0–23).
struct WhenYouDictateChart: View {
    let buckets: [HourBucket]

    private var hasData: Bool { buckets.contains { $0.count > 0 } }

    var body: some View {
        ChartCard(
            title: "When you dictate",
            subtitle: "We'll chart your busiest hours as you use PrivoVoice.",
            systemImage: "clock",
            isEmpty: !hasData
        ) {
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Hour", bucket.hour),
                    y: .value("Dictations", bucket.count))
                .foregroundStyle(AppTheme.meterOut)
                .cornerRadius(2)
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let h = value.as(Int.self) {
                            Text(Self.hourLabel(h))
                        }
                    }
                }
            }
        }
    }

    /// "12a", "6a", "12p", "6p", "11p".
    static func hourLabel(_ hour: Int) -> String {
        let suffix = hour < 12 ? "a" : "p"
        var h = hour % 12
        if h == 0 { h = 12 }
        return "\(h)\(suffix)"
    }
}

/// Bar chart of total dictation time per model.
struct ByModelChart: View {
    let buckets: [ModelBucket]

    private var hasData: Bool { buckets.contains { $0.count > 0 } }

    var body: some View {
        ChartCard(
            title: "By model",
            subtitle: "Once you dictate, time spent per model appears here.",
            systemImage: "cpu",
            isEmpty: !hasData
        ) {
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Minutes", bucket.seconds / 60),
                    y: .value("Model", bucket.displayName))
                .foregroundStyle(AppTheme.meterHot)
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let m = value.as(Double.self) {
                            Text("\(Int(m))m")
                        }
                    }
                }
            }
        }
    }
}
