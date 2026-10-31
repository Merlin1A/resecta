import XCTest

/// A pinch zoom survives a page change from the page bar: the next page
/// opens at the zoom the reader chose. The zoom is read from a screenshot,
/// as in `CanvasGeometryUITests`: just above the fit page's top edge the
/// canvas shows its background at the fit zoom, and page when zoomed in.
///
/// nonisolated: an XCUITest drives a separate process and touches no
/// @MainActor state.
nonisolated final class CanvasPageChangeZoomUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
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

    func testThePinchZoomSurvivesAPageChange() throws {
        let page = try XCTUnwrap(try probe().fitPage(), "the page at fit is measurable")
        let above = CGPoint(x: page.midX, y: page.minY - 8)
        XCTAssertTrue(try probe().isBackground(above), "at fit the canvas shows above the page")

        let canvas = app.scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height } ?? app.scrollViews.firstMatch
        var zoomed = false
        for _ in 1...2 where !zoomed {
            canvas.pinch(withScale: 2.0, velocity: 1.0)
            sleep(3)
            zoomed = try !probe().isBackground(above)
        }
        XCTAssertTrue(zoomed, "the pinch zooms the page")
        attachShot("zoomed-page-1")

        let next = app.buttons["pageNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        let counter = app.descendants(matching: .any).matching(identifier: "pageNavCounter").firstMatch
        let onPage2 = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Page 2 of'"), object: counter)
        XCTAssertEqual(XCTWaiter().wait(for: [onPage2], timeout: 10), .completed, "the page bar moved to page 2")
        sleep(2)
        attachShot("after-page-change")
        XCTAssertFalse(try probe().isBackground(above), "page 2 opened at the fit zoom: the pinch zoom was lost")
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
