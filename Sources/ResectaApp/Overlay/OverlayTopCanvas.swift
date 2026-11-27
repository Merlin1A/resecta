import UIKit

/// The overlay's top layer: everything the overlay draws after its
/// committed boxes (the Search layer, the snap guides and the shapes being
/// drawn), in the order the overlay always drew them, in a bitmap above the
/// boxes' own.
///
/// It is the overlay's one permanent subview, with the overlay's bounds, and
/// it follows them by its autoresizing mask. It takes no touch, so a touch's
/// view is still the overlay; and it holds no accessibility elements, since
/// the overlay lists its own. The overlay marks it whenever it is marked
/// itself (`RedactionOverlayView.setNeedsDisplay`), so no caller changes.
final class OverlayTopCanvas: UIView {
    private weak var host: RedactionOverlayView?

    init(host: RedactionOverlayView) {
        self.host = host
        super.init(frame: host.bounds)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let host, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.clip(to: rect)
        host.drawSearchLayer(ctx: ctx, in: rect)
        host.drawSnapGuides(ctx: ctx)
        host.drawInProgressShapes(ctx: ctx)
    }
}
