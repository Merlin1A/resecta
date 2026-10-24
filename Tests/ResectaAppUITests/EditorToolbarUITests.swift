import XCTest

/// UI tests for the editor's iPhone toolbar: the … menu's order, the one
/// Undo control (a tap undoes; a touch and hold opens Undo and Redo named
/// for their steps), Redact staying available with selected matches not yet
/// applied — a tap raises the search sheet instead of redacting — the Add
/// to Selection capsule's Done, and the delete notice's Undo.
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

        // The page is marked, so the whole-page row reads Unmark.
        let expected = ["Select Regions", "Add to Selection", "Unmark Whole Page", "Switch Mode", "Settings", "Home"]
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

        // A region of the user's own, so only the selections stand in the
        // way: from the … menu, as the page bar steps aside while parked.
        openOverflowAndTap("Mark Whole Page")

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

    // MARK: - Add to Selection's capsule

    private func openOverflowAndTap(_ label: String) {
        let overflow = app.buttons["OverflowBarButtonItem"].firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "The … menu button is missing.")
        overflow.tap()
        let row = app.buttons[label].firstMatch.exists ? app.buttons[label].firstMatch : app.switches[label].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The … menu has no '\(label)' row.")
        row.tap()
    }

    func testAddToSelection_capsuleShowsAndDoneEndsTheMode() {
        launchWithOneRegion()
        openOverflowAndTap("Add to Selection")
        let capsule = app.descendants(matching: .any).matching(identifier: "addModeCapsule").firstMatch
        XCTAssertTrue(capsule.waitForExistence(timeout: 5), "Add to Selection must show its capsule.")
        attachScreenshot(named: "toolbar-add-capsule")
        app.buttons["addModeDoneButton"].firstMatch.tap()
        XCTAssertTrue(capsule.waitForNonExistence(timeout: 5), "Done must end Add to Selection and its capsule.")
    }

    // MARK: - The delete notice

    func testDeleteTwoRegions_noticeUndoRestoresThem() {
        launchWithOneRegion()
        // A second region, drawn.
        let draw = app.buttons["drawTool"].firstMatch
        XCTAssertTrue(draw.waitForExistence(timeout: 10))
        draw.tap()
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.40))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)))
        draw.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "2 regions"), "The drawn box did not count.")

        openOverflowAndTap("Select Regions")
        let selectAll = app.buttons["Select All on Page"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        openOverflowAndTap("Delete 2 Regions")
        XCTAssertTrue(waitForLabel(counter, containing: "0 regions"), "Both regions must go at once.")
        let notice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Deleted 2 regions.'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "Deleting two must show the notice.")
        attachScreenshot(named: "toolbar-delete-notice")
        // The notice's button speaks as "Undo action" (ToastView).
        let undo = app.buttons["Undo action"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "The notice must offer Undo.")
        undo.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "2 regions"), "The notice's Undo must restore both.")
    }
}
