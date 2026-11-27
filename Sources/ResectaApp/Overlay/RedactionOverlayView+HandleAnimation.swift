import UIKit

// The selection handles' scale animation, moved out of
// `RedactionOverlayView.swift` (the hub) from its `// MARK: - Handle
// Animation` seam: animating the handles in and out, the display link's
// tick, and the `removeFromSuperview` override that stops it. The animation
// state is stored on the hub (an extension adds no storage).

extension RedactionOverlayView {
    // MARK: - Handle Animation

    /// Animate resize handles appearing (selection gained).
    /// Duration sourced from `ResectaTokens.Anim.selectionInDuration`;
    /// Reduce Motion bypasses the CADisplayLink path and snaps to the target
    /// scale immediately, matching the `Anim.resolved` posture used by the
    /// SwiftUI surfaces.
    func animateHandlesIn() {
        if UIAccessibility.isReduceMotionEnabled {
            handleScale = 1.0
            setNeedsDisplay()
            return
        }
        handleAnimFromScale = handleScale
        handleAnimTargetScale = 1.0
        handleAnimDuration = ResectaTokens.Anim.selectionInDuration
        startHandleAnimation()
    }

    /// Animate resize handles disappearing (selection lost).
    /// See `animateHandlesIn` for the Reduce-Motion posture.
    func animateHandlesOut() {
        if UIAccessibility.isReduceMotionEnabled {
            handleScale = 0.0
            setNeedsDisplay()
            return
        }
        handleAnimFromScale = handleScale
        handleAnimTargetScale = 0.0
        handleAnimDuration = ResectaTokens.Anim.selectionOutDuration
        startHandleAnimation()
    }

    private func startHandleAnimation() {
        handleDisplayLink?.invalidate()
        handleAnimStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(handleAnimationTick))
        // ProMotion: allow 120Hz on capable devices for smoother handle animation
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        handleDisplayLink = link
    }

    @objc private func handleAnimationTick(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - handleAnimStartTime
        var t = min(elapsed / handleAnimDuration, 1.0)
        // Ease-out cubic: 1 - (1-t)^3
        t = 1.0 - pow(1.0 - t, 3)
        handleScale = handleAnimFromScale + (handleAnimTargetScale - handleAnimFromScale) * CGFloat(t)
        boxLayers.mark(.handles)
        if elapsed >= handleAnimDuration {
            handleScale = handleAnimTargetScale
            link.invalidate()
            handleDisplayLink = nil
        }
    }

    override func removeFromSuperview() {
        handleDisplayLink?.invalidate()
        handleDisplayLink = nil
        super.removeFromSuperview()
    }
}
