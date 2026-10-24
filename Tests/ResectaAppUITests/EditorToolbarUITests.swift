import XCTest

/// UI tests for the editor's iPhone toolbar: the … menu's order, the one
/// Undo control (a tap undoes; a touch and hold opens Undo and Redo named
/// for their steps), and Redact staying available with selected matches
/// not yet applied — a tap raises the search sheet instead of redacting.
///
/// Launch arguments only; assertions read identifiers and labels.
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class EditorToolbarUITests: XCTestCase {

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

    private var counter: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "pageNavCounter").firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLabel(_ element: XCUIElement, notContaining text: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "NOT (label CONTAINS %@)", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Open the multipage document and mark page 1 so the page has a region.
    private func launchWithOneRegion() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()
        let mark = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(mark.waitForExistence(timeout: 30), "The page bar never appeared.")
        mark.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "1 region"), "Marking the page did not add a region.")
    }

    // MARK: - The … menu's order

    func testOverflowMenu_listsSelectionActionsFirstAndHomeLast() {
        launchWithOneRegion()
        let overflow = app.buttons["OverflowBarButtonItem"].firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "The … menu button is missing.")
        overflow.tap()

        let expected = ["Select Regions", "Add to Selection", "Mark Whole Page", "Switch Mode", "Settings", "Home"]
        var ys: [CGFloat] = []
        for label in expected {
            let row = app.buttons[label].firstMatch.exists ? app.buttons[label].firstMatch
                : app.switches[label].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "The … menu has no '\(label)' row.")
            ys.append(row.frame.midY)
        }
        XCTAssertEqual(ys, ys.sorted(), "The … menu's rows are out of order: \(zip(expected, ys).map { "\($0) \($1)" })")
        XCTAssertFalse(app.buttons["More"].exists && app.buttons["Delete Selected"].exists,
                       "The separate More menu must be gone.")
        attachScreenshot(named: "toolbar-overflow-order")
    }

    // MARK: - The Undo control

    func testUndoControl_tapUndoesAndHoldNamesTheSteps() {
        launchWithOneRegion()
        let undo = app.buttons["undoButton"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "The Undo control is missing from the bar.")

        undo.press(forDuration: 0.8)
        let undoRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Undo '")).firstMatch
        XCTAssertTrue(undoRow.waitForExistence(timeout: 5), "A touch and hold must open the Undo menu with the step's name.")
        attachScreenshot(named: "toolbar-undo-menu")
        undoRow.tap()
        XCTAssertTrue(waitForLabel(counter, notContaining: "1 region"), "The menu's Undo row must undo the mark.")

        undo.press(forDuration: 0.8)
        let redoRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Redo '")).firstMatch
        XCTAssertTrue(redoRow.waitForExistence(timeout: 5), "With a step to redo, the menu must offer Redo with its name.")
        redoRow.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "1 region"), "Redo must bring the region back.")

        undo.tap()
        XCTAssertTrue(waitForLabel(counter, notContaining: "1 region"), "A tap on Undo must undo at once.")
    }

    // MARK: - Redact with unapplied matches

    func testRedact_withUnappliedMatches_raisesTheSheetInsteadOfRedacting() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
        app.launch()
        let selectAll = app.buttons["footerSelectAllButton"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        selectAll.tap()
        let next = app.buttons["resultNavNext"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        let strip = app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "The walk did not park the sheet.")

        // A region of the user's own, so only the selections stand in the way.
        let mark = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(mark.waitForExistence(timeout: 10))
        mark.tap()

        let redact = app.buttons["redactButton"].firstMatch
        XCTAssertTrue(redact.waitForExistence(timeout: 10), "Redact is missing from the bar.")
        XCTAssertTrue(redact.isEnabled, "Unapplied matches must not grey Redact out.")
        redact.tap()
        XCTAssertTrue(app.buttons["searchDismissButton"].waitForExistence(timeout: 10),
                      "A tap on Redact with unapplied matches must raise the sheet.")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "verificationResults").firstMatch.exists,
                       "Redact must not run without the selected matches.")
        attachScreenshot(named: "toolbar-redact-explains")
    }
}
