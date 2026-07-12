import CoreGraphics

// Vision line-box merging.
// Groups OCR lines into rows by y-proximity then merges intra-row lines by
// x-proximity so downstream Phase-3 address / name detectors see coherent
// spatial regions instead of raw Vision observations.
//
// Thresholds are hardcoded placeholders per plan §5 and DataPipeline
// CLAUDE.md §2.3 — device validation on iPhone 17 pending. Jesse replaces
// `Constants.xGap` / `Constants.yGap` via PR once real-device measurements
// land; until then this merger is conservative (small thresholds → fewer
// false merges).
//
// No call site in Phase 2. Phase 3 address detector will be the first caller.

struct BoundingBoxMerger: Sendable {

    enum Constants {
        /// Maximum horizontal gap (normalized) between two boxes in the same
        /// row before they stop merging. Placeholder per plan §5; finalize on
        /// iPhone 17 A19 per DataPipeline CLAUDE.md §2.3.
        static let xGap: CGFloat = 0.015

        /// Maximum vertical distance (normalized) between two lines before
        /// they split into separate rows. Same placeholder caveat as `xGap`.
        static let yGap: CGFloat = 0.020
    }

    /// One merged spatial region. `sourceLineIndices` references the indices
    /// in the input array that were folded into this region, preserved in
    /// reading order (left-to-right within the row).
    struct MergedRegion: Sendable, Equatable {
        let text: String
        let unionRect: CGRect
        let sourceLineIndices: [Int]
    }

    init() {}

    /// Merge OCR line observations into row-major spatial regions.
    ///
    /// Algorithm (row-then-column):
    /// 1. Pair each line with its input index and sort top-to-bottom
    ///    (Vision normalized coords are bottom-left origin, so descending
    ///    `minY`).
    /// 2. Group consecutive lines into a row when the minY delta is
    ///    ≤ `Constants.yGap`.
    /// 3. Within each row, sort left-to-right (ascending `minX`) and merge
    ///    consecutive lines when their x-gap is ≤ `Constants.xGap`. Merged
    ///    text is space-joined; the union rect is the bounding box of all
    ///    participants.
    func merge(_ lines: [OCREngine.TextLine]) -> [MergedRegion] {
        guard !lines.isEmpty else { return [] }

        let indexed = lines.enumerated().map { (index: $0.offset, line: $0.element) }
        let sortedByY = indexed.sorted { $0.line.normalizedRect.minY > $1.line.normalizedRect.minY }

        // Group by row.
        var rows: [[(index: Int, line: OCREngine.TextLine)]] = []
        var currentRow: [(index: Int, line: OCREngine.TextLine)] = []
        var currentRowY: CGFloat = 0

        for entry in sortedByY {
            if currentRow.isEmpty {
                currentRow.append(entry)
                currentRowY = entry.line.normalizedRect.minY
            } else if abs(entry.line.normalizedRect.minY - currentRowY) <= Constants.yGap {
                currentRow.append(entry)
            } else {
                rows.append(currentRow)
                currentRow = [entry]
                currentRowY = entry.line.normalizedRect.minY
            }
        }
        if !currentRow.isEmpty { rows.append(currentRow) }

        // Merge within each row.
        var regions: [MergedRegion] = []
        for row in rows {
            let sortedByX = row.sorted { $0.line.normalizedRect.minX < $1.line.normalizedRect.minX }
            var runs: [[(index: Int, line: OCREngine.TextLine)]] = []
            var currentRun: [(index: Int, line: OCREngine.TextLine)] = []

            for entry in sortedByX {
                if let prev = currentRun.last {
                    let gap = entry.line.normalizedRect.minX - prev.line.normalizedRect.maxX
                    if gap <= Constants.xGap {
                        currentRun.append(entry)
                        continue
                    }
                    runs.append(currentRun)
                    currentRun = [entry]
                } else {
                    currentRun = [entry]
                }
            }
            if !currentRun.isEmpty { runs.append(currentRun) }

            for run in runs {
                let text = run.map(\.line.text).joined(separator: " ")
                var rect = run.first!.line.normalizedRect
                for entry in run.dropFirst() {
                    rect = rect.union(entry.line.normalizedRect)
                }
                regions.append(MergedRegion(
                    text: text,
                    unionRect: rect,
                    sourceLineIndices: run.map(\.index)
                ))
            }
        }

        return regions
    }
}
