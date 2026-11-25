import Testing
import UIKit
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The overlay in two bitmaps: the committed boxes in the overlay's own,
// and every pass drawn after them in the top canvas above (`OverlayTopCanvas`).
// What is on screen is unchanged; the canvas pixel tests hold that. These
// pin the split itself: each redraw reaches both bitmaps, each `draw(_:)`
// names its own passes, a temporary view stays above the canvas, and the
// canvas keeps the overlay's bounds.
@MainActor
struct OverlayTopCanvasTests {

    private static let overlaySize = CGSize(width: 400, height: 400)

    /// An overlay in a shown window, both bitmaps drawn, nothing marked.
    private func hostedOverlay() throws -> (UIWindow, RedactionOverlayView, OverlayTopCanvas) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.overlaySize))
        let overlay = RedactionOverlayView(frame: window.bounds)
        window.addSubview(overlay)
        window.isHidden = false
        let canvas = try #require(overlay.topCanvas)
        overlay.layer.displayIfNeeded()
        canvas.layer.displayIfNeeded()
        return (window, overlay, canvas)
    }

    // MARK: - Every redraw reaches both

    @Test("Marking the overlay marks the top canvas")
    func setNeedsDisplayReachesTheCanvas() throws {
        let (window, overlay, canvas) = try hostedOverlay()
        #expect(canvas.layer.needsDisplay() == false, "precondition: the canvas was drawn")
        overlay.setNeedsDisplay()
        #expect(overlay.layer.needsDisplay())
        #expect(canvas.layer.needsDisplay())
        withExtendedLifetime(window) {}
    }

    @Test("Marking a part of the overlay marks the top canvas")
    func setNeedsDisplayInARectReachesTheCanvas() throws {
        let (window, overlay, canvas) = try hostedOverlay()
        #expect(canvas.layer.needsDisplay() == false, "precondition: the canvas was drawn")
        overlay.setNeedsDisplay(CGRect(x: 10, y: 10, width: 40, height: 40))
        #expect(canvas.layer.needsDisplay())
        withExtendedLifetime(window) {}
    }

    @Test("The Differentiate Without Color notice redraws the top canvas")
    func settingChangeReachesTheCanvas() throws {
        let (window, _, canvas) = try hostedOverlay()
        #expect(canvas.layer.needsDisplay() == false, "precondition: the canvas was drawn")
        NotificationCenter.default.post(name: UIAccessibility.differentiateWithoutColorDidChangeNotification, object: nil)
        #expect(canvas.layer.needsDisplay())
        withExtendedLifetime(window) {}
    }

    // MARK: - Each draw body names its own passes

    @Test("The overlay draws only the boxes; the top canvas draws the three later passes, in order")
    func drawBodiesNameTheirPasses() throws {
        let overlayBody = try Self.drawBody(of: "Sources/ResectaApp/Overlay/RedactionOverlayView+DrawEntry.swift")
        let canvasBody = try Self.drawBody(of: "Sources/ResectaApp/Overlay/OverlayTopCanvas.swift")
        let later = ["drawSearchLayer(", "drawSnapGuides(", "drawInProgressShapes("]

        #expect(overlayBody.contains("drawCommittedRegions("))
        for pass in later { #expect(!overlayBody.contains(pass), "the overlay's draw(_:) still calls \(pass)") }

        #expect(!canvasBody.contains("drawCommittedRegions("))
        let offsets = try later.map { pass in
            try #require(canvasBody.range(of: pass), "the top canvas's draw(_:) does not call \(pass)").lowerBound
        }
        #expect(offsets == offsets.sorted(), "the top canvas draws the passes out of order")
    }

    /// The code lines (comments dropped) of a file's `draw(_:)` override.
    private static func drawBody(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let start = try #require(text.range(of: "override func draw(_ rect: CGRect) {"), "no draw(_:) in \(relativePath)")
        var depth = 1
        var body = ""
        for ch in text[start.upperBound...] {
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1; if depth == 0 { break } }
            body.append(ch)
        }
        return body.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - A temporary view stays above the canvas

    @Test("A rejected rubber band, while shown, is above the top canvas")
    func rejectedBandIsAboveTheCanvas() throws {
        let (window, overlay, canvas) = try hostedOverlay()
        overlay.isDrawingMode = true
        overlay.activeShapeTool = .rectangle
        let coordinator = RecordingCoordinator()
        overlay.coordinator = coordinator
        overlay.configure(with: [], selectedIDs: [])

        // Past the 8-pt start gate, under the 20-pt commit floor: the band
        // is rejected on touch-up and shown while it shrinks away.
        let touch = StubTouch(location: CGPoint(x: 100, y: 100), view: overlay)
        overlay.touchesBegan([touch], with: nil)
        touch.move(to: CGPoint(x: 112, y: 112))
        overlay.touchesMoved([touch], with: nil)
        overlay.touchesEnded([touch], with: nil)
        #expect(coordinator.addedRegions.isEmpty)

        let canvasIndex = try #require(overlay.subviews.firstIndex(of: canvas))
        let bandIndex = try #require(overlay.subviews.firstIndex { $0 !== canvas }, "no band view was shown")
        #expect(bandIndex > canvasIndex)
        withExtendedLifetime(window) {}
    }

    // MARK: - The canvas keeps the overlay's bounds

    @Test("The top canvas's frame equals the overlay's bounds after the overlay's frame changes",
          arguments: [CGRect.zero, CGRect(x: 0, y: 0, width: 400, height: 400)])
    func canvasFollowsTheBounds(start: CGRect) throws {
        let overlay = RedactionOverlayView(frame: start)
        let canvas = try #require(overlay.topCanvas)
        #expect(canvas.frame == overlay.bounds)
        for next in [CGRect(x: 20, y: 30, width: 300, height: 500), CGRect(x: 0, y: 0, width: 612, height: 792)] {
            overlay.frame = next
            overlay.layoutIfNeeded()
            #expect(canvas.frame == overlay.bounds)
        }
    }
}
