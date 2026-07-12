import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp

// WU-43 — canvas a11y polish bundle. Three sub-fixes pinned by token-value
// / predicate / shape tests so each can fail in isolation if a future
// tweak drifts a duration, a stroke width, or the Reduce-Motion gate.
//
// M-D.3 — badge outer stroke width (dark-mode contrast)
// M-D.4 — resize-handle outer stroke width (selection visibility)
// M-D.5 — handle in/out durations sourced from `ResectaTokens.Anim`
//          + Reduce-Motion gate that snaps to the target scale.

@Suite("Canvas accessibility polish (WU-43)")
@MainActor
struct CanvasAccessibilityPolishTests {

    // MARK: - M-D.3 — Badge outer stroke

    @Test("Badge outer stroke is a 0.5pt hairline (M-D.3)")
    func badgeOuterStrokeIsHairline() {
        // 0.5pt sub-pixel on 2× / 3× retina. Wide enough to register as a
        // perimeter line without bulking up the badge, so the badge color
        // still reads first and the stroke only kicks in at the edge.
        #expect(RedactionOverlayView.badgeOuterStrokeWidth == 0.5)
    }

    // MARK: - M-D.4 — Resize-handle outer stroke

    @Test("Resize-handle outer ring is a 1pt mid-gray stroke (M-D.4)")
    func selectionHandleOuterStrokeIsOnePoint() {
        // 1pt mid-gray ring drawn beneath the white-fill / blue-stroke
        // handle disc. Visible against white page margins where the
        // 1.5pt blue stroke alone can wash out.
        #expect(RedactionOverlayView.selectionHandleOuterStrokeWidth == 1.0)
    }

    // MARK: - M-D.5 — Handle animation tokens

    @Test("Handle-in duration matches the SwiftUI selectionIn timing")
    func selectionInDurationMatchesToken() {
        // The CADisplayLink path can't consume a SwiftUI Animation value,
        // so the duration lives in a TimeInterval companion token. Both
        // share the 0.2s ease-out cubic posture so the resize-handle
        // CADisplayLink path and the SwiftUI selection-tint animation
        // settle on the same beat when both fire at once.
        #expect(ResectaTokens.Anim.selectionInDuration == 0.2)
    }

    @Test("Handle-out duration matches the SwiftUI selectionOut timing")
    func selectionOutDurationMatchesToken() {
        // 0.15s — faster than the in-animation to match the SwiftUI
        // pairing where deselection settles quicker than selection. Same
        // reasoning as selectionInDuration: shared posture across the
        // two animation surfaces.
        #expect(ResectaTokens.Anim.selectionOutDuration == 0.15)
    }

    // MARK: - M-D.5 — Reduce Motion gate

    @Test("Reduce Motion in: handle scale snaps to 1.0 (full size)")
    func reduceMotionSelectionInSnapsToOne() {
        // Selection-gained branch with Reduce Motion on. The caller
        // bypasses the CADisplayLink path and sets handleScale directly
        // to 1.0. The pure helper returns a non-nil CGFloat so the call
        // site can route through one branch.
        let scale = RedactionOverlayView.reduceMotionHandleScale(
            direction: .in,
            reduceMotion: true
        )
        #expect(scale == 1.0)
    }

    @Test("Reduce Motion out: handle scale snaps to 0.0 (hidden)")
    func reduceMotionSelectionOutSnapsToZero() {
        let scale = RedactionOverlayView.reduceMotionHandleScale(
            direction: .out,
            reduceMotion: true
        )
        #expect(scale == 0.0)
    }

    @Test("Reduce Motion off: helper returns nil — CADisplayLink path runs")
    func reduceMotionOffReturnsNil() {
        // Without Reduce Motion, the helper returns nil so the call site
        // runs the standard CADisplayLink interpolation. nil distinguishes
        // "no override" from "snap to scale 0.0" so the in/out branches
        // share one routing.
        let inScale = RedactionOverlayView.reduceMotionHandleScale(
            direction: .in,
            reduceMotion: false
        )
        #expect(inScale == nil)
        let outScale = RedactionOverlayView.reduceMotionHandleScale(
            direction: .out,
            reduceMotion: false
        )
        #expect(outScale == nil)
    }
}
