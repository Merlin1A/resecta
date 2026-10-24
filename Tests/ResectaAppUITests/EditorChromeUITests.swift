import XCTest

/// UI tests for the editor's chrome: the page bar's whole-page control as a
/// per-page toggle that keeps its place, the page bar on a one-page
/// document, and the parked match walk letting go of a match the page bar
/// pages away from.
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

    // MARK: - The parked walk follows the page bar

    func testParkedWalk_pagingAwayTurnsApplyOff() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        next.tap()
        let apply = app.buttons["applyCurrentResultButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10), "The parked strip's Apply never appeared.")
        XCTAssertTrue(apply.isEnabled, "Parked on a match, Apply must be enabled.")

        let pageNext = app.buttons["pageNavNext"]
        XCTAssertTrue(pageNext.waitForExistence(timeout: 5), "The page bar's next control is missing while parked.")
        for _ in 0..<3 { pageNext.tap() }
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == false"), object: apply)
        XCTAssertEqual(XCTWaiter().wait(for: [disabled], timeout: 8), .completed,
                       "Paging away from the current match must turn the strip's Apply off.")
        attachScreenshot(named: "chrome-parked-walk-paged-away")
    }
}
