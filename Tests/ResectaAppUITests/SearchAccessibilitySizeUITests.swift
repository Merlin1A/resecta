import XCTest

// The search surfaces at the largest accessibility text size
// (`UICTContentSizeCategoryAccessibilityXXXL`, "AX5"): the sheet
// header's three pieces each on a line of their own, the parked
// strip's Apply capsule named by its state, and the page bar's counter
// as one spoken element. A NEW suite file: `SearchDetentLayoutUITests`
// is tracked by the growth ratchet and may not grow. The size is set
// with the launch argument every UIKit app honours, so the sim's
// Settings are never touched.
nonisolated final class SearchAccessibilitySizeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - The header

    /// Dismiss and "Apply N" each on one line: both buttons stand on
    /// the floor and neither is taller than one AX5 text line (a
    /// hyphenated "Dis-/miss" measured 125 pt; one line is under 80).
    func testHeaderPiecesSitOnTheirOwnLines() {
        app.launch()
        let dismiss = app.buttons["searchDismissButton"]
        let apply = app.buttons["searchApplyButton"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 30), "The sheet header never presented.")
        XCTAssertTrue(apply.exists, "The Apply button is missing from the header.")
        for (name, element) in [("Dismiss", dismiss), ("Apply", apply)] {
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) height \(element.frame.height) is under the effective floor.")
            XCTAssertLessThan(element.frame.height, 80, "\(name) height \(element.frame.height) reads as two lines at AX5 (a hyphenated label).")
        }
        // Stacked: Apply sits below Dismiss, not beside it.
        XCTAssertGreaterThan(apply.frame.minY, dismiss.frame.maxY - 1, "Apply is beside Dismiss — the header did not stack at AX5.")
        attachScreenshot(named: "ax5-header-stacked")
    }

    // MARK: - The parked strip

    /// After one Apply the capsule is named "Applied" and its value
    /// keeps the match's position ("Amount, Page 1 of 23").
    func testParkedStripAppliedStateIsNamedApplied() {
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        next.tap()
        let strip = app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "The first chevron tap did not park the sheet.")
        let apply = app.buttons["applyCurrentResultButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5), "The parked strip's Apply capsule is missing.")
        XCTAssertEqual(apply.label, "Apply", "Before the mark the capsule reads Apply.")
        apply.tap()
        let applied = app.buttons["applyCurrentResultButton"]
        let named = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Applied"), object: applied
        )
        XCTAssertEqual(XCTWaiter().wait(for: [named], timeout: 10), .completed,
                       "The capsule never read Applied after the tap (label: \(applied.label)).")
        XCTAssertTrue(applied.value.map { "\($0)" }?.contains("Page ") ?? false,
                      "The applied capsule's value lost the position: \(String(describing: applied.value)).")
        XCTAssertGreaterThanOrEqual(applied.frame.height, 44, "The applied capsule is under the effective floor.")
        attachScreenshot(named: "ax5-strip-applied")
    }

    // MARK: - The page bar

    /// The counter is one element whose label starts "Page 1 of".
    func testPageBarCounterIsOneSpokenElement() {
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        next.tap()
        let counter = app.descendants(matching: .any).matching(identifier: "pageNavCounter").firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 10), "The page bar's counter element is missing.")
        XCTAssertTrue(counter.label.hasPrefix("Page 1 of "), "The counter reads \"\(counter.label)\", not one 'Page 1 of N' element.")
        attachScreenshot(named: "ax5-page-bar")
    }
}
