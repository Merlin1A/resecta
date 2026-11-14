import UIKit

extension RedactionOverlayView {
    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
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
