import XCTest

/// UI tests for the editor's chrome: the page bar's whole-page control as a
/// per-page toggle that keeps its place, the page bar on a one-page
/// document, and the page bar back once a parked match walk ends.
///
/// Launch arguments only; every assertion reads identifiers and labels.
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class EditorChromeUITests: XCTestCase {

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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Wait until `element`'s label equals `label`.
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Mark ↔ Unmark

    func testWholePageControl_marksThenUnmarksInPlace() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()

        let control = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(control.waitForExistence(timeout: 30), "The page bar's whole-page control never appeared.")
        let counter = element("pageNavCounter")
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 23, 0 regions"),
                      "An empty page's counter must speak its zero count; it read '\(counter.label)'.")
        XCTAssertEqual(control.label, "Mark Whole Page")
        let xBefore = control.frame.midX

        control.tap()
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 23, 1 region"),
                      "Mark Whole Page must add one region; the counter read '\(counter.label)'.")
        XCTAssertTrue(waitForLabel(control, "Unmark Whole Page"), "A marked page's control must read Unmark Whole Page.")
        XCTAssertTrue(control.isSelected, "A marked page's control must report itself selected.")
        XCTAssertEqual(control.frame.midX, xBefore, accuracy: 0.5,
                       "The control must keep its place when the count appears.")
        attachScreenshot(named: "chrome-page-bar-marked")

        control.tap()
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 23, 0 regions"),
                      "Unmark Whole Page must remove the region; the counter read '\(counter.label)'.")
        XCTAssertTrue(waitForLabel(control, "Mark Whole Page"))
        XCTAssertFalse(control.isSelected)
        XCTAssertEqual(control.frame.midX, xBefore, accuracy: 0.5)
    }

    // MARK: - The one-page bar

    func testOnePageDocument_showsTheCountWithoutArrowsOrControl() {
        app.launchArguments = ["--uitesting", "--loadTestDocument"]
        app.launch()

        let counter = element("pageNavCounter")
        XCTAssertTrue(counter.waitForExistence(timeout: 30), "A one-page document must show the page bar's counter.")
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 1, 0 regions"),
                      "The one-page counter read '\(counter.label)'.")
        XCTAssertTrue(app.staticTexts["1 of 1"].exists, "The drawn counter must read '1 of 1'.")
        XCTAssertFalse(app.buttons["pageNavPrevious"].exists, "No page arrows on a one-page document.")
        XCTAssertFalse(app.buttons["pageNavNext"].exists, "No page arrows on a one-page document.")
        XCTAssertFalse(app.buttons["pageNavMarkWholePage"].exists,
                       "No whole-page control on a one-page document; the … menu keeps the action.")
        attachScreenshot(named: "chrome-page-bar-one-page")
    }

    // MARK: - The page bar comes back when the walk ends

    /// The bar steps aside while the walk is parked and is back, usable,
    /// once the sheet is dismissed and the walk ends.
    func testWalkEnds_pageBarReturns() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        next.tap()
        XCTAssertTrue(element("compactFloatStrip").waitForExistence(timeout: 10), "The first chevron tap did not park the sheet.")
        let pageBar = element("pageNav")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pageBar)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "The page bar must step aside while the walk is parked.")

        let dismiss = raiseSheetToDismiss()
        XCTAssertNotNil(dismiss, "The sheet's Dismiss never appeared after the raise.")
        dismiss?.tap()
        let pageNext = app.buttons["pageNavNext"]
        XCTAssertTrue(pageNext.waitForExistence(timeout: 10), "The page bar must be back once the walk ends.")
        XCTAssertTrue(pageNext.isHittable, "The page bar's next control must be usable once the walk ends.")
        let counter = element("pageNavCounter")
        let before = counter.label
        pageNext.tap()
        let paged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: counter)
        XCTAssertEqual(XCTWaiter().wait(for: [paged], timeout: 8), .completed, "The returned page bar must page.")
        attachScreenshot(named: "chrome-walk-ended-page-bar-back")
    }

    /// Grabber drag from the parked strip up until the sheet's Dismiss
    /// shows (`ResultWalkUITests`' idiom); the Dismiss, or nil.
    private func raiseSheetToDismiss() -> XCUIElement? {
        let window = app.windows.firstMatch
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        for _ in 0..<3 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.1, thenDragTo: end)
            if dismiss.waitForExistence(timeout: 3), dismiss.isHittable { return dismiss }
        }
        return nil
    }
}
