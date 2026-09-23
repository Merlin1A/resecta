import CoreGraphics
import Foundation

/// The per-session OCR page caches `DocumentSearcher` owns: the verbatim
/// Vision lines per page, the LRU access order that drives eviction, and the
/// parallel cache of normalized PII-scan inputs, keyed identically and
/// evicted in lockstep. A synchronous value type: every mutation runs on the
/// owning actor with no suspension point.
struct OCRPageCache {

    /// Maximum cached pages before the least-recently-used entry is evicted.
    static let maxEntries = 50

    /// A page's normalized PII-scan input: the confusable-corrected lines
    /// joined with "\n" and, per line, its offset into that concatenation.
    /// The PII path (`scanPagePIIViaOCR`) reads this cache; user text search
    /// (`searchPageViaOCR`) reads the verbatim lines. The normalizer runs
    /// once per page at cache-miss time; cached results stay authoritative.
    struct NormalizedPage {
        let concatenated: String
        let entries: [NormalizedLineEntry]
    }
    struct NormalizedLineEntry {
        let start: Int
        let normalizedText: String
        let normalizedRect: CGRect
        let confidence: Float
    }

    /// Verbatim Vision lines per page index.
    private var lines: [Int: [OCREngine.TextLine]] = [:]
    /// LRU access tracking for eviction.
    private var access: [Int: Int] = [:]
    private var counter: Int = 0
    /// The normalized PII-scan inputs, keyed identically to `lines`.
    private var normalized: [Int: NormalizedPage] = [:]

    /// A cache hit: records the access for eviction ordering and returns
    /// the page's lines; nil on a miss.
    mutating func touch(_ pageIndex: Int) -> [OCREngine.TextLine]? {
        guard let cached = lines[pageIndex] else { return nil }
        counter += 1
        access[pageIndex] = counter
        return cached
    }

    /// Inserts a page's lines through the eviction path (evict BEFORE
    /// insert) and records the access.
    mutating func insert(_ newLines: [OCREngine.TextLine], for pageIndex: Int) {
        evictIfNeeded()
        counter += 1
        access[pageIndex] = counter
        lines[pageIndex] = newLines
    }

    /// Evicts the least-recently-used entry when the capacity ceiling is
    /// reached. `lines` and `normalized` are always evicted in lockstep so
    /// the two parallel caches never diverge. Called BEFORE inserting a new
    /// entry.
    mutating func evictIfNeeded() {
        if lines.count >= Self.maxEntries {
            if let lruPage = access.min(by: { $0.value < $1.value })?.key {
                lines.removeValue(forKey: lruPage)
                access.removeValue(forKey: lruPage)
                normalized.removeValue(forKey: lruPage)
            }
        }
    }

    /// The page's normalized PII-scan input, when built.
    func normalizedPage(for pageIndex: Int) -> NormalizedPage? {
        normalized[pageIndex]
    }

    /// Records the page's normalized PII-scan input.
    mutating func setNormalizedPage(_ page: NormalizedPage, for pageIndex: Int) {
        normalized[pageIndex] = page
    }

    #if DEBUG
    // MARK: - Test seams (observation / seeding only; DocumentSearcher forwards to them)

    var cachedKeys: Set<Int> { Set(lines.keys) }
    var normalizedKeys: Set<Int> { Set(normalized.keys) }

    /// One page's cached lines without touching the access order.
    func cachedLines(forPageIndex pageIndex: Int) -> [OCREngine.TextLine]? {
        lines[pageIndex]
    }

    /// Seeds the caches with `occupiedCount` placeholder entries, inserted
    /// in ascending page-index order so the smallest index is the
    /// least-recently-used. Page indices equal to `skippingPageIndex` are
    /// skipped so a subsequent OCR pass on that page forces a miss + LRU
    /// eviction — driving the production eviction code path under test.
    mutating func seedForCoherence(skippingPageIndex: Int, occupiedCount: Int) {
        lines.removeAll()
        access.removeAll()
        normalized.removeAll()
        counter = 0
        var added = 0
        var idx = 0
        while added < occupiedCount {
            if idx != skippingPageIndex {
                counter += 1
                access[idx] = counter
                lines[idx] = []
                normalized[idx] = NormalizedPage(concatenated: "", entries: [])
                added += 1
            }
            idx += 1
        }
    }

    /// Seeds known lines for a page. The normalized entry is NOT pre-seeded
    /// (the PII path rebuilds it on demand; the text/regex paths do not
    /// read it); a stale entry is dropped so a subsequent PII scan rebuilds
    /// it from the newly seeded raw lines.
    mutating func seedLines(_ newLines: [OCREngine.TextLine], forPageIndex pageIndex: Int) {
        counter += 1
        access[pageIndex] = counter
        lines[pageIndex] = newLines
        normalized.removeValue(forKey: pageIndex)
    }
    #endif
}
