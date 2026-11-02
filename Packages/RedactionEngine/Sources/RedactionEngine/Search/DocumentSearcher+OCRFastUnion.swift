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
    /// its fast read. Accurate matches of one term with one box (the matches
    /// on one recognised line) form a group; the fast matches of that term
    /// whose boxes overlap the group's by at least half the smaller box are
    /// its fast matches, each taken by one group only. When the fast read
    /// holds MORE matches there than the accurate read, the fast matches
    /// stand for the group, with their own boxes: the accurate read missed
    /// an occurrence, and one accurate box would answer for both (a hybrid
    /// page then drops it as a repeat of the text-layer occurrence, leaving
    /// the other unboxed). Otherwise each fast match pairs with one accurate
    /// match, which is kept, boxed by the union of the two (the larger
    /// cover). Every fast match no group took is added. Added matches take
    /// their place in page order; the accurate matches keep theirs.
    nonisolated static func unionFastOCRResults(
        accurate: [SearchResult], fast: [SearchResult]
    ) -> [SearchResult] {
        guard !fast.isEmpty else { return accurate }
        var groups: [[Int]] = []
        for index in accurate.indices {
            if let group = groups.firstIndex(where: {
                accurate[$0[0]].term == accurate[index].term
                    && accurate[$0[0]].normalizedRect == accurate[index].normalizedRect
            }) {
                groups[group].append(index)
            } else {
                groups.append([index])
            }
        }
        var merged = accurate
        var standsInFor = Set<Int>()   // accurate matches the fast ones replace
        var taken = Set<Int>()         // fast matches a group took
        var added: [SearchResult] = []
        for group in groups {
            let first = accurate[group[0]]
            let hits = fast.indices.filter {
                !taken.contains($0) && fast[$0].term == first.term
                    && overlapsHalfTheSmaller(first.normalizedRect, fast[$0].normalizedRect)
            }
            taken.formUnion(hits)
            if hits.count > group.count {
                standsInFor.formUnion(group)
                added += hits.map { fast[$0] }
            } else {
                for (a, f) in zip(group, hits) {
                    merged[a] = merged[a].boxed(merged[a].normalizedRect.union(fast[f].normalizedRect))
                }
            }
        }
        added += fast.indices.filter { !taken.contains($0) }.map { fast[$0] }
        var result = merged.indices.filter { !standsInFor.contains($0) }.map { merged[$0] }
        for match in added { insertInPageOrder(match, into: &result) }
        return result
    }

    /// Inserts `match` before the first result below it on the page, or, on
    /// the same row, before the first result to its right.
    nonisolated static func insertInPageOrder(_ match: SearchResult, into results: inout [SearchResult]) {
        let box = match.normalizedRect
        let index = results.firstIndex { other in
            let otherBox = other.normalizedRect
            if sharesRow(box, otherBox) { return box.minX < otherBox.minX }
            return otherBox.midY < box.midY   // bottom-left origin: lower on the page
        } ?? results.endIndex
        results.insert(match, at: index)
    }

    /// Whether two boxes overlap vertically by at least half the shorter one.
    nonisolated static func sharesRow(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxY, b.maxY) - max(a.minY, b.minY) >= 0.5 * min(a.height, b.height)
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
