import Testing
import Foundation
import CoreGraphics
import UIKit
@testable import ResectaApp

// WU-77 — Apple Pencil circle-to-select. The pure
// predicates (closed-loop, shoelace area, point-in-polygon, row
// enclosure, touch-source discriminator, enclosed-row aggregator)
// are testable without a UIView host; the actual gesture wiring
// lives in `PencilCircleSelectOverlay` (UIViewRepresentable) which
// requires a device for end-to-end verification per
// `CHROME_AND_LAYOUT.md` §A11.5 manual checklist.
//
// Per [RR-36] the gesture-conflict matrix is the load-bearing
// sub-deliverable and lives in the spec doc (not in tests). Per
// [RR-37] iOS 26 API stability — recognizer path uses
// `UIPanGestureRecognizer` + `allowedTouchTypes` which has been
// stable since iOS 9; the `#available(iOS 26, *)` modifier gate
// is a future-proofing marker since the deployment target is
// already iOS 26.

@Suite("Pencil circle-to-select predicates (WU-77)")
@MainActor
struct PencilCircleSelectTests {

    // MARK: - Closed-loop recognizer

    @Test("Open path (start far from end) is not a closed loop")
    func isClosedLoopRejectsOpenPath() {
        let path = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 0, y: 100),
            CGPoint(x: 0, y: 200), // end is 200pt from start
        ]
        #expect(SearchResultsSection.isClosedLoop(path: path) == false)
    }

    @Test("Closed loop with sufficient area is recognized")
    func isClosedLoopAcceptsClosedQuadrilateral() {
        let path = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 0, y: 100),
            CGPoint(x: 5, y: 5), // close to start (< 40pt)
        ]
        #expect(SearchResultsSection.isClosedLoop(path: path) == true)
    }

    @Test("Closed loop with too-small area is rejected")
    func isClosedLoopRejectsTinyLoop() {
        // 5x5 square has area 25, well below the 400 default minimum.
        let path = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 5, y: 0),
            CGPoint(x: 5, y: 5),
            CGPoint(x: 0, y: 5),
            CGPoint(x: 0, y: 0),
        ]
        #expect(SearchResultsSection.isClosedLoop(path: path) == false)
    }

    @Test("Path with fewer than 3 points is not a loop")
    func isClosedLoopRejectsTooFewPoints() {
        #expect(SearchResultsSection.isClosedLoop(path: []) == false)
        #expect(SearchResultsSection.isClosedLoop(path: [.zero]) == false)
        #expect(SearchResultsSection.isClosedLoop(
            path: [.zero, CGPoint(x: 10, y: 10)]
        ) == false)
    }

    @Test("Close distance threshold respects override")
    func isClosedLoopRespectsCloseDistanceOverride() {
        let path = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 0, y: 100),
            CGPoint(x: 50, y: 50), // 70.7pt from start
        ]
        // Default threshold (40pt) rejects.
        #expect(SearchResultsSection.isClosedLoop(path: path) == false)
        // Looser threshold (100pt) accepts.
        #expect(
            SearchResultsSection.isClosedLoop(path: path, closeDistance: 100)
                == true
        )
    }

    // MARK: - Shoelace area

    @Test("Shoelace area of a 100x100 square is 10000")
    func shoelaceSquareArea() {
        let square = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 0, y: 100),
        ]
        #expect(abs(SearchResultsSection.shoelaceArea(path: square) - 10000) < 1e-6)
    }

    @Test("Shoelace area is winding-direction-independent")
    func shoelaceWindingIndependent() {
        let cw = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0, y: 100),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 100, y: 0),
        ]
        let ccw = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 0, y: 100),
        ]
        #expect(
            SearchResultsSection.shoelaceArea(path: cw)
                == SearchResultsSection.shoelaceArea(path: ccw)
        )
    }

    @Test("Shoelace area of a degenerate path is zero")
    func shoelaceDegenerate() {
        #expect(SearchResultsSection.shoelaceArea(path: []) == 0)
        #expect(SearchResultsSection.shoelaceArea(path: [.zero]) == 0)
        #expect(
            SearchResultsSection.shoelaceArea(
                path: [.zero, CGPoint(x: 100, y: 100)]
            ) == 0
        )
    }

    // MARK: - Point-in-polygon

    @Test("Point inside a 100x100 square is detected as inside")
    func isPointInPolygonInteriorPoint() {
        let square = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 0, y: 100),
        ]
        #expect(
            SearchResultsSection.isPointInPolygon(
                point: CGPoint(x: 50, y: 50),
                polygon: square
            ) == true
        )
    }

    @Test("Point outside a 100x100 square is detected as outside")
    func isPointInPolygonExteriorPoint() {
        let square = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 0, y: 100),
        ]
        #expect(
            SearchResultsSection.isPointInPolygon(
                point: CGPoint(x: 200, y: 200),
                polygon: square
            ) == false
        )
    }

    @Test("Concave polygon notch is detected as outside")
    func isPointInPolygonConcaveNotch() {
        // Pac-Man-like shape: rectangle with a triangular notch cut
        // out of the right side. A point inside the notch should
        // read as outside.
        let pacman = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 50, y: 50),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 0, y: 100),
        ]
        // The notch is the triangle (100,0)-(50,50)-(100,100). A point
        // at (80, 50) sits inside the notch — outside the polygon.
        #expect(
            SearchResultsSection.isPointInPolygon(
                point: CGPoint(x: 80, y: 50),
                polygon: pacman
            ) == false
        )
        // A point at (20, 50) is inside the main body.
        #expect(
            SearchResultsSection.isPointInPolygon(
                point: CGPoint(x: 20, y: 50),
                polygon: pacman
            ) == true
        )
    }

    @Test("Degenerate polygon (< 3 points) contains nothing")
    func isPointInPolygonDegenerate() {
        #expect(
            SearchResultsSection.isPointInPolygon(
                point: .zero,
                polygon: []
            ) == false
        )
    }

    // MARK: - Row enclosure

    @Test("Row whose centroid is inside the loop is enclosed")
    func isRowEnclosedCentroidInside() {
        let loop = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 200, y: 0),
            CGPoint(x: 200, y: 200),
            CGPoint(x: 0, y: 200),
        ]
        let row = CGRect(x: 50, y: 50, width: 100, height: 50)
        // Centroid (100, 75) is inside the loop.
        #expect(
            SearchResultsSection.isRowEnclosed(rowFrame: row, loop: loop)
                == true
        )
    }

    @Test("Row whose centroid is outside the loop is not enclosed")
    func isRowEnclosedCentroidOutside() {
        let loop = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 0, y: 100),
        ]
        let row = CGRect(x: 300, y: 300, width: 100, height: 50)
        #expect(
            SearchResultsSection.isRowEnclosed(rowFrame: row, loop: loop)
                == false
        )
    }

    // MARK: - Touch-source discrimination

    @Test("Pencil touch-type activates the gesture")
    func isPencilEventForPencil() {
        #expect(SearchResultsSection.isPencilEvent(touchType: .pencil) == true)
    }

    @Test("Finger touch-type does not activate the gesture")
    func isPencilEventForFinger() {
        #expect(SearchResultsSection.isPencilEvent(touchType: .direct) == false)
    }

    @Test("Indirect touch (trackpad) does not activate the gesture")
    func isPencilEventForIndirect() {
        #expect(
            SearchResultsSection.isPencilEvent(touchType: .indirectPointer)
                == false
        )
    }

    // MARK: - Enclosed-row aggregator

    @Test("enclosedRowIDs returns rows whose centroid is inside the loop")
    func enclosedRowIDsSelectsInsideRows() {
        let loop = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 200, y: 0),
            CGPoint(x: 200, y: 200),
            CGPoint(x: 0, y: 200),
        ]
        let inside = UUID()
        let outside = UUID()
        let frames: [UUID: CGRect] = [
            inside: CGRect(x: 50, y: 50, width: 100, height: 30),
            outside: CGRect(x: 300, y: 300, width: 100, height: 30),
        ]
        let enclosed = SearchResultsSection.enclosedRowIDs(
            loop: loop,
            rowFrames: frames
        )
        #expect(enclosed == [inside])
    }

    @Test("enclosedRowIDs returns empty when no row centroid is inside")
    func enclosedRowIDsEmptyWhenAllOutside() {
        let loop = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 50, y: 0),
            CGPoint(x: 50, y: 50),
            CGPoint(x: 0, y: 50),
        ]
        let frames: [UUID: CGRect] = [
            UUID(): CGRect(x: 100, y: 100, width: 50, height: 30),
            UUID(): CGRect(x: 200, y: 200, width: 50, height: 30),
        ]
        let enclosed = SearchResultsSection.enclosedRowIDs(
            loop: loop,
            rowFrames: frames
        )
        #expect(enclosed.isEmpty)
    }

    @Test("enclosedRowIDs returns multiple rows when several are inside")
    func enclosedRowIDsMultipleInside() {
        let loop = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 500, y: 0),
            CGPoint(x: 500, y: 500),
            CGPoint(x: 0, y: 500),
        ]
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let outside = UUID()
        let frames: [UUID: CGRect] = [
            a: CGRect(x: 50, y: 50, width: 100, height: 30),
            b: CGRect(x: 100, y: 200, width: 100, height: 30),
            c: CGRect(x: 200, y: 350, width: 100, height: 30),
            outside: CGRect(x: 700, y: 700, width: 100, height: 30),
        ]
        let enclosed = SearchResultsSection.enclosedRowIDs(
            loop: loop,
            rowFrames: frames
        )
        #expect(enclosed == [a, b, c])
    }

    // MARK: - Stroke-lifecycle gate (SA-1, D-71)
    //
    // Row-frame tracking mounts only while a Pencil stroke is live;
    // this pure transition function is the gate policy the overlay's
    // Coordinator dispatches on every recognizer state change.

    @Test("Stroke gate activates on .began and deactivates on terminal states")
    func strokeGateTerminalTransitions() {
        #expect(SearchResultsSection.pencilStrokeGateTransition(for: .began) == true)
        #expect(SearchResultsSection.pencilStrokeGateTransition(for: .ended) == false)
        #expect(SearchResultsSection.pencilStrokeGateTransition(for: .cancelled) == false)
        #expect(SearchResultsSection.pencilStrokeGateTransition(for: .failed) == false)
    }

    @Test("Stroke gate leaves idle and mid-stroke states unchanged")
    func strokeGateNoChangeTransitions() {
        #expect(SearchResultsSection.pencilStrokeGateTransition(for: .possible) == nil)
        #expect(SearchResultsSection.pencilStrokeGateTransition(for: .changed) == nil)
    }
}

// q18 hit-test regression pins: the overlay view must NEVER claim a
// hit (the pre-fix `event.allTouches` check never fired during
// hit-testing, so the overlay stole every finger touch over the
// results list — row taps and finger scroll were silent no-ops), and
// the Pencil recognizer must ride the window, not the overlay.
@Suite("Pencil overlay touch passthrough (q18)")
@MainActor
struct PencilTouchPassthroughTests {
    @Test("Overlay view never claims hit-testing")
    func hitTestAlwaysNil() {
        let view = PencilTouchPassthroughView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(view.hitTest(CGPoint(x: 200, y: 200), with: nil) == nil)
    }

    @Test("Recognizer attaches to the window on entry and detaches on exit")
    func recognizerRidesWindow() {
        let view = PencilTouchPassthroughView()
        let recognizer = PencilCircleSelectGestureRecognizer(target: nil, action: nil)
        view.hostedRecognizer = recognizer
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.addSubview(view)
        #expect(window.gestureRecognizers?.contains(recognizer) == true)
        view.removeFromSuperview()
        #expect(window.gestureRecognizers?.contains(recognizer) != true)
    }
}
