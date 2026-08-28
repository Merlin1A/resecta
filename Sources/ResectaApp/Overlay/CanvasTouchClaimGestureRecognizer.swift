import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A "canvas touch is in flight" flag for UIKit's
/// gesture arbitration.
///
/// `RedactionOverlayView` handles every canvas gesture through raw
/// `touchesBegan` / `touchesMoved` / `touchesEnded` overrides and so has no
/// standing of its own in the gesture environment. While a sheet is
/// presented, iOS 26 installs a window-level pan
/// (`UISheetPresentationControllerExteriorPanGesture`, `cancelsTouchesInView`)
/// that recognizes on the first moves of ANY touch and cancels the touches
/// PDFKit's scroll view is still holding for its `delaysContentTouches`
/// window — so beneath the compact float the overlay never received
/// `touchesBegan` for a drag (draw, move, resize, lasso), while stationary
/// taps went through. Measured on the iPhone 17 / iOS 26.4 simulator:
/// six drags commit 6/6 with no sheet and 0/6 beneath the float; with the
/// exterior pan required to fail against this recognizer, 3/3 with the pan
/// enabled.
///
/// The recognizer enters `.began` on touch-down and ends with the last
/// lift; the overlay then makes every window-level cancelling pan
/// `require(toFail:)` it (`RedactionOverlayView.reconcileWindowPanDeference()`).
/// UIKit honours a failure requirement regardless of delegate simultaneity
/// (a plain "prevent" does not — the sheet's delegate recognizes
/// simultaneously, probed). It never prevents another recognizer, is never
/// prevented, and neither cancels nor delays the view's touches, so the
/// overlay's raw-touch state machine and PDFKit's pinch / two-finger pan
/// are untouched.
final class CanvasTouchClaimGestureRecognizer: UIGestureRecognizer {

    private var trackedTouches = Set<UITouch>()

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    /// A flag, not a competitor: nothing is blocked by this recognizer
    /// succeeding …
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    /// … and nothing may block it, or the failure requirement it anchors
    /// would release the exterior pan mid-drag.
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        trackedTouches.formUnion(touches)
        if state == .possible {
            state = .began
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        trackedTouches.subtract(touches)
        if trackedTouches.isEmpty {
            state = .ended
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        trackedTouches.subtract(touches)
        if trackedTouches.isEmpty {
            state = .cancelled
        }
    }

    override func reset() {
        super.reset()
        trackedTouches.removeAll()
    }
}
