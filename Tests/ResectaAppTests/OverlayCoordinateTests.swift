import Testing
import UIKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// UI_UX §2.3: Coordinate transform tests.
// Security-critical — incorrect conversion = wrong pixels destroyed.

@Suite("Overlay Coordinate Conversion", .tags(.critical, .overlay))
@MainActor
struct OverlayCoordinateTests {

    // Standard page size for most tests
    private static let pageFrame = CGRect(x: 0, y: 0, width: 612, height: 792)

    private func makeOverlay(frame: CGRect = pageFrame) -> RedactionOverlayView {
        RedactionOverlayView(frame: frame)
    }

    // MARK: - overlayToPDFNormalized

    @Test("Full bounds maps to unit rect (0, 0, 1, 1)")
    func overlayToPDFNormalized_fullBounds() {
        let overlay = makeOverlay()
        let result = overlay.overlayToPDFNormalized(overlay.bounds)
        #expect(abs(result.origin.x) < 0.001)
        #expect(abs(result.origin.y) < 0.001)
        #expect(abs(result.width - 1.0) < 0.001)
        #expect(abs(result.height - 1.0) < 0.001)
    }

    @Test("Y axis is flipped: UIKit top -> PDF top (y=1)")
    func overlayToPDFNormalized_flipsY() {
        let overlay = makeOverlay()
        // A rect at the very top of UIKit (y=0) maps to bottom of PDF (y close to 1)
        let topRect = CGRect(x: 0, y: 0, width: 612, height: 100)
        let result = overlay.overlayToPDFNormalized(topRect)
        // PDF y should be near the top of the page (close to 1 - height/792)
        let expectedY = 1.0 - (100.0 / 792.0)
        #expect(abs(result.origin.y - expectedY) < 0.001)
    }

    @Test("Zero-size bounds returns .zero")
    func overlayToPDFNormalized_zeroBoundsReturnsZero() {
        let overlay = RedactionOverlayView(frame: .zero)
        let result = overlay.overlayToPDFNormalized(
            CGRect(x: 10, y: 10, width: 50, height: 50))
        #expect(result == .zero)
    }

    @Test("Small region at known position maps correctly")
    func overlayToPDFNormalized_smallRegion() {
        let overlay = makeOverlay()
        // Region at overlay (61.2, 79.2, 122.4, 158.4)
        // Expected normalized: x=0.1, width=0.2, height=0.2
        // Y: 1.0 - (79.2 + 158.4)/792 = 1.0 - 237.6/792 = 1.0 - 0.3 = 0.7
        let rect = CGRect(x: 61.2, y: 79.2, width: 122.4, height: 158.4)
        let result = overlay.overlayToPDFNormalized(rect)
        #expect(abs(result.origin.x - 0.1) < 0.001)
        #expect(abs(result.origin.y - 0.7) < 0.001)
        #expect(abs(result.width - 0.2) < 0.001)
        #expect(abs(result.height - 0.2) < 0.001)
    }

    // MARK: - pdfNormalizedToOverlay

    @Test("Unit rect maps to full bounds")
    func pdfNormalizedToOverlay_fullBounds() {
        let overlay = makeOverlay()
        let result = overlay.pdfNormalizedToOverlay(
            CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(abs(result.origin.x) < 0.001)
        #expect(abs(result.origin.y) < 0.001)
        #expect(abs(result.width - 612) < 0.001)
        #expect(abs(result.height - 792) < 0.001)
    }

    @Test("Center region (0.25, 0.25, 0.5, 0.5) maps to center of overlay")
    func pdfNormalizedToOverlay_centerRegion() {
        let overlay = makeOverlay()
        let result = overlay.pdfNormalizedToOverlay(
            CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(abs(result.origin.x - 153) < 0.5)
        // PDF y=0.25 with height=0.5 means top-left in UIKit is at:
        // (1.0 - 0.25 - 0.5) * 792 = 0.25 * 792 = 198
        #expect(abs(result.origin.y - 198) < 0.5)
        #expect(abs(result.width - 306) < 0.5)
        #expect(abs(result.height - 396) < 0.5)
    }

    // MARK: - Round-Trip Identity

    @Test("Round-trip overlayToPDF -> pdfToOverlay is identity")
    func roundTripIsIdentity() {
        let overlay = makeOverlay()
        let original = CGRect(x: 100, y: 200, width: 150, height: 180)
        let normalized = overlay.overlayToPDFNormalized(original)
        let roundTripped = overlay.pdfNormalizedToOverlay(normalized)

        #expect(abs(roundTripped.origin.x - original.origin.x) < 0.01)
        #expect(abs(roundTripped.origin.y - original.origin.y) < 0.01)
        #expect(abs(roundTripped.width - original.width) < 0.01)
        #expect(abs(roundTripped.height - original.height) < 0.01)
    }

    @Test("Round-trip identity for various bounds sizes",
          arguments: [
            CGRect(x: 0, y: 0, width: 612, height: 792),
            CGRect(x: 0, y: 0, width: 300, height: 400),
            CGRect(x: 0, y: 0, width: 1000, height: 1000),
          ])
    func roundTripParameterized(bounds: CGRect) {
        let overlay = RedactionOverlayView(frame: bounds)
        let testRect = CGRect(
            x: bounds.width * 0.15,
            y: bounds.height * 0.2,
            width: bounds.width * 0.3,
            height: bounds.height * 0.25)
        let normalized = overlay.overlayToPDFNormalized(testRect)
        let roundTripped = overlay.pdfNormalizedToOverlay(normalized)

        #expect(abs(roundTripped.origin.x - testRect.origin.x) < 0.01)
        #expect(abs(roundTripped.origin.y - testRect.origin.y) < 0.01)
        #expect(abs(roundTripped.width - testRect.width) < 0.01)
        #expect(abs(roundTripped.height - testRect.height) < 0.01)
    }
}
