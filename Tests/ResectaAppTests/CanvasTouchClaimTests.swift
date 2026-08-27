import Testing
import UIKit
@testable import ResectaApp

// UXC-49 (D-124 / REV-13): the canvas claim recognizer and the window-pan
// deference it anchors. Beneath the compact float, iOS 26's sheet installs
// a window-level pan (`cancelsTouchesInView`) that cancelled every moving
// canvas touch before PDFKit's delayed content touches reached the
// raw-touch overlay (six drags: 6/6 with no sheet, 0/6 beneath the float);
// the overlay now makes such pans `require(toFail:)` its claim. Pinned
// here without a sheet: the recognizer's contract, the pure predicate that
// selects the pans, the reconcile bookkeeping, and the source seams.
@Suite("Canvas touch claim")
@MainActor
struct CanvasTouchClaimTests {

    @Test("The claim never cancels or delays the view's touches, never prevents, is never prevented")
    func claimContract() {
        let claim = CanvasTouchClaimGestureRecognizer(target: nil, action: nil)
        #expect(!claim.cancelsTouchesInView)
        #expect(!claim.delaysTouchesBegan)
        #expect(!claim.delaysTouchesEnded)
        let other = UIPanGestureRecognizer()
        #expect(!claim.canPrevent(other))
        #expect(!claim.canBePrevented(by: other))
    }

    @Test("Predicate: only a window-level pan that cancels touches defers to the canvas")
    func predicateSelectsWindowCancellingPans() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))

        let exteriorLike = UIPanGestureRecognizer()
        window.addGestureRecognizer(exteriorLike)
        #expect(RedactionOverlayView.windowPanShouldDeferToCanvas(exteriorLike))

        let flexLike = UIPanGestureRecognizer()
        flexLike.cancelsTouchesInView = false
        window.addGestureRecognizer(flexLike)
        #expect(!RedactionOverlayView.windowPanShouldDeferToCanvas(flexLike),
                "a pan that does not cancel touches is left alone")

        let windowTap = UITapGestureRecognizer()
        window.addGestureRecognizer(windowTap)
        #expect(!RedactionOverlayView.windowPanShouldDeferToCanvas(windowTap),
                "only pans defer")

        let plainView = UIView()
        let viewPan = UIPanGestureRecognizer()
        plainView.addGestureRecognizer(viewPan)
        #expect(!RedactionOverlayView.windowPanShouldDeferToCanvas(viewPan),
                "a pan on an ordinary view (PDFKit's scroll pan, the sheet's grabber) is left alone")

        let detached = UIPanGestureRecognizer()
        #expect(!RedactionOverlayView.windowPanShouldDeferToCanvas(detached))
    }

    @Test("Reconcile wires each qualifying window pan once — on window entry and on repeat calls")
    func reconcileIsIdempotent() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let exteriorLike = UIPanGestureRecognizer()
        window.addGestureRecognizer(exteriorLike)
        let flexLike = UIPanGestureRecognizer()
        flexLike.cancelsTouchesInView = false
        window.addGestureRecognizer(flexLike)

        let overlay = RedactionOverlayView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(overlay.deferredWindowPanCount == 0)

        window.addSubview(overlay)   // didMoveToWindow reconciles
        #expect(overlay.deferredWindowPanCount == 1)

        overlay.reconcileWindowPanDeference()
        overlay.reconcileWindowPanDeference()
        #expect(overlay.deferredWindowPanCount == 1, "idempotent")

        let laterPresentationPan = UIPanGestureRecognizer()
        window.addGestureRecognizer(laterPresentationPan)
        overlay.reconcileWindowPanDeference()
        #expect(overlay.deferredWindowPanCount == 2, "a pan that arrives later is picked up")
    }

    @Test("Source pin: the overlay installs the claim, gates hit-testing on its routing, and reconciles at the hit-test seam and on window entry")
    func overlaySourceSeams() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Overlay/RedactionOverlayView.swift")
        #expect(source.contains("addGestureRecognizer(canvasTouchClaim)"))
        #expect(source.contains("recognizer.require(toFail: canvasTouchClaim)"))
        guard let hit = source.range(
                of: "override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {"),
              let claims = source.range(
                of: "private func claimsTouch(at point: CGPoint) -> Bool {",
                range: hit.upperBound..<source.endIndex)
        else {
            Issue.record("Could not locate the overlay hit-test seam")
            return
        }
        let body = source[hit.upperBound..<claims.lowerBound]
        #expect(body.contains("guard claimsTouch(at: point) else { return nil }"))
        #expect(body.contains("reconcileWindowPanDeference()"))
        guard let moved = source.range(of: "override func didMoveToWindow() {") else {
            Issue.record("Could not locate didMoveToWindow")
            return
        }
        #expect(source[moved.upperBound...].prefix(120).contains("reconcileWindowPanDeference()"))
    }

    /// Mirrors `HonestySurfacesTests.loadRepoFile`.
    private func loadRepoFile(
        _ relativePath: String, from file: StaticString = #filePath
    ) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}
