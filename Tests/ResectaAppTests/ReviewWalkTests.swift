import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The review-origin walk's cursor (`ReviewWalk`), pinned without a
// SwiftUI host: the item order, the wrap, the re-anchor on removal, the
// selection toggle, the match line, the empty set.

@Suite("Review walk")
@MainActor
struct ReviewWalkTests {

    private func detection(
        _ text: String?, kind: DetectionResult.Kind = .pii(.ssn), x: CGFloat = 0.1
    ) -> DetectionResult {
        DetectionResult(
            normalizedRect: CGRect(x: x, y: 0.5, width: 0.2, height: 0.03),
            kind: kind, confidence: 0.9, matchedText: text)
    }

    @Test("Items follow the review list's order — the page key ascending, then insertion; the view mode plays no part")
    func order() {
        let a = detection("a"), b = detection("b"), c = detection("c"), d = detection("d", x: 0.4)
        let pending: [Int: [DetectionResult]] = [2: [d], 0: [a, b], 1: [c]]
        let items = ReviewWalk.items(from: pending)
        #expect(items.map(\.id) == [a.id, b.id, c.id, d.id])
        #expect(items.map(\.page) == [0, 0, 1, 2])
        #expect(items[3].rect == d.normalizedRect)
        // `.grouped` renders groups but keeps the flat order beneath —
        // the walk steps the same items in every view mode.
        let grouped = ScanReviewSection.filteredFindings(
            ScanReviewSection.flattenedFindings(pending), filterKind: nil, viewMode: .grouped)
        #expect(grouped.map(\.detection.id) == items.map(\.id))
        #expect(ReviewWalk.items(from: nil).isEmpty)
    }

    @Test("▼ and ▲ wrap; the first step lands on the first (▼) or the last (▲) item")
    func wrap() {
        let items = ReviewWalk.items(from: [0: [detection("a"), detection("b"), detection("c")]])
        var walk = ReviewWalk(items: items)
        #expect(walk.current == nil && walk.currentIndex == nil && walk.count == 3)
        walk.next()
        #expect(walk.currentIndex == 0)
        walk.next(); walk.next()
        #expect(walk.currentIndex == 2)
        walk.next()
        #expect(walk.currentIndex == 0, "▼ from the last item wraps to the first")
        walk.previous()
        #expect(walk.currentIndex == 2, "▲ from the first item wraps to the last")
        var fresh = ReviewWalk(items: items)
        fresh.previous()
        #expect(fresh.currentIndex == 2, "the first ▲ lands on the last item")
    }

    @Test("A current that vanishes re-anchors to the survivor at its old position, or the new last; a surviving current is kept; an empty set clears it")
    func reanchorOnRemoval() {
        let a = detection("a"), b = detection("b"), c = detection("c"), d = detection("d")
        var walk = ReviewWalk(items: ReviewWalk.items(from: [0: [a, b, c, d]]), currentID: b.id)
        // The current survives a prune elsewhere.
        walk.update(items: ReviewWalk.items(from: [0: [a, b, d]]))
        #expect(walk.currentID == b.id && walk.count == 3)
        // The current itself is pruned: the item that slid into its slot.
        walk.update(items: ReviewWalk.items(from: [0: [a, d]]))
        #expect(walk.currentID == d.id, "b's slot (index 1) now holds d")
        // The current was last and is pruned: the new last.
        walk.update(items: ReviewWalk.items(from: [0: [a]]))
        #expect(walk.currentID == a.id)
        // Everything gone.
        walk.update(items: [])
        #expect(walk.currentID == nil && walk.current == nil && walk.isEmpty)
        // A cursor with no current stays that way through an update.
        var idle = ReviewWalk(items: ReviewWalk.items(from: [0: [a]]))
        idle.update(items: ReviewWalk.items(from: [0: [a, b]]))
        #expect(idle.currentID == nil && idle.count == 2)
    }

    @Test("focus(on:) makes a held id current and ignores an unknown one; the init drops an unknown current")
    func focus() {
        let a = detection("a"), b = detection("b")
        var walk = ReviewWalk(items: ReviewWalk.items(from: [0: [a, b]]))
        walk.focus(on: b.id)
        #expect(walk.currentIndex == 1)
        walk.focus(on: UUID())
        #expect(walk.currentID == b.id)
        #expect(ReviewWalk(items: walk.items, currentID: UUID()).currentID == nil)
    }

    @Test("The selection toggle: an absent id selects, a selected one deselects, a deselected one selects again")
    func selectToggle() {
        let id = UUID()
        var selections: [UUID: Bool] = [:]
        ReviewWalk.toggleSelection(of: id, in: &selections)
        #expect(selections[id] == true)
        ReviewWalk.toggleSelection(of: id, in: &selections)
        #expect(selections[id] == false)
        ReviewWalk.toggleSelection(of: id, in: &selections)
        #expect(selections[id] == true)
    }

    @Test("The match line: the Scan category name · Page k of N · the matched text; the kind's full name and no text for a face; empty before the first step")
    func line() {
        let ssn = detection("123-45-6789")
        let face = detection(nil, kind: .face)
        var walk = ReviewWalk(items: ReviewWalk.items(from: [1: [ssn], 3: [face]]))
        #expect(walk.line(pageCount: 5) == .empty)
        walk.next()
        #expect(walk.line(pageCount: 5)
                == .match(WalkSummary(kind: "SSN", pageLabel: "Page 2 of 5", text: "123-45-6789")))
        walk.next()
        #expect(walk.line(pageCount: 5)
                == .match(WalkSummary(kind: "Detected Face", pageLabel: "Page 4 of 5", text: nil)))
        // The same label the search line uses.
        #expect(WalkSummary.pageLabel(pageIndex: 1, pageCount: 5) == SearchState.walkPageLabel(pageIndex: 1, pageCount: 5))
    }

    @Test("An empty set: no current, the steps are no-ops, the line is empty")
    func empty() {
        var walk = ReviewWalk()
        walk.next(); walk.previous(); walk.focus(on: UUID())
        #expect(walk.isEmpty && walk.current == nil && walk.line(pageCount: 1) == .empty)
        #expect(walk == ReviewWalk())
    }
}
