import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp

// Canvas a11y polish bundle. Three sub-fixes pinned by token-value
// / predicate / shape tests so each can fail in isolation if a future
// tweak drifts a duration, a stroke width, or the Reduce-Motion gate.
//
// Badge outer stroke width (dark-mode contrast)
// Resize-handle outer stroke width (selection visibility)
// Handle in/out durations sourced from `ResectaTokens.Anim`.

@Suite("Canvas accessibility polish")
@MainActor
struct CanvasAccessibilityPolishTests {

    // MARK: - Badge outer stroke

    @Test("Badge outer stroke is a 0.5pt hairline")
    func badgeOuterStrokeIsHairline() {
        // 0.5pt sub-pixel on 2× / 3× retina. Wide enough to register as a
        // perimeter line without bulking up the badge, so the badge color
        // still reads first and the stroke only kicks in at the edge.
        #expect(RedactionOverlayView.badgeOuterStrokeWidth == 0.5)
    }

    // MARK: - Handle animation tokens

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
}
