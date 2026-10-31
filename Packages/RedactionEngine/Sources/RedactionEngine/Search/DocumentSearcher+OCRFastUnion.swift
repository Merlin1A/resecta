import CoreGraphics
import Foundation

// Text recognition on iOS 27 can lose a word on a scanned page that its
// fast read of the same image still has (a line read as noise, two words
// read as one). On iOS 27 the routes that search a scanned page's
// recognized text (the per-line literal path, the regex fallback and the
// PII Scan) also run over the page's fast read, and add what only it
// matched. iOS 26 reads one recognition, as before.
extension DocumentSearcher {

    /// Whether this OS reads the fast recognition beside the accurate one.
    nonisolated static var readsFastOCRBeside: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    /// The union of one route's matches over a page's accurate read and over
    /// its fast read. A fast match is the same match as an accurate one when
    /// both carry the same term and their boxes overlap by at least half the
    /// smaller box: that accurate match is kept, boxed by the union of the
    /// two boxes (the larger cover). Every other fast match is added.
    nonisolated static func unionFastOCRResults(
        accurate: [SearchResult], fast: [SearchResult]
    ) -> [SearchResult] {
        var merged = accurate
        for candidate in fast {
            if let index = accurate.indices.first(where: {
                accurate[$0].term == candidate.term
                    && overlapsHalfTheSmaller(accurate[$0].normalizedRect, candidate.normalizedRect)
            }) {
                merged[index] = merged[index].boxed(merged[index].normalizedRect.union(candidate.normalizedRect))
            } else {
                merged.append(candidate)
            }
        }
        return merged
    }

    /// Whether two boxes overlap by at least half the smaller one's area.
    nonisolated static func overlapsHalfTheSmaller(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && overlap.width * overlap.height >= 0.5 * smaller
    }
}

extension SearchResult {
    /// This result with another box; every other field kept.
    func boxed(_ rect: CGRect) -> SearchResult {
        SearchResult(
            id: id, pageIndex: pageIndex, normalizedRect: rect, matchedText: matchedText,
            contextSnippet: contextSnippet, source: source, term: term, isSelected: isSelected,
            piiCategory: piiCategory, piiConfidence: piiConfidence, rationale: rationale,
            matchRangeInSnippet: matchRangeInSnippet, occurrenceID: occurrenceID,
            textLayerRect: textLayerRect, inkFitDegraded: inkFitDegraded)
    }
}
