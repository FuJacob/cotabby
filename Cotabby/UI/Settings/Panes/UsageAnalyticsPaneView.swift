import Charts
import SwiftUI

/// File overview:
/// "Usage" detail pane (issue #489): local, privacy-preserving stats on how much the user has
/// accepted from Cotabby. It reads only the aggregated day buckets in `UsageAnalyticsStore`; there
/// is no raw text behind these numbers. A range picker switches the totals across 7 days / 30 days /
/// all time, a per-day bar chart shows the recent trend, and a confirmed Reset clears the store.
struct UsageAnalyticsPaneView: View {
    @ObservedObject var usageAnalyticsStore: UsageAnalyticsStore

    @State private var range: UsageAnalyticsRange = .last7Days
    @State private var isConfirmingReset = false

    var body: some View {
        SettingsPaneScaffold {
            Section {
                Picker("Time Range", selection: $range) {
                    ForEach(UsageAnalyticsRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                summaryTiles
            } header: {
                Text("Accepted Suggestions")
            } footer: {
                if isEmpty {
                    Text(
                        "Accept a suggestion with your accept key to start tracking. "
                            + "Everything here stays on this device."
                    )
                }
            }

            Section("Words Accepted per Day") {
                trendChart
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingReset = true
                } label: {
                    SettingsRowLabel(
                        title: "Reset Stats",
                        description: "Clear all recorded usage counts on this device.",
                        systemImage: "trash"
                    )
                }
                .disabled(isEmpty)
            } footer: {
                Text(
                    "All usage stats are stored locally. Cotabby never records the text you accept, "
                        + "which app you accept it in, or anything finer than a daily count."
                )
            }
        }
        .alert("Reset usage stats?", isPresented: $isConfirmingReset) {
            Button("Reset", role: .destructive) { usageAnalyticsStore.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently clears your accepted-suggestion, word, and character counts on "
                    + "this device. It cannot be undone."
            )
        }
    }

    // MARK: - Summary

    private var totals: UsageAnalyticsTotals {
        usageAnalyticsStore.totals(in: range)
    }

    /// "Has the user ever accepted anything?" It drives the empty-state hint and disables Reset. Keyed
    /// on all-time totals so switching to a quiet 7-day window still shows the (zeroed) tiles rather
    /// than the first-run hint.
    private var isEmpty: Bool {
        usageAnalyticsStore.totals(in: .allTime) == .zero
    }

    private var summaryTiles: some View {
        HStack(spacing: 12) {
            UsageStatTile(
                title: "Acceptances",
                value: totals.acceptances,
                systemImage: "checkmark.circle.fill",
                tint: .accentColor
            )
            UsageStatTile(
                title: "Words",
                value: totals.words,
                systemImage: "textformat",
                tint: .blue
            )
            UsageStatTile(
                title: "Characters",
                value: totals.characters,
                systemImage: "character",
                tint: .green
            )
        }
        .padding(.vertical, 4)
    }

    // MARK: - Trend chart

    /// Bars track the active range: a 7-day window shows seven daily bars, the wider windows show a
    /// fixed 30-day trail so the chart never grows unbounded for long-running installs.
    private var chartDays: Int {
        range == .last7Days ? 7 : 30
    }

    @ViewBuilder
    private var trendChart: some View {
        let series = usageAnalyticsStore.recentDailyBuckets(days: chartDays)
        if series.contains(where: { $0.words > 0 }) {
            Chart(series) { bucket in
                BarMark(
                    x: .value("Day", bucket.day, unit: .day),
                    y: .value("Words", bucket.words)
                )
                .foregroundStyle(Color.accentColor.gradient)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: chartDays > 7 ? 7 : 1)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 150)
            .padding(.vertical, 4)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .frame(height: 150)
                .overlay(
                    Text("No words accepted yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                )
                .padding(.vertical, 4)
        }
    }
}

/// One stat in the summary row: an icon, a large grouped number, and a caption. Kept private to the
/// pane since it only makes sense inside this dashboard layout.
private struct UsageStatTile: View {
    let title: String
    let value: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.large)
                .foregroundStyle(tint)
            Text(value.formatted())
                .font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.1))
        )
    }
}
