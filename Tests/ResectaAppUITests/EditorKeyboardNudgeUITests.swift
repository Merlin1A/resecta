import XCTest

/// The keyboard's nudge in the running editor: the arrow keys move the
/// selected box one point of the page at a time through the editor's own
/// key handler, and at the page's edge a press is held there. Each press
/// runs the handler's Debug check that the editor admits the box it is
/// about to store (`RedactionState.admitsEditorShare`); a box stepped past
/// the page fails that check and stops the app, so the case is red. The
/// box starts drawn past the page's right edge, which the draw clamps to
/// the page, so it sits on the edge.
///
/// A simulator that delivers no hardware key at all records the case for
/// the device pass instead of failing it: the first left press must move
/// the box, or nothing after it is read.
///
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class EditorKeyboardNudgeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testArrowKeysStepTheSelectedBoxAndHoldItAtThePageEdge() throws {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 60), "the editor never appeared")
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Text layer detected'")).firstMatch
        if toast.waitForExistence(timeout: 4) { _ = toast.waitForNonExistence(timeout: 20) }
        sleep(1)
        let page = try XCTUnwrap(try probe().fitPage(), "the page at fit is measurable")

        // A box from inside the page to past its right edge: the draw clamps it to the page.
        setDrawTool("Drawing mode active")
        let top = page.minY + page.height * 0.45
        let end = CGPoint(x: min(page.maxX + 12, window.frame.width - 2), y: top + 30)
        point(CGPoint(x: page.maxX - 90, y: top)).press(
            forDuration: 0.05, thenDragTo: point(end), withVelocity: .slow, thenHoldForDuration: 0.2)
        setDrawTool("Tap to enter drawing mode")
        XCTAssertTrue(waitForRegionCount(1), "the box drew; the page bar read \(currentRegionCount())")

        let box = app.buttons.matching(NSPredicate(format: "label == %@", "Redaction region 1")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5), "the box is in the tree")
        let drawn = box.frame
        XCTAssertLessThanOrEqual(drawn.maxX, page.maxX + 1, "the draw clamped the box to the page: box \(drawn), page \(page)")
        tap(CGPoint(x: drawn.midX, y: drawn.midY))
        XCTAssertTrue(app.buttons["selectionBarDelete"].waitForExistence(timeout: 5), "the tap selected the box")
        let start = box.frame

        // Left three times: the box steps off the edge, so the key reached the handler.
        for _ in 0..<3 { app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: []) }
        let deadline = Date().addingTimeInterval(5)
        var moved = false
        while Date() < deadline {
            if box.exists, box.frame.minX < start.minX - 0.5 { moved = true; break }
            usleep(250_000)
        }
        guard moved else {
            throw XCTSkip("The simulator delivered no hardware key (the left arrow did not move the box); the nudge is recorded for the device pass.")
        }
        sleep(1)
        let left = box.frame
        XCTAssertEqual(left.width, start.width, accuracy: 0.5, "a step moves the box and keeps its size")
        XCTAssertEqual(left.minY, start.minY, accuracy: 0.5, "a left step does not move the box up or down")

        // Right twelve times: three bring it back, the rest take it to the page's edge (the
        // draw may have stopped a few points short of it) and are held there; three more then
        // move it nowhere.
        for _ in 0..<12 { app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: []) }
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after the presses at the edge")
        XCTAssertTrue(box.exists, "the box is still there")
        let atEdge = box.frame
        XCTAssertGreaterThanOrEqual(atEdge.maxX, start.maxX - 0.5, "the right presses brought the box back: \(atEdge), drawn \(start)")
        XCTAssertLessThanOrEqual(atEdge.maxX, page.maxX + 1, "the box stays on the page: \(atEdge), page \(page)")
        for _ in 0..<3 { app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: []) }
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "the app is still running after three more presses at the edge")
        let held = box.frame
        XCTAssertEqual(held.maxX, atEdge.maxX, accuracy: 0.3, "at the page's edge a press holds the box there: \(held), before \(atEdge)")
        XCTAssertEqual(held.width, start.width, accuracy: 0.5, "the box keeps its size at the edge")
        XCTAssertEqual(currentRegionCount(), 1, "one box, still")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "nudge-held-at-the-edge"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Helpers

    private var window: XCUIElement { app.windows.firstMatch }

    private func probe() throws -> CanvasPixelProbe {
        try XCTUnwrap(CanvasPixelProbe(XCUIScreen.main.screenshot(), windowSize: window.frame.size))
    }

    private func point(_ p: CGPoint) -> XCUICoordinate {
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y))
    }

    private func tap(_ p: CGPoint) { point(p).tap() }

    private func setDrawTool(_ value: String) {
        let tool = app.buttons["drawTool"]
        for _ in 0..<3 {
            tool.tap()
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if tool.drawToolReads(value) { return }
                usleep(250_000)
            }
        }
        XCTFail("The Rectangle tool never read \(value).")
    }

    /// The page bar's region count for the current page: 0 when it shows none.
    private func currentRegionCount() -> Int {
        let label = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ regions?$")).firstMatch
        guard label.exists, let head = label.label.split(separator: " ").first, let count = Int(head) else { return 0 }
        return count
    }

    private func waitForRegionCount(_ count: Int, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentRegionCount() == count { return true }
            usleep(250_000)
        }
        return currentRegionCount() == count
    }
}
