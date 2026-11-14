import UIKit

// The pointer hover handler, moved out of `RedactionOverlayView.swift` (the
// hub) from its `// MARK: - Hover` seam. The hub's initialiser installs the
// hover recognizer that calls it.

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
