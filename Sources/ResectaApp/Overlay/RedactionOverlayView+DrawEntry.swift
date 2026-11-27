import UIKit

// The overlay's `draw(_:)` override, moved out of `RedactionOverlayView.swift`
// (the hub) from its `// MARK: - Drawing` seam. The segments it draws are in
// `RedactionOverlayView+Draw.swift`.

extension RedactionOverlayView {
    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        drawPassCount += 1
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // Clip to dirty rect for performance with many regions.
        ctx.clip(to: rect)

        // The segments live in `RedactionOverlayView+Draw.swift`. This
        // bitmap holds the committed regions only; the passes drawn after
        // them (the search layer, the snap chrome, the in-progress shapes)
        // are drawn, in that order, by the top canvas above it
        // (`OverlayTopCanvas`).
        drawCommittedRegions(ctx: ctx, in: rect)
    }
}
