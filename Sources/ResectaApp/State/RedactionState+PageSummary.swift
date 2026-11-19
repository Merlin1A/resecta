import Foundation
import RedactionEngine

// The page menu's reads of the regions: pure functions of the regions
// dictionary and the page count, so they are tested without a state object.
// A page holds a box when its list of regions is not empty. A page whose last
// box was removed keeps an empty list, so pages are never counted by the
// dictionary's keys.

extension RedactionState {

    /// The nearest page after `page` that holds a box; nil when none follows.
    /// It never wraps round to the first page.
    static func nextPageWithRegions(after page: Int, in regions: [Int: [RedactionRegion]], pageCount: Int) -> Int? {
        let start = max(page + 1, 0)
        guard start < pageCount else { return nil }
        return (start..<pageCount).first { !(regions[$0]?.isEmpty ?? true) }
    }

    /// The nearest page before `page` that holds a box; nil when none comes
    /// before it. It never wraps round to the last page.
    static func previousPageWithRegions(before page: Int, in regions: [Int: [RedactionRegion]], pageCount: Int) -> Int? {
        let end = min(page, pageCount)
        guard end > 0 else { return nil }
        return (0..<end).reversed().first { !(regions[$0]?.isEmpty ?? true) }
    }

    /// Every box on the document's pages, counted as the page bar counts
    /// them page by page, and the number of pages that hold one.
    static func regionTotals(in regions: [Int: [RedactionRegion]], pageCount: Int) -> (regions: Int, pages: Int) {
        var boxes = 0, pages = 0
        for page in 0..<max(pageCount, 0) {
            let count = regions[page]?.count ?? 0
            boxes += count
            if count > 0 { pages += 1 }
        }
        return (boxes, pages)
    }

    /// The page a typed number names, from 1 to `pageCount`: digits only,
    /// spaces at its ends ignored, leading zeros allowed ("012" is page 12).
    /// Nil for anything else.
    static func typedPage(_ text: String, pageCount: Int) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard pageCount >= 1, !digits.isEmpty,
              digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let page = Int(digits), (1...pageCount).contains(page)
        else { return nil }
        return page
    }
}
