import Charts
import SwiftUI

/// File overview:
/// "Performance" detail pane of the redesigned Settings window. Combines two things a debugging
/// session wants side by side: an opt-in, persisted log of per-request latencies (the table, plus a
/// trend graph) and an always-live view of the app's own CPU and memory footprint. The live graphs
/// only sample while this pane is on screen — `onAppear`/`onDisappear` drive `SystemMetricsStore` so
/// there is zero background cost when the pane is closed. The latency table stays inert until the
/// user enables tracking, since `SuggestionEngineRouter` short-circuits the recorder when it's off.
struct PerformancePaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var performanceMetricsStore: PerformanceMetricsStore
    @ObservedObject var qualityMetricsStore: SuggestionQualityMetricsStore
    @ObservedObject var systemMetricsStore: SystemMetricsStore

    var body: some View {
        SettingsPaneScaffold {
            liveResourceSection

            suggestionQualitySection

            Section("Tracking") {
                Toggle(isOn: trackingEnabledBinding) {
                    SettingsRowLabel(
                        title: "Enable Performance Tracking",
                        description: "Record the timestamp, model, and elapsed time of every LLM " +
                            "request. Only the most recent " +
                            "\(PerformanceMetricsStore.maximumEntries) requests are retained.",
                        systemImage: "stopwatch"
                    )
                }
                .settingsItem(.performanceTracking)
            }

            Section {
                // Both branches carry the anchor; only one exists at a time, so the scroll target
                // stays unique whichever state the log is in.
                if performanceMetricsStore.entries.isEmpty {
                    Text(emptyStateMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .settingsItem(.recentRequests)
                } else {
                    latencyChart
                        .settingsItem(.recentRequests)
                    metricsTable
                }
            } header: {
                HStack {
                    Text(historyHeaderLabel)
                    Spacer()
                    if !performanceMetricsStore.entries.isEmpty {
                        Button("Clear") {
                            performanceMetricsStore.clear()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }
        }
        // Sampling is scoped to visibility: the detail pane is rebuilt (`.id(selection)`) on every
        // sidebar switch, so these fire reliably as the user navigates in and out of Performance.
        .onAppear { systemMetricsStore.beginSampling() }
        .onDisappear { systemMetricsStore.endSampling() }
    }

    // MARK: - Suggestion quality counters

    /// Lifetime counters: how often suggestions appear, why withheld ones were withheld, and how
    /// many shown suggestions the user accepted. Always on (counters carry no content), unlike the
    /// per-request latency log below, which records timestamps and stays opt-in.
    private var suggestionQualitySection: some View {
        Section {
            qualityCounterRow(label: "Suggestions shown", value: "\(qualityMetricsStore.counters.shown)")
                .settingsItem(.suggestionQualityStats)
            qualityCounterRow(label: "Accepted", value: acceptedLabel)
            qualityCounterRow(label: "Generations", value: "\(qualityMetricsStore.counters.generated)")
            if !topSuppressionReasons.isEmpty {
                qualityCounterRow(
                    label: "Withheld (\(qualityMetricsStore.counters.suppressedTotal))",
                    value: topSuppressionReasons
                )
            }
        } header: {
            HStack {
                Text(qualityHeaderLabel)
                Spacer()
                if qualityMetricsStore.counters.shown > 0 || qualityMetricsStore.counters.generated > 0 {
                    Button("Reset") {
                        qualityMetricsStore.reset()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
    }

    private func qualityCounterRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var acceptedLabel: String {
        let accepted = qualityMetricsStore.counters.acceptedSuggestions
        guard let rate = qualityMetricsStore.counters.acceptanceRate else {
            return "\(accepted)"
        }
        return "\(accepted) (\(Int((rate * 100).rounded()))%)"
    }

    private var topSuppressionReasons: String {
        qualityMetricsStore.counters.suppressedByReason
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
            .prefix(4)
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
    }

    private var qualityHeaderLabel: String {
        guard let since = qualityMetricsStore.counters.firstRecordedAt else {
            return "Suggestion Quality"
        }
        let formatted = since.formatted(date: .abbreviated, time: .omitted)
        return "Suggestion Quality (since \(formatted))"
    }

    // MARK: - Live resource graphs

    private var liveResourceSection: some View {
        Section {
            MetricSparkline(
                points: cpuPoints,
                yDomainUpper: cpuDomainUpper,
                tint: .blue,
                valueLabel: cpuCurrentLabel
            )
            .settingsItem(.resourceUsage)
            MetricSparkline(
                points: ramPoints,
                yDomainUpper: ramDomainUpperMB,
                tint: .green,
                valueLabel: ramCurrentLabel
            )
        } header: {
            Text("Live Resource Usage")
        } footer: {
            Text(
                "Updated every second while this pane is open. CPU can exceed 100% across multiple " +
                "cores. Memory is the app's physical footprint."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var cpuPoints: [MetricSparkline.Point] {
        systemMetricsStore.samples.map {
            MetricSparkline.Point(id: String($0.id), label: "CPU", date: $0.timestamp, value: $0.cpuPercent)
        }
    }

    private var ramPoints: [MetricSparkline.Point] {
        systemMetricsStore.samples.map {
            MetricSparkline.Point(
                id: String($0.id),
                label: "Memory",
                date: $0.timestamp,
                value: Double($0.footprintBytes) / Self.bytesPerMB
            )
        }
    }

    /// Headroom above the recent peak so the line never clips the top of the frame. CPU never
    /// dips below a 100% ceiling so single-core spikes read against a familiar reference.
    private var cpuDomainUpper: Double {
        let peak = systemMetricsStore.samples.map(\.cpuPercent).max() ?? 0
        return max(100, peak * 1.2)
    }

    private var ramDomainUpperMB: Double {
        let peakMB = ramPoints.map(\.value).max() ?? 0
        return max(128, peakMB * 1.2)
    }

    private var cpuCurrentLabel: String {
        guard let latest = systemMetricsStore.samples.last else { return "—" }
        return String(format: "%.0f%%", latest.cpuPercent)
    }

    private var ramCurrentLabel: String {
        guard let latest = systemMetricsStore.samples.last else { return "—" }
        let mb = Double(latest.footprintBytes) / Self.bytesPerMB
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Latency trend graph

    private var latencyChart: some View {
        MetricSparkline(
            points: latencyPoints,
            yDomainUpper: latencyDomainUpper,
            tint: .orange,
            valueLabel: latencyCurrentLabel
        )
    }

    private var latencyPoints: [MetricSparkline.Point] {
        performanceMetricsStore.entries.map {
            MetricSparkline.Point(
                id: $0.id.uuidString,
                label: "Latency",
                date: $0.timestamp,
                value: Double($0.latencyMs)
            )
        }
    }

    private var latencyDomainUpper: Double {
        let peak = performanceMetricsStore.entries.map { Double($0.latencyMs) }.max() ?? 0
        return max(100, peak * 1.2)
    }

    private var latencyCurrentLabel: String {
        guard let latest = performanceMetricsStore.entries.last else { return "—" }
        return "\(latest.latencyMs) ms"
    }

    // MARK: - History table

    private var metricsTable: some View {
        // Newest-first reads more naturally for the "what just happened" use case. The underlying
        // store keeps insertion order so we reverse here without mutating the source of truth.
        let reversed = Array(performanceMetricsStore.entries.reversed())
        return VStack(spacing: 0) {
            tableHeader
            Divider()
            ForEach(Array(reversed.enumerated()), id: \.element.id) { index, entry in
                metricRow(for: entry)
                if index < reversed.count - 1 {
                    Divider().opacity(0.3)
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("Time")
                .frame(width: 130, alignment: .leading)
            Text("Model")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Duration")
                .frame(width: 90, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    private func metricRow(for entry: PerformanceMetricEntry) -> some View {
        HStack(spacing: 12) {
            Text(Self.timestampFormatter.string(from: entry.timestamp))
                .frame(width: 130, alignment: .leading)
                .monospacedDigit()
            Text(entry.modelName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(entry.latencyMs) ms")
                .frame(width: 90, alignment: .trailing)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    // MARK: - Bindings

    private var trackingEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isPerformanceTrackingEnabled },
            set: { suggestionSettings.setPerformanceTrackingEnabled($0) }
        )
    }

    // MARK: - Helpers

    private var historyHeaderLabel: String {
        let count = performanceMetricsStore.entries.count
        let cap = PerformanceMetricsStore.maximumEntries
        if count == 0 {
            return "Recent Requests"
        }
        return "Recent Requests (\(count) of \(cap))"
    }

    private var emptyStateMessage: String {
        if suggestionSettings.isPerformanceTrackingEnabled {
            return "No requests recorded yet. Trigger a suggestion to start populating this list."
        }
        return "Performance tracking is off. Enable the toggle above to start recording requests."
    }

    private static let bytesPerMB: Double = 1024 * 1024

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// A compact filled line graph for a single time series (CPU, memory, or latency). Renders a header
/// with the metric name and its current value, then a fixed-height area+line chart. Kept generic
/// over plain `Point`s so the pane can feed it three different sources without leaking chart code
/// into the pane body.
private struct MetricSparkline: View {
    struct Point: Identifiable {
        // A `String` identity lets each source supply a naturally unique key (a UUID's `uuidString`
        // for latency, the monotonic sample counter for CPU/RAM) without lossily folding a 128-bit
        // UUID down into a collision-prone integer.
        let id: String
        let label: String
        let date: Date
        let value: Double
    }

    let points: [Point]
    let yDomainUpper: Double
    let tint: Color
    let valueLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(points.first?.label ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(valueLabel)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            chart
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var chart: some View {
        if points.isEmpty {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .frame(height: 110)
                .overlay(
                    Text("Collecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                )
        } else {
            Chart(points) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value(point.label, point.value)
                )
                .foregroundStyle(tint.opacity(0.15))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value(point.label, point.value)
                )
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...yDomainUpper)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
            }
            .frame(height: 110)
        }
    }
}
