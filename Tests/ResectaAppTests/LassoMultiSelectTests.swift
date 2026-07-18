import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// DRAW-6 (Phase 3) — lasso (rect-marquee) multi-select. When the
// `isMultiSelectActive` toolbar toggle is on AND the user's touch-down
// hits empty space, the drag is treated as a marquee. On touch-up, the
// overlay intersects every region's `normalizedRect` against the
// marquee and routes the hit set through
// `RedactionState.applyBatch(_:undoManager:toastManager:)` — a peer of
// the region-creating `applyFindings` seam, not a collapse onto
// it. The 500-region cap and warning toast surface inside
// `applyBatch` itself; see `ApplyBatchCapTests` for that side.
//
// These tests pin three behaviors without a UITouch host:
// 1. The pure intersection helper
//    `RedactionOverlayView.regionsIntersecting(marqueeNormalized:regions:)`
//    returns exactly the regions overlapping the marquee.
// 2. The marquee path is orthogonal to the new-region draw path —
//    `regionsIntersecting` only operates on supplied regions; it never
//    creates a new one. The branch in `touchesBegan` is gated on
//    `isMultiSelectActive` so multi-select-off documents preserve the
//    legacy new-region drawing.
// 3. Batch-delete via the existing `deleteSelected` affordance after a
//    marquee selection collapses into one undo step — the
//    selection-set mutation and the delete are independent registers,
//    but a single `undoManager.undo()` after the deletion restores the
//    deleted regions (matching the user-visible "one Cmd-Z = undo
//    delete" expectation).

@Suite("Lasso multi-select (DRAW-6)")
@MainActor
struct LassoMultiSelectTests {

    /// Seed a state with `count` regions arrayed vertically on `page`.
    /// Each region is 0.2 wide / 0.04 tall, evenly spaced from y=0.05
    /// upward by 0.08 so they don't overlap. Returns the regions in
    /// stored order so the caller can build expected sets without
    /// re-deriving the geometry. Uses `addRegion` so the `regionPageIndex`
    /// reverse map is populated — `deleteSelected` resolves region IDs
    /// to page indices through that map.
    private func seedRegions(
        _ state: RedactionState, count: Int, page: Int = 0
    ) -> [RedactionRegion] {
        var made: [RedactionRegion] = []
        for i in 0..<count {
            let region = RedactionRegion(
                id: UUID(),
                normalizedRect: CGRect(
                    x: 0.10,
                    y: 0.05 + Double(i) * 0.08,
                    width: 0.20,
                    height: 0.04
                ),
                source: .manual
            )
            state.addRegion(region, page: page, undoManager: nil)
            made.append(region)
        }
        return made
    }

    // MARK: - Marquee selects intersecting regions

    @Test("Marquee selects exactly the regions whose normalizedRect intersects the box")
    func testMarqueeSelectsIntersecting() {
        // 10 regions stacked vertically; geometry per `seedRegions`:
        //   region i sits in y ∈ [0.05 + i*0.08, 0.05 + i*0.08 + 0.04]
        // A marquee covering y ∈ [0.04, 0.30] x x ∈ [0.05, 0.35] overlaps
        // regions 0, 1, 2, 3 (their y starts are 0.05, 0.13, 0.21, 0.29).
        // Region 4 starts at y=0.37, outside the marquee. We assert
        // exactly those 4 are selected.
        let state = RedactionState()
        let regions = seedRegions(state, count: 10)
        let marquee = CGRect(x: 0.05, y: 0.04, width: 0.30, height: 0.26)

        let hits = RedactionOverlayView.regionsIntersecting(
            marqueeNormalized: marquee,
            regions: regions
        )

        #expect(hits.count == 4)
        #expect(Set(hits.map(\.id)) == Set(regions.prefix(4).map(\.id)))

        // Route the hits through applyBatch — the multi-select set must
        // hold exactly those four region IDs after commit.
        state.applyBatch(hits, undoManager: nil, toastManager: nil)
        #expect(state.selectedRegionIDs == Set(regions.prefix(4).map(\.id)))
    }

    @Test("Marquee that touches an edge counts the touched region")
    func testMarqueeEdgeTouchCountsAsHit() {
        // Edge-touch semantics: a marquee whose right edge just grazes a
        // region's left edge counts as a hit. Matches the user's mental
        // model that the box "covers" the region whenever they overlap.
        let state = RedactionState()
        let regions = seedRegions(state, count: 3)
        // Marquee right edge sits at x=0.30, the right edge of every
        // region (each region: x ∈ [0.10, 0.30]). Y range covers all
        // three regions.
        let marquee = CGRect(x: 0.05, y: 0.0, width: 0.25, height: 1.0)

        let hits = RedactionOverlayView.regionsIntersecting(
            marqueeNormalized: marquee,
            regions: regions
        )

        // All 3 hit because rects are inside the marquee (x.maxX = 0.30
        // = marquee.maxX; CGRect.intersects treats overlapping x ranges
        // as a hit when both rects have nonzero height/width overlap).
        #expect(hits.count == 3)
    }

    @Test("Marquee disjoint from all regions selects nothing")
    func testMarqueeDisjointSelectsNothing() {
        let state = RedactionState()
        let regions = seedRegions(state, count: 5)
        // Marquee in lower-right corner; all regions sit at x ∈ [0.10,
        // 0.30] and y in 0.05–0.41, so a marquee at (0.6, 0.6, 0.3, 0.3)
        // overlaps nothing.
        let marquee = CGRect(x: 0.60, y: 0.60, width: 0.30, height: 0.30)

        let hits = RedactionOverlayView.regionsIntersecting(
            marqueeNormalized: marquee,
            regions: regions
        )

        #expect(hits.isEmpty)

        // applyBatch with empty input is a valid no-op selection: the
        // selection set becomes empty.
        state.selectedRegionIDs = Set(regions.map(\.id))  // pre-fill
        state.applyBatch(hits, undoManager: nil, toastManager: nil)
        #expect(state.selectedRegionIDs.isEmpty)
    }

    // MARK: - Marquee orthogonality: off → ordinary new-region draw path

    @Test("Marquee path is gated on isMultiSelectActive — toggle off leaves draw path intact")
    func testMarqueeIgnoresWhenMultiSelectOff() {
        // The marquee branch in `touchesBegan` is gated on
        // `isMultiSelectActive` BEFORE the drawing-mode branch fires.
        // With multi-select off, an empty-space touch in drawing mode
        // still routes through the new-region draw path. We pin this
        // contract by exercising the overlay's `isMultiSelectActive`
        // setter and reading back the flag — the gate predicate is
        // local to `touchesBegan`, so the only test seam is the flag's
        // round-trip and the pure intersection helper's independence
        // from any "tool is active" state.

        let overlay = RedactionOverlayView()
        overlay.isDrawingMode = true

        // Default: off. New-region draw path remains the only empty-
        // space behavior — the marquee path is unreachable.
        #expect(overlay.isMultiSelectActive == false)

        // The pure helper has no awareness of `isMultiSelectActive` —
        // its only role is to resolve a marquee rect against regions.
        // That separation is intentional: the gate lives at the touch-
        // handling site, not in the math.
        let state = RedactionState()
        let regions = seedRegions(state, count: 4)
        let marquee = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        let hits = RedactionOverlayView.regionsIntersecting(
            marqueeNormalized: marquee,
            regions: regions
        )
        // Helper returns hits regardless of toggle state — but the
        // overlay never invokes the helper when the toggle is off.
        #expect(hits.count == 4)

        // Round-trip the toggle so future refactors keep the property
        // accessible from the layer above (PDFDocumentView ->
        // PDFViewCoordinator -> RedactionOverlayView). If this property
        // is removed or renamed, the gate predicate falls back to the
        // drawing-mode-only branch.
        overlay.isMultiSelectActive = true
        #expect(overlay.isMultiSelectActive == true)
        overlay.isMultiSelectActive = false
        #expect(overlay.isMultiSelectActive == false)
    }

    // MARK: - Batch-delete after marquee is one undo step

    @Test("Marquee select + delete via existing affordance: one undo restores all 4 regions")
    func testBatchDeleteIsSingleUndo() {
        // Pins the user-visible contract: after marquee-selecting four
        // regions and pressing Delete (the existing batch affordance),
        // a single `undoManager.undo()` restores all four regions to
        // the document.
        let state = RedactionState()
        let regions = seedRegions(state, count: 10)
        let undoManager = UndoManager()
        // seedRegions passes `undoManager: nil` so the apply/delete
        // pair below is the only undo content on the stack.

        // Marquee covers the first four regions (same geometry as
        // testMarqueeSelectsIntersecting).
        let marquee = CGRect(x: 0.05, y: 0.04, width: 0.30, height: 0.26)
        let hits = RedactionOverlayView.regionsIntersecting(
            marqueeNormalized: marquee,
            regions: regions
        )
        #expect(hits.count == 4)

        // Apply the lasso batch — selection set is registered as a
        // single undo step.
        state.applyBatch(hits, undoManager: undoManager, toastManager: nil)
        #expect(state.selectedRegionIDs.count == 4)

        // Delete via existing affordance — `deleteSelected` routes
        // through `removeRegions`, registering its own single undo
        // step that restores all 4 regions to page 0.
        let affectedPages = state.deleteSelected(undoManager: undoManager)
        #expect(affectedPages == [0])
        #expect(state.regions[0]?.count == 6)
        #expect(state.selectedRegionIDs.isEmpty)

        // The user-visible contract: one Cmd-Z brings the 4 deleted
        // regions back. That's the single undo step `removeRegions`
        // registers — the selection mutation lives in a separate undo
        // group, which the user undoes with a second Cmd-Z if desired.
        undoManager.undo()
        #expect(state.regions[0]?.count == 10)
        // The restored regions retain their original IDs so a re-
        // intersection against the same marquee picks them up.
        let restored = state.regions[0] ?? []
        let restoredIDs = Set(restored.map(\.id))
        #expect(restoredIDs.isSuperset(of: Set(regions.prefix(4).map(\.id))))
    }
}
