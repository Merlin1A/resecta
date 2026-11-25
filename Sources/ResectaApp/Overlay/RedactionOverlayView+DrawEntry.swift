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

        // The segments live in `RedactionOverlayView+Draw.swift`, drawn
        // in the order this body always drew them: the committed
        // regions, the search layer, the snap chrome, the in-progress
        // shapes.
        drawCommittedRegions(ctx: ctx, in: rect)

        drawSearchLayer(ctx: ctx, in: rect)

        // Draw active snap guide lines
        drawSnapGuides(ctx: ctx)

        drawInProgressShapes(ctx: ctx)
    }
}
