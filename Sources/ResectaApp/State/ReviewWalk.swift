import Foundation
import CoreGraphics
import RedactionEngine

// The review-origin walk's cursor — pure state over the staged
// detections (`RedactionState.pendingTriage`), so the pipeline review
// steps its rows from the parked strip the way the search walk steps
// its results: the same ‹ › pair, the same counter, the same match
// line, and in the Apply slot a one-tap Select (the row checkbox's
// sibling; the header's "Apply N" commits, as it always did). The sheet
// holds one as `@State`; the walk seam (`+Walk.swift`) re-anchors it
// against the live staged set on every read and steps it, and the
// canvas half of the seam frames the current row.
//
// Items are the review list's own order (`ScanReviewSection.flattenedFindings`:
// the page key ascending, then insertion) — every item carries its page
// beside the detection, because `DetectionResult` has no page of its
// own; the page is the dictionary key. The `.grouped` view mode walks
// the same flat items: a group has no cursor. Stepping wraps like
// `SearchState.navigateToNext` / `navigateToPrevious`; the first step
// from no current lands on the first (▼) or the last (▲) item.
//
// Re-anchoring: a group apply prunes members from the staged set under
// the cursor. A current that survives is kept; a current that vanished
// yields to the survivor at its old position (the item that slid into
// its slot), or to the new last item; an empty set clears the current.
// `ReviewWalkTests` pins the rules.

struct ReviewWalk: Equatable {

    /// One staged detection as the walk sees it: its page (the
    /// `pendingTriage` key) beside the detection.
    struct Item: Equatable {
        let page: Int
        let detection: DetectionResult

        var id: UUID { detection.id }
        /// 0–1, bottom-left — the `DetectionResult` convention the
        /// canvas half of the walk seam consumes.
        var rect: CGRect { detection.normalizedRect }

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.page == rhs.page && lhs.detection.id == rhs.detection.id
        }
    }

    private(set) var items: [Item]
    private(set) var currentID: UUID?

    init(items: [Item] = [], currentID: UUID? = nil) {
        self.items = items
        self.currentID = items.contains { $0.id == currentID } ? currentID : nil
    }

    /// The staged set in the review list's order.
    static func items(from pending: [Int: [DetectionResult]]?) -> [Item] {
        ScanReviewSection.flattenedFindings(pending).map { Item(page: $0.page, detection: $0.detection) }
    }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    var currentIndex: Int? {
        guard let currentID else { return nil }
        return items.firstIndex { $0.id == currentID }
    }

    var current: Item? {
        currentIndex.map { items[$0] }
    }

    /// ▼ — the next item, wrapping; the first item from no current.
    mutating func next() {
        guard !items.isEmpty else { return }
        let index = currentIndex.map { ($0 + 1) % items.count } ?? 0
        currentID = items[index].id
    }

    /// ▲ — the previous item, wrapping; the last item from no current.
    mutating func previous() {
        guard !items.isEmpty else { return }
        let index = currentIndex.map { ($0 - 1 + items.count) % items.count } ?? items.count - 1
        currentID = items[index].id
    }

    /// Make `id` the current (the review row tap). An id the set does
    /// not hold leaves the cursor as it was.
    mutating func focus(on id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        currentID = id
    }

    /// Re-anchor against a new staged set (the file comment's rule).
    mutating func update(items newItems: [Item]) {
        defer { items = newItems }
        guard let id = currentID else { return }
        if newItems.contains(where: { $0.id == id }) { return }
        guard !newItems.isEmpty, let oldIndex = currentIndex else {
            currentID = nil
            return
        }
        currentID = newItems[min(oldIndex, newItems.count - 1)].id
    }

    /// The row checkbox's toggle, for the strip's Select: an absent id
    /// reads as not selected (the review-first arrival rule), so the
    /// first tap selects and the next deselects.
    static func toggleSelection(of id: UUID, in selections: inout [UUID: Bool]) {
        selections[id] = !(selections[id] ?? false)
    }
}

// MARK: - The match line

extension ReviewWalk {
    /// The strip's line for the current row — `.empty` with no current
    /// (before the first step, or after the set emptied under it).
    func line(pageCount: Int) -> WalkLine {
        guard let item = current else { return .empty }
        return .match(WalkSummary(item: item, pageCount: pageCount))
    }
}

extension WalkSummary {
    /// The review origin's line: the kind = the category name the Scan
    /// search line uses (`PIICategory.rawValue`) when the kind has one,
    /// else the kind's full name (a face, a barcode, a possible
    /// signature); the page readout over the document; the matched
    /// text, absent for the kinds that carry none.
    init(item: ReviewWalk.Item, pageCount: Int) {
        let kind: String
        if case .pii(let piiKind) = item.detection.kind,
           let category = PIICategory(piiKind: piiKind) {
            kind = category.rawValue
        } else {
            kind = item.detection.kind.fullName
        }
        self.init(
            kind: kind,
            pageLabel: WalkSummary.pageLabel(pageIndex: item.page, pageCount: pageCount),
            text: item.detection.matchedText)
    }
}
