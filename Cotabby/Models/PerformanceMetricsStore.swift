import Combine
import Foundation

/// File overview:
/// In-memory + UserDefaults-backed ring buffer of the most recent LLM generation latencies.
/// Capped at `maximumEntries` so the persisted blob stays small and the Performance settings pane
/// renders a bounded list without virtualization. Records flow in from `SuggestionEngineRouter`
/// only when the user has enabled performance tracking in Settings, so the default user pays no
/// storage or write cost.

/// One recorded LLM request — kept intentionally narrow: just the three fields the
/// Performance pane shows. Codable so the whole array round-trips through UserDefaults
/// as a JSON blob.
struct PerformanceMetricEntry: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let timestamp: Date
    let modelName: String
    let latencyMs: Int

    init(id: UUID = UUID(), timestamp: Date = Date(), modelName: String, latencyMs: Int) {
        self.id = id
        self.timestamp = timestamp
        self.modelName = modelName
        self.latencyMs = latencyMs
    }
}

@MainActor
final class PerformanceMetricsStore: ObservableObject {
    /// Hard cap on retained entries. The UI assumes the entire list is renderable without
    /// virtualization, so growing this past a few hundred would require revisiting the pane.
    static let maximumEntries = 100

    @Published private(set) var entries: [PerformanceMetricEntry]

    private let userDefaults: UserDefaults
    private static let entriesDefaultsKey = "cotabbyPerformanceMetricEntries"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        entries = Self.loadEntries(from: userDefaults)
    }

    /// Append a new metric and drop the oldest entries above the cap. Persists after every record
    /// because the cap keeps the JSON blob small (well under 10 KB) and the write happens at most
    /// once per LLM request — far below any debouncing threshold.
    func record(modelName: String, latencyMs: Int, timestamp: Date = Date()) {
        let entry = PerformanceMetricEntry(
            timestamp: timestamp,
            modelName: modelName,
            latencyMs: latencyMs
        )
        var updated = entries
        updated.append(entry)
        if updated.count > Self.maximumEntries {
            updated.removeFirst(updated.count - Self.maximumEntries)
        }
        entries = updated
        persist(updated)
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        userDefaults.removeObject(forKey: Self.entriesDefaultsKey)
    }

    private func persist(_ entries: [PerformanceMetricEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            return
        }
        userDefaults.set(data, forKey: Self.entriesDefaultsKey)
    }

    private static func loadEntries(from userDefaults: UserDefaults) -> [PerformanceMetricEntry] {
        guard let data = userDefaults.data(forKey: Self.entriesDefaultsKey),
              let decoded = try? JSONDecoder().decode([PerformanceMetricEntry].self, from: data)
        else {
            return []
        }
        if decoded.count > maximumEntries {
            return Array(decoded.suffix(maximumEntries))
        }
        return decoded
    }
}
