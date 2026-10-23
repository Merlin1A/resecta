import Foundation
import RedactionEngine

// The last-used filter shape, moved out of `SearchState.swift` along its
// `// MARK: - Last-used filter shape` and `// MARK: - Filter flush` seams:
// the stored shape, its key, the debounced write and the read the
// initializer hydrates from. The debounce task and the defaults stay
// stored on the class (an extension adds no storage).

extension SearchState {

    /// Codable bag of the three filter fields that restore across sheet
    /// sessions. `appliedFilter` is intentionally excluded — it is
    /// document-specific.
    struct LastSearchFilterShape: Codable, Sendable {
        var sourceFilter: SourceFilter
        var minimumOCRConfidence: Float
        var sortOrder: ResultSortOrder
    }

    static let lastFilterKey = "search.lastFilter.v1"

    // MARK: - Filter flush (debounced 500 ms)

    /// Schedule a debounced write of the current filter shape to
    /// UserDefaults. Cancels any pending write (mirrors flushTask
    /// idiom) so a slider drag does not write on every tick.
    func scheduleFilterFlush() {
        filterFlushTask?.cancel()
        filterFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.flushFilterShape()
        }
    }

    /// Write the current filter shape to UserDefaults synchronously.
    func flushFilterShape() {
        let shape = LastSearchFilterShape(
            sourceFilter: sourceFilter,
            minimumOCRConfidence: minimumOCRConfidence,
            sortOrder: sortOrder
        )
        if let data = try? JSONEncoder().encode(shape) {
            defaults.set(data, forKey: Self.lastFilterKey)
        }
    }

    /// The stored filter shape, or nil when it is missing or malformed
    /// (fail-closed: the in-type defaults then stand). Read by the
    /// initializer, which assigns the fields itself so no save-on-change
    /// observer runs during init.
    static func storedFilterShape(in defaults: UserDefaults) -> LastSearchFilterShape? {
        guard let data = defaults.data(forKey: lastFilterKey) else { return nil }
        return try? JSONDecoder().decode(LastSearchFilterShape.self, from: data)
    }
}
