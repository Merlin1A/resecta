import XCTest

/// A walk step that does not park the sheet (the k key) scrolls the match
/// into view at the zoom the reader chose: a pinch zoom survives it. The
/// zoom is read from a screenshot, as in `CanvasGeometryUITests`: just
/// above the fit page's top edge the canvas shows its background at the
/// fit zoom, and page when zoomed in.
///
/// nonisolated: an XCUITest drives a separate process and touches no
/// @MainActor state.
nonisolated final class CanvasWalkKeyAtZoomUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc", "--searchQuery=Amount"]
        app.launch()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 60), "the editor never appeared")
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Text layer detected'")).firstMatch
        if toast.waitForExistence(timeout: 4) { _ = toast.waitForNonExistence(timeout: 20) }
        sleep(1)
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testAKeyStepKeepsThePinchZoom() throws {
        let page = try XCTUnwrap(try probe().fitPage(), "the page at fit is measurable")
        let above = CGPoint(x: page.midX, y: page.minY - 8)
        let canvas = app.scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height } ?? app.scrollViews.firstMatch
        var zoomed = false
        for _ in 1...2 where !zoomed {
            canvas.pinch(withScale: 2.0, velocity: 1.0)
            sleep(3)
            zoomed = try !probe().isBackground(above)
        }
        XCTAssertTrue(zoomed, "the pinch zooms the page")

        app.buttons["searchRedact"].tap()
        XCTAssertTrue(app.buttons["searchDismissButton"].firstMatch.waitForExistence(timeout: 15), "the search sheet opened")
        sleep(2)
        XCTAssertFalse(try probe().isBackground(above), "the sheet's arrival keeps the zoom")

        let counter = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Result ")).firstMatch
        let before = counter.exists ? counter.label : nil
        app.typeKey("k", modifierFlags: [])
        let deadline = Date().addingTimeInterval(5)
        var stepped = false
        while Date() < deadline {
            if counter.exists, counter.label != before { stepped = true; break }
            usleep(250_000)
        }
        guard stepped else {
            throw XCTSkip("The simulator delivered no hardware key (k did not step the walk); the key step is recorded for the device pass.")
        }
        sleep(2)
        attachShot("after-k")
        XCTAssertFalse(try probe().isBackground(above), "the k step refit the page: the pinch zoom was lost")
    }

    private func probe() throws -> CanvasPixelProbe {
        try XCTUnwrap(CanvasPixelProbe(XCUIScreen.main.screenshot(), windowSize: app.windows.firstMatch.frame.size))
    }

    private func attachShot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
