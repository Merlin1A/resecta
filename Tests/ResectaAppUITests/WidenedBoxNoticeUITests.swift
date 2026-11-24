import XCTest

/// The widened-box notice as a user meets it: the results sheet's banner
/// names the page whose boxes were widened, the parked walk shows the fit
/// notice in the editor's band on that page, and after the apply the notice
/// stays on the widened page, with the Rectangle tool on too, and is absent
/// from a clean one. A run with no widened box shows neither. The notice
/// may be open or folded (it folds when the page meets the band): either
/// counts. `--uitestWidenPage=0` (a DEBUG launch hook) marks page
/// 1's results of the seeded "Amount" query widened.
///
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class WidenedBoxNoticeUITests: XCTestCase {

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

    /// The fit notice open, or its folded mark speaking the fit sentence.
    private var fitNotice: XCUIElement { element("fitNotice") }
    private var foldedFitNotice: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "noticeFoldedMark")
            .matching(NSPredicate(format: "label CONTAINS 'than their words'")).firstMatch
    }

    /// Waits for the open notice or its folded mark; returns the one found.
    private func waitForFitNotice(timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if fitNotice.exists { return fitNotice }
            if foldedFitNotice.exists { return foldedFitNotice }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        attachScreenshot(named: "fit-notice-not-found")
        return nil
    }

    private func fitNoticeGone(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !fitNotice.exists && !foldedFitNotice.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    /// The notice sits in the band: its top within 30 pt under the toolbar.
    private func assertInTheBand(_ notice: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let toolbarBottom = app.navigationBars.firstMatch.frame.maxY
        let top = notice.frame.minY
        XCTAssertTrue(top >= toolbarBottom - 1 && top <= toolbarBottom + 30,
                      "The fit notice's top \(top) is not in the band under the toolbar (\(toolbarBottom)).",
                      file: file, line: line)
    }

    /// Launch with page 1 widened, walk to it, Select All and apply, and
    /// close the sheet: the editor with page 1 in view.
    private func applyOnTheWidenedPage() {
        launch(widenPage: 0)
        XCTAssertTrue(element("widenedBoxBanner").waitForExistence(timeout: 30), "The results sheet must name the page.")
        app.buttons["resultNavNext"].tap()
        XCTAssertTrue(element("compactFloatStrip").waitForExistence(timeout: 10), "The walk did not park the sheet.")
        raiseAndApply()
    }

    private func raiseAndApply() {
        let raise = app.windows.firstMatch
        raise.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            .press(forDuration: 0.1, thenDragTo: raise.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        let selectAll = app.buttons["footerSelectAllButton"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "The raised sheet shows Select All.")
        selectAll.tap()
        let apply = app.buttons["searchApplyButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: apply)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed)
        apply.tap()
        let dismiss = app.buttons["searchDismissButton"]
        if dismiss.waitForExistence(timeout: 10) { dismiss.tap() }
        _ = dismiss.waitForNonExistence(timeout: 10)
        // The apply's own notice sits in the band for a few seconds.
        let marked = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Marked'")).firstMatch
        _ = marked.waitForNonExistence(timeout: 20)
    }

    private func launch(widenPage: Int?) {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ] + (widenPage.map { ["--uitestWidenPage=\($0)"] } ?? [])
        app.launch()
    }

    func testBannerCaptionAndAfterApply() {
        launch(widenPage: 0)
        let banner = element("widenedBoxBanner")
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "The results sheet must name the page with widened boxes.")
        XCTAssertTrue(banner.label.contains("page 1 were drawn larger"), "The banner reads \"\(banner.label)\".")
        attachScreenshot(named: "widened-banner")

        app.buttons["resultNavNext"].tap()
        XCTAssertTrue(element("compactFloatStrip").waitForExistence(timeout: 10), "The walk did not park the sheet.")
        let parked = waitForFitNotice(timeout: 10)
        XCTAssertNotNil(parked, "The parked walk on page 1 must show the fit notice in the band.")
        if let parked { assertInTheBand(parked) }
        attachScreenshot(named: "fit-notice-parked")

        raiseAndApply()
        let after = waitForFitNotice(timeout: 10)
        XCTAssertNotNil(after, "After the apply, page 1 keeps its notice with the sheet gone.")
        if let after { assertInTheBand(after) }
        XCTAssertFalse(element("widenedBoxCapsule").exists, "The bottom slot holds no widened-box notice.")
        attachScreenshot(named: "fit-notice-after-apply")
        app.buttons["pageNavNext"].tap()
        XCTAssertTrue(fitNoticeGone(timeout: 10), "Page 2's boxes are not widened: no notice there.")
        app.buttons["pageNavPrevious"].tap()
        XCTAssertNotNil(waitForFitNotice(timeout: 10), "Back on page 1, the notice is back.")
    }

    func testFitNotice_staysInTheBandWithTheRectangleToolOn() {
        applyOnTheWidenedPage()
        let before = waitForFitNotice(timeout: 10)
        XCTAssertNotNil(before, "After the apply, page 1 shows the fit notice.")
        let wasFolded = before.map { $0.identifier == "noticeFoldedMark" } ?? false
        let tool = app.buttons["drawTool"]
        XCTAssertTrue(tool.waitForExistence(timeout: 10))
        tool.tap()
        XCTAssertTrue(element("drawingCaption").waitForExistence(timeout: 10), "The Rectangle tool's caption is in the slot.")
        if wasFolded {
            // A folded mark hides while the tool is on, and is back with it off.
            XCTAssertTrue(fitNoticeGone(timeout: 5), "The folded mark hides while the tool is on.")
            tool.tap()
            XCTAssertNotNil(waitForFitNotice(timeout: 10), "The folded mark is back with the tool off.")
        } else {
            XCTAssertTrue(fitNotice.exists, "The open fit notice stays in the band with the tool on.")
            assertInTheBand(fitNotice)
            attachScreenshot(named: "fit-notice-with-rectangle-tool")
        }
    }

    func testNoNoticeWithoutAWidenedBox() {
        launch(widenPage: nil)
        XCTAssertTrue(app.buttons["resultNavNext"].waitForExistence(timeout: 30), "The seeded query returned nothing.")
        XCTAssertFalse(element("widenedBoxBanner").exists, "No banner when no box is widened.")
        app.buttons["resultNavNext"].tap()
        XCTAssertTrue(element("compactFloatStrip").waitForExistence(timeout: 10))
        XCTAssertTrue(fitNoticeGone(timeout: 3), "No fit notice when no box is widened.")
        XCTAssertFalse(fitNotice.waitForExistence(timeout: 3), "No fit notice when no box is widened.")
    }
}
