import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// 500-region cap on `RedactionState.applyBatch`.
// The lasso marquee path routes its hit set through `applyBatch`; on
// large documents an indiscriminate marquee could land thousands of
// regions in one gesture. The cap is a defense against an accidental
// select-all — when input > 500, `applyBatch` truncates to the first
// 500 (by stored order) and says so once: while Add to Selection is on
// (its capsule holds the slot) by the `.warning` toast, as at 1.3.1; with
// the selection bar showing, by the cut it records (`lassoCut`), which the
// bar shows as its second line.
//
// These tests pin two contracts:
// 1. `applyBatch` truncates input > 500 to exactly 500 and says so once,
//    by the warning or by the bar's line, never both.
// 2. The kept set is the *first 500* by input order — preserving the
//    caller's stable ordering so future callers (sort-by-coverage,
//    sort-by-detection-confidence) can drive truncation deterministically.

@Suite("ApplyBatch 500-region cap")
@MainActor
struct ApplyBatchCapTests {

    /// Build N regions tiled across the page so each has a distinct
    /// normalizedRect. The ordering of the returned array is stable —
    /// region `i` always carries the same UUID across runs because the
    /// IDs are generated in order and captured back in the array.
    private func fabricateRegions(count: Int) -> [RedactionRegion] {
        var made: [RedactionRegion] = []
        for i in 0..<count {
            // Tiny rectangles tiled to keep them distinct without
            // overflowing the 0–1 normalized range. Coords don't matter
            // for cap arithmetic — only the count and stable order do.
            let region = RedactionRegion(
                id: UUID(),
                normalizedRect: CGRect(
                    x: Double(i % 100) * 0.005 + 0.001,
                    y: Double(i / 100) * 0.005 + 0.001,
                    width: 0.004,
                    height: 0.004
                ),
                source: .manual
            )
            made.append(region)
        }
        return made
    }

    // MARK: - Cap arithmetic, and the cut said once

    @Test("With Add to Selection on, a cut to 500 queues the warning and records no line")
    func testApplyBatchTruncatesAt500() throws {
        let state = RedactionState()
        let toastManager = ToastQueueManager()
        let cutAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let regions = fabricateRegions(count: 600)
        // Stash the regions in the state so they're real "resident"
        // regions (the cap arithmetic doesn't actually inspect this,
        // but the production path always passes resident regions).
        state.regions[0] = regions

        // Pre-condition: cap is the documented constant.
        #expect(RedactionState.lassoSelectionCap == 500)

        let outcome = state.applyBatch(regions, now: cutAt, barShowing: false, toastManager: toastManager)

        // Exactly 500 selected — the first 500 by stored input order.
        #expect(outcome.selected == 500)
        #expect(outcome.truncated == true)
        #expect(state.selectedRegionIDs.count == 500)

        // The warning, once, at .warning severity with the shipped words.
        #expect(toastManager.activeToasts.count == 1)
        let toast = try #require(toastManager.activeToasts.first)
        #expect(toast.severity == .warning)
        #expect(toast.message == RedactionState.lassoSelectionCapToastMessage)
        // No line for the bar as well: one notice.
        #expect(state.lassoCut == nil)

        // The words, pinned, so a rename of the constant fails this test by
        // a mismatch rather than by a silent drift.
        #expect(RedactionState.lassoSelectionCapToastMessage == "Selection limited to 500 regions")
    }

    @Test("With the selection bar showing, a cut to 500 records the bar's line and queues no warning")
    func testApplyBatchWithTheBarShowing() {
        let state = RedactionState()
        let toastManager = ToastQueueManager()
        let cutAt = Date(timeIntervalSinceReferenceDate: 2_000)
        let regions = fabricateRegions(count: 600)
        state.regions[0] = regions

        let outcome = state.applyBatch(regions, now: cutAt, barShowing: true, toastManager: toastManager)

        #expect(outcome.selected == 500 && outcome.truncated)
        // The cut is recorded with its time and the selection it left.
        #expect(state.lassoCut == LassoCut(at: cutAt, selection: state.selectedRegionIDs))
        // No warning as well: one notice.
        #expect(toastManager.activeToasts.isEmpty)
    }

    @Test("applyBatch under the cap selects everything and records no cut")
    func testApplyBatchUnderCapNoToast() {
        // Boundary check: 500 input regions land in the selection
        // verbatim with no truncation and no cut recorded. The cap is
        // inclusive on the 500th region. A batch that is not cut also
        // clears an earlier cut.
        let state = RedactionState()
        let regions = fabricateRegions(count: 500)
        state.regions[0] = regions
        state.lassoCut = LassoCut(at: .now, selection: [UUID()])

        let outcome = state.applyBatch(regions)

        #expect(outcome.selected == 500)
        #expect(outcome.truncated == false)
        #expect(state.selectedRegionIDs.count == 500)
        #expect(state.lassoCut == nil)
    }

    @Test("applyBatch truncates with no view attached")
    func testApplyBatchTruncatesEvenWithoutToastSurface() {
        // Defense-in-depth: the cap arithmetic does not depend on any
        // view-layer service. Tests that exercise the state alone still
        // see truncation.
        let state = RedactionState()
        let regions = fabricateRegions(count: 750)

        let outcome = state.applyBatch(regions)

        #expect(outcome.selected == 500)
        #expect(outcome.truncated == true)
        #expect(state.selectedRegionIDs.count == 500)
    }

    // MARK: - Ordering preservation

    @Test("applyBatch preserves stable order — the kept set is the first 500")
    func testApplyBatchPreservesOrder() {
        // Spec: "fabricate 500 regions in marquee bounds; pass 500
        // regions; assert the kept set is the first 500 by stable
        // ordering." We test this with 600 input regions and assert
        // the kept IDs match `regions.prefix(500)`.
        let state = RedactionState()
        let regions = fabricateRegions(count: 600)
        state.regions[0] = regions

        state.applyBatch(regions)

        let expectedIDs = Set(regions.prefix(500).map(\.id))
        #expect(state.selectedRegionIDs == expectedIDs)

        // The dropped tail should not appear in the selection set.
        let droppedIDs = Set(regions.suffix(100).map(\.id))
        #expect(state.selectedRegionIDs.isDisjoint(with: droppedIDs))
    }

    @Test("applyBatch with exactly 500 keeps all of them in input order")
    func testApplyBatchKeepsAllWhenExactlyAtCap() {
        // The 500-region cap is inclusive — input of exactly 500
        // returns 500 selected with no truncation. This pins the
        // off-by-one boundary so a future refactor that flips the
        // comparator to `>=` breaks the test instead of silently
        // dropping the 500th region.
        let state = RedactionState()
        let regions = fabricateRegions(count: 500)

        let outcome = state.applyBatch(regions)

        #expect(outcome.selected == 500)
        #expect(outcome.truncated == false)
        #expect(state.selectedRegionIDs == Set(regions.map(\.id)))
    }
}
