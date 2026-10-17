import SwiftUI

/// File overview:
/// The Memory pane's statistics: how much memory holds, what it costs on disk and in RAM, and how
/// fast it searches and indexes.
///
/// Its own view so the Index section stays about settings. Presentation only: every figure is
/// measured elsewhere. Totals come from the sources' stats (`MemoryControlModel.sources`); sizes,
/// latencies and the indexing rate from the engine's status (`MemoryEngineStatus`), where searches
/// record their own timings (`MemoryLatencyStats`, the last 100 searches).
struct MemoryIndexStatsView: View {
    let status: MemoryEngineStatus
    let sources: [MemorySource]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            row("Stored", stored)
            row("Searchable", searchable)
            row("On disk", "Database \(Self.bytes(status.databaseBytes)) · Model \(Self.bytes(status.modelBytes))")
            row("In RAM", "Vectors \(Self.bytes(Int64(status.vectorBytes)))"
                + (status.dimensions > 0 ? " · \(status.dimensions.formatted()) dimensions per passage" : ""))
            row("Search", latency(status.searchLatency, noun: "searches"))
            row("Query embedding", latency(status.queryEmbeddingLatency, noun: "queries"))
            row("Indexing", indexing)
            if !status.modelName.isEmpty { row("Model", status.modelName) }
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    private var stored: String {
        let messages = sources.reduce(0) { $0 + $1.stats.messages }
        let conversations = sources.reduce(0) { $0 + $1.stats.conversations }
        let withMessages = sources.filter { $0.stats.messages > 0 }.count
        return "\(messages.formatted()) messages in \(conversations.formatted()) conversations from \(withMessages) "
            + (withMessages == 1 ? "source" : "sources")
    }

    private var searchable: String {
        var text = "\(status.passages.formatted()) passages"
        if status.pendingMessages > 0 { text += " · \(status.pendingMessages.formatted()) messages waiting to be indexed" }
        return text
    }

    private var indexing: String {
        guard let rate = status.passagesPerSecond, rate > 0 else { return "No run measured yet" }
        let speed = String(format: "%.0f passages/s", rate)
        guard status.pendingMessages > 0 else { return speed + " (last run)" }
        // Roughly one passage per message for chat; long mail is several, so this is a floor.
        let minutes = Double(status.pendingMessages) / rate / 60
        let remaining = minutes < 1 ? "under a minute" : String(format: "about %.0f min", minutes.rounded(.up))
        return "\(speed) · \(remaining) left while running"
    }

    private func latency(_ stats: MemoryLatencyStats, noun: String) -> String {
        guard let median = stats.median, let p95 = stats.p95 else { return "No \(noun) yet" }
        return "\(Self.milliseconds(median)) median · \(Self.milliseconds(p95)) p95 · last \(stats.samples.count) of "
            + "\(stats.total.formatted()) \(noun)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
        }
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func milliseconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }
}
