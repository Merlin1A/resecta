import XCTest

/// The widened-box notice as a user meets it: the results sheet's banner
/// names the page whose boxes were widened, the parked walk shows the page
/// capsule on that page, and after the apply the capsule stays on the
/// widened page and is absent from a clean one. A run with no widened box
/// shows neither. `--uitestWidenPage=0` (a DEBUG launch hook) marks page
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
        XCTAssertTrue(banner.label.contains("page 1 were drawn wider"), "The banner reads \"\(banner.label)\".")
        attachScreenshot(named: "widened-banner")

        app.buttons["resultNavNext"].tap()
        XCTAssertTrue(element("compactFloatStrip").waitForExistence(timeout: 10), "The walk did not park the sheet.")
        let capsule = element("widenedBoxCapsule")
        XCTAssertTrue(capsule.waitForExistence(timeout: 10), "The parked walk on page 1 must show the page capsule.")
        attachScreenshot(named: "widened-capsule-parked")

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

        XCTAssertTrue(capsule.waitForExistence(timeout: 10), "After the apply, page 1 keeps its notice with the sheet gone.")
        // The apply's own notice sits in the same band for a few seconds.
        let marked = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Marked'")).firstMatch
        _ = marked.waitForNonExistence(timeout: 20)
        XCTAssertTrue(capsule.exists, "The page capsule outlasts the apply's notice.")
        attachScreenshot(named: "widened-capsule-after-apply")
        app.buttons["pageNavNext"].tap()
        XCTAssertTrue(capsule.waitForNonExistence(timeout: 10), "Page 2's boxes are not widened: no notice there.")
    }

    func testNoNoticeWithoutAWidenedBox() {
        launch(widenPage: nil)
        XCTAssertTrue(app.buttons["resultNavNext"].waitForExistence(timeout: 30), "The seeded query returned nothing.")
        XCTAssertFalse(element("widenedBoxBanner").exists, "No banner when no box is widened.")
        app.buttons["resultNavNext"].tap()
        XCTAssertTrue(element("compactFloatStrip").waitForExistence(timeout: 10))
        XCTAssertFalse(element("widenedBoxCapsule").waitForExistence(timeout: 3), "No page capsule when no box is widened.")
    }
}
