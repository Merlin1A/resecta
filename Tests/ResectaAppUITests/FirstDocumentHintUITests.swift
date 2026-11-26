import XCTest
import UIKit

/// UI tests for the first-time line: it shows on a first document, leaves at
/// the first touch or page turn and never comes back; a touch on the line
/// reaches nothing under it; at the largest text size it is drawn whole in
/// the slot's place with the folded form; and a test launch with neither of
/// its arguments never meets it.
///
/// Launch arguments only; assertions read identifiers and labels.
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class FirstDocumentHintUITests: XCTestCase {

    private var app: XCUIApplication!

    private static let document = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
    private static let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    private static let largestOrdinary = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]

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

    private var line: XCUIElement { element("firstDocumentHint") }
    private var counter: XCUIElement { element("pageNavCounter") }

    private func launch(_ arguments: [String]) {
        app.launchArguments = Self.document + arguments
        app.launch()
        XCTAssertTrue(app.buttons["pageNavMarkWholePage"].waitForExistence(timeout: 30), "The page bar never appeared.")
    }

    /// The line shows; it may wait behind the import's own message first.
    private func lineShows(file: StaticString = #filePath, line number: UInt = #line) {
        XCTAssertTrue(line.waitForExistence(timeout: 30), "The first-time line never showed.", file: file, line: number)
    }

    private func lineLeaves(_ why: String, file: StaticString = #filePath, line number: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: line)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "The line stayed after \(why).",
                       file: file, line: number)
    }

    private func noLineFor5Seconds(_ why: String, file: StaticString = #filePath, line number: UInt = #line) {
        XCTAssertFalse(line.waitForExistence(timeout: 5), "The line showed \(why).", file: file, line: number)
    }

    func testFirstDocument_lineShowsOnceAndLeavesAtTheFirstToolbarTap() {
        launch(["--firstDocumentHintFresh"])
        lineShows()
        XCTAssertEqual(line.label, "Use Search or Scan. Then use Redact.")
        app.buttons["drawTool"].tap()
        lineLeaves("a tap on the Rectangle tool")
        app.terminate()
        launch(["--firstDocumentHintStored"])
        noLineFor5Seconds("again after the first action")
    }

    func testFirstDocument_lineLeavesAtATouchOnThePage_andATouchOnTheLineReachesNothingUnderIt() {
        launch(["--firstDocumentHintFresh"])
        lineShows()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        lineLeaves("a touch on the page")
        app.terminate()

        launch(["--firstDocumentHintFresh"])
        lineShows()
        XCTAssertTrue(counter.label.contains("0 regions"), "The page held a box before the touch: \(counter.label)")
        line.tap()
        lineLeaves("a touch on the line itself")
        XCTAssertTrue(counter.label.contains("0 regions"), "A touch on the line reached the page: \(counter.label)")
    }

    func testFirstDocument_lineLeavesAtAPageTurn() {
        launch(["--firstDocumentHintFresh"])
        lineShows()
        let next = app.buttons["pageNavNext"]
        XCTAssertTrue(next.exists, "The next-page button is missing.")
        next.tap()
        lineLeaves("a page turn")
    }

    func testFirstDocument_atTheLargestSize_lineIsDrawnWholeInTheSlotWithTheFoldedForm() {
        launch(["--firstDocumentHintFresh"] + Self.largest)
        XCTAssertGreaterThan(counter.frame.height, 40, "The largest text size did not take.")
        lineShows()
        // Redact is not on the bar at this size.
        XCTAssertFalse(app.buttons["Redact"].exists, "Redact is on the bar at the largest size.")
        let bar = element("pageNav")
        // The bar's element reports its content without its 8 points of padding.
        let glass = bar.frame.minY - 8
        let top = app.navigationBars.firstMatch.frame.maxY
        let frame = line.frame
        XCTContext.runActivity(named: "line \(frame), canvas \(glass - top)") { _ in }
        XCTAssertGreaterThanOrEqual(frame.minY, top, "The line runs under the toolbar.")
        XCTAssertEqual(glass - frame.maxY, 8, accuracy: 2, "The line's foot is \(glass - frame.maxY) pt above the page bar's glass.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        lineLeaves("a touch at the largest size")
    }

    func testFirstDocument_atTheLargestOrdinarySize_redactIsInTheMenuAndTheLineShows() {
        launch(["--firstDocumentHintFresh"] + Self.largestOrdinary)
        // The size took: the bar folds Redact into the More menu at this size and not below.
        XCTAssertTrue(app.editorOverflowButton.waitForExistence(timeout: 10), "The More menu button is missing.")
        XCTAssertFalse(app.buttons["Redact"].exists, "Redact is on the bar at the largest ordinary size.")
        lineShows()
        XCTAssertEqual(line.label, "Use Search or Scan. Then use Redact.")
    }

    func testUITestLaunch_withNeitherArgument_theLineNeverShows() {
        launch(["--firstDocumentHintFresh"])
        lineShows()
        app.terminate()
        // The flag is still unset: nothing was touched.
        launch(["--firstDocumentHintStored"])
        lineShows()
        app.terminate()
        launch([])
        noLineFor5Seconds("under a test launch with neither argument")
    }
}
