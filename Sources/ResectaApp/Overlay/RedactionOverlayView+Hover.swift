import UIKit

extension RedactionOverlayView {
    // MARK: - Hover

    @objc func handleHover(_ gesture: UIHoverGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began, .changed:
            let region = hitTestRegion(at: point)
            let newID = region?.id
            if newID != coordinator?.redactionState?.hoveredRegionID {
                coordinator?.redactionState?.hoveredRegionID = newID
            }
        case .ended, .cancelled:
            coordinator?.redactionState?.hoveredRegionID = nil
        default:
            break
        }
    }
}
