import XCTest

/// Typing into a freshly opened Search sheet must not cost the field its
/// keyboard focus, and the sheet must not move, when the first results
/// arrive or when the field is emptied.
///
/// nonisolated for the same reason as the sibling suites: an XCUITest
/// drives a separate process and touches no @MainActor app state.
nonisolated final class SearchTypingFocusUITests: XCTestCase {

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

    private func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    /// Opens Search on the 23-page fixture with the software keyboard
    /// up and the field empty; returns the field, the keyboard and the
    /// header's resting y.
    private func openSearchWithKeyboard() throws -> (field: XCUIElement, keyboard: XCUIElement, headerY: CGFloat) {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()
        let search = app.buttons["searchRedact"]
        XCTAssertTrue(search.waitForExistence(timeout: 40), "Editor toolbar never appeared.")
        search.tap()
        let field = app.textFields["Search text"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Search field never appeared.")
        // A simulator raises the software keyboard with the first typed
        // key. Type and delete one, then start from rest: keyboard up,
        // field empty, the state a phone is in as soon as the sheet opens.
        field.typeText("x")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        let keyboard = app.keyboards.firstMatch
        _ = keyboard.waitForExistence(timeout: 8)
        sleep(2)
        try requireKeyboardOnScreen(keyboard)
        XCTAssertTrue(hasKeyboardFocus(field), "Field not focused at rest.")
        return (field, keyboard, app.buttons["searchDismissButton"].frame.minY)
    }

    /// Some simulators never bring the software keyboard on screen (seen
    /// on iOS 27.2 started from the command line: its frame stays below
    /// the screen). There this class can judge nothing about the sheet
    /// with the keyboard up, so it skips and says why; a skipped run is
    /// not a passed one. On a phone a missing keyboard is a failure.
    private func requireKeyboardOnScreen(_ keyboard: XCUIElement) throws {
        let onScreen = keyboardIsOnScreen(keyboard)
        #if targetEnvironment(simulator)
        try XCTSkipUnless(
            onScreen,
            "No software keyboard on this simulator, so the sheet cannot be judged with the keyboard up. Run this class on an iOS 26.4 simulator or on a phone."
        )
        #else
        XCTAssertTrue(onScreen, "Software keyboard is not on screen.")
        #endif
    }

    private func keyboardIsOnScreen(_ keyboard: XCUIElement) -> Bool {
        keyboard.exists && keyboard.frame.minY < app.windows.firstMatch.frame.maxY - 100
    }

    // MARK: - A drag on a no-rows state (must not change)

    /// Where the sheet is, read from the screen.
    private enum SheetPlace: String { case closed, parked, half, full }

    private func sheetPlace() -> SheetPlace {
        let dismiss = app.buttons["searchDismissButton"]
        if dismiss.exists {
            return dismiss.frame.minY < app.windows.firstMatch.frame.height * 0.25 ? .full : .half
        }
        let strip = app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
        return strip.exists ? .parked : .closed
    }

    /// What a slow drag on the "Text search" state does at half height on
    /// the code before the results area had one root. A change to that
    /// area must leave both as they are.
    private static let placeAfterDragDown = SheetPlace.parked
    private static let placeAfterDragUp = SheetPlace.half
    /// The same for a slow drag down on the "No matches" state.
    private static let placeAfterNoMatchesDragDown = SheetPlace.parked

    /// Search at half height with nothing searched and the keyboard away.
    private func openSearchAtHalfHeightWithNothingSearched() -> XCUIElement {
        let field = openSearch()
        // Return in an empty field starts nothing and gives up the keyboard.
        field.typeText("\n")
        sleep(2)
        XCTAssertEqual(sheetPlace(), .half, "The sheet is not at half height before the drag.")
        let headline = app.staticTexts["Text search"]
        XCTAssertTrue(headline.waitForExistence(timeout: 10), "The no-rows state is not on screen.")
        return headline
    }

    /// A slow drag with a hold at its end, so no fling decides where the
    /// sheet settles.
    private func slowDrag(from element: XCUIElement, by dy: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: dy))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        sleep(2)
    }

    func testHalfHeightNoRowsState_dragDown_doesWhatTheBaseDoes() {
        let headline = openSearchAtHalfHeightWithNothingSearched()
        slowDrag(from: headline, by: 300)
        let place = sheetPlace()
        XCTAssertEqual(place, Self.placeAfterDragDown, "A drag down on the no-rows state left the sheet \(place.rawValue).")
    }

    func testHalfHeightNoRowsState_dragUp_doesWhatTheBaseDoes() {
        let headline = openSearchAtHalfHeightWithNothingSearched()
        slowDrag(from: headline, by: -250)
        let place = sheetPlace()
        XCTAssertEqual(place, Self.placeAfterDragUp, "A drag up on the no-rows state left the sheet \(place.rawValue).")
    }

    func testHalfHeightNoMatchesState_dragDown_doesWhatTheBaseDoes() {
        let field = openSearch()
        field.typeText("Zqx")
        let headline = app.staticTexts["No matches"]
        XCTAssertTrue(headline.waitForExistence(timeout: 15), "The no-match state never appeared.")
        // Return gives up the keyboard; the sheet rests at half height.
        field.typeText("\n")
        sleep(2)
        XCTAssertEqual(sheetPlace(), .half, "The sheet is not at half height before the drag.")
        XCTAssertTrue(headline.exists, "The no-match state is not on screen.")
        slowDrag(from: headline, by: 300)
        let place = sheetPlace()
        XCTAssertEqual(place, Self.placeAfterNoMatchesDragDown,
                       "A drag down on the no-match state left the sheet \(place.rawValue).")
    }

    // MARK: - Return on a search that is already listed

    /// Opens Search on the 23-page fixture and returns the field, which
    /// takes the focus as the sheet opens. Asks nothing of the software
    /// keyboard: these tests judge what Return starts, and a Return from
    /// any keyboard shows that.
    private func openSearch() -> XCUIElement {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()
        let search = app.buttons["searchRedact"]
        XCTAssertTrue(search.waitForExistence(timeout: 40), "Editor toolbar never appeared.")
        search.tap()
        let field = app.textFields["Search text"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Search field never appeared.")
        return field
    }

    /// The notice a run posts when it clears listed matches. It is on
    /// screen for a few seconds after such a run starts.
    private var rerunNotice: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: #"label CONTAINS "Search re-run""#)).firstMatch
    }

    /// The footer's "M of N selected" line.
    private var selectionLine: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: #"label ENDSWITH "selected""#)).firstMatch
    }

    /// Types a query that runs by itself and waits for its run to end.
    private func listResults(for query: String, in field: XCUIElement) {
        field.typeText(query)
        XCTAssertTrue(
            app.buttons["footerSelectAllButton"].waitForExistence(timeout: 15),
            "The typed query returned no results."
        )
        sleep(4)
    }

    func testReturn_onTheListedSearch_startsNoRunAndPostsNoNotice() {
        let field = openSearch()
        listResults(for: "Amo", in: field)
        let before = selectionLine.label
        field.typeText("\n")
        XCTAssertFalse(
            rerunNotice.waitForExistence(timeout: 4),
            "Return on the listed search started a run and posted its notice."
        )
        XCTAssertEqual(selectionLine.label, before, "The list changed after Return.")
    }

    func testReturn_onTheListedSearch_keepsTheSelection() {
        let field = openSearch()
        listResults(for: "Amo", in: field)
        // Return puts the keyboard away so the footer is in reach.
        field.typeText("\n")
        sleep(5)
        app.buttons["footerSelectAllButton"].tap()
        sleep(1)
        let selected = selectionLine.label
        XCTAssertFalse(selected.hasPrefix("0 of"), "Select All selected nothing: \(selected)")
        // Back into the field, and Return again.
        field.tap()
        field.typeText("\n")
        XCTAssertFalse(
            rerunNotice.waitForExistence(timeout: 4),
            "Return on the listed search started a run and posted its notice."
        )
        XCTAssertEqual(selectionLine.label, selected, "Return dropped the selection.")
    }

    func testReturn_onASearchStoppedAtTheResultCap_startsNoRun() {
        let field = openSearch()
        // One letter is below the as-you-type floor; Return runs it, and
        // on this fixture the run stops at the result cap.
        field.typeText("e\n")
        XCTAssertTrue(
            app.buttons["footerSelectAllButton"].waitForExistence(timeout: 20),
            "The one-letter query returned no results."
        )
        sleep(6)
        let cap = app.staticTexts.matching(NSPredicate(format: #"label BEGINSWITH "Showing first""#)).firstMatch
        XCTAssertTrue(cap.exists, "The run did not stop at the result cap, so this test judges nothing.")
        let before = selectionLine.label
        field.tap()
        field.typeText("\n")
        XCTAssertFalse(
            rerunNotice.waitForExistence(timeout: 4),
            "Return on a search listed up to the cap started a run and posted its notice."
        )
        XCTAssertEqual(selectionLine.label, before, "The list changed after Return.")
    }

    func testReturn_onAShortQuery_runsIt() {
        let field = openSearch()
        // Two letters are below the as-you-type floor: nothing runs.
        field.typeText("Am")
        XCTAssertFalse(
            app.buttons["footerSelectAllButton"].waitForExistence(timeout: 4),
            "A two-letter query ran without Return."
        )
        field.typeText("\n")
        XCTAssertTrue(
            app.buttons["footerSelectAllButton"].waitForExistence(timeout: 15),
            "Return did not run the two-letter query."
        )
        sleep(4)
        // A changed query under a finished run: Return runs it, and that
        // run posts the notice for the matches it clears.
        field.tap()
        field.typeText("o")
        sleep(5)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        sleep(1)
        XCTAssertEqual(field.value as? String, "Am", "The query was not edited back to two letters.")
        field.typeText("\n")
        XCTAssertTrue(
            rerunNotice.waitForExistence(timeout: 6),
            "Return on a changed query started no run."
        )
    }

    func testReturn_putsTheKeyboardAwayAndTheSheetStays() throws {
        let (field, keyboard, headerY) = try openSearchWithKeyboard()
        field.typeText("Amo\n")
        XCTAssertTrue(
            app.buttons["footerSelectAllButton"].waitForExistence(timeout: 15),
            "The typed query returned no results."
        )
        sleep(2)
        XCTAssertFalse(keyboardIsOnScreen(keyboard), "Return left the keyboard up.")
        XCTAssertEqual(
            app.buttons["searchDismissButton"].frame.minY, headerY, accuracy: 1,
            "The sheet moved when Return put the keyboard away."
        )
    }

    func testScrollingResults_putsTheKeyboardAwayAndTheSheetStays() throws {
        let (field, keyboard, headerY) = try openSearchWithKeyboard()
        field.typeText("Amo")
        XCTAssertTrue(
            app.buttons["footerSelectAllButton"].waitForExistence(timeout: 15),
            "The typed query returned no results."
        )
        sleep(2)
        XCTAssertTrue(keyboardIsOnScreen(keyboard), "The keyboard left before any scroll.")
        // A short upward drag that starts on the first result row.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: #"label == "Search match, page 1""#)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "First result row not found.")
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -60))
        start.press(forDuration: 0.1, thenDragTo: end)
        sleep(2)
        XCTAssertFalse(keyboardIsOnScreen(keyboard), "Scrolling the results left the keyboard up.")
        XCTAssertEqual(
            app.buttons["searchDismissButton"].frame.minY, headerY, accuracy: 1,
            "The sheet moved when a scroll put the keyboard away."
        )
    }

    func testTypingFirstResults_fieldKeepsFocusAndSheetHolds() throws {
        let (field, keyboard, restHeaderY) = try openSearchWithKeyboard()
        let dismiss = app.buttons["searchDismissButton"]
        let restKeyboardY = keyboard.frame.minY

        // Three letters start the as-you-type run by themselves.
        for (index, letter) in "Amo".enumerated() {
            field.typeText(String(letter))
            XCTAssertTrue(hasKeyboardFocus(field), "Focus lost after key \(index + 1).")
        }
        XCTAssertTrue(
            app.buttons["footerSelectAllButton"].waitForExistence(timeout: 15),
            "The typed query returned no results."
        )
        sleep(2)
        XCTAssertTrue(hasKeyboardFocus(field), "Focus lost when the first results arrived.")
        XCTAssertTrue(keyboard.exists, "Keyboard closed when the first results arrived.")
        XCTAssertEqual(
            keyboard.frame.minY, restKeyboardY, accuracy: 1,
            "Keyboard moved when the first results arrived."
        )
        XCTAssertEqual(
            dismiss.frame.minY, restHeaderY, accuracy: 1,
            "The sheet moved when the first results arrived."
        )

        // Typing goes on where it left off.
        field.typeText("unt")
        XCTAssertEqual(field.value as? String, "Amount", "The query was not continued.")

        // Emptying the field brings the empty state back; the focus
        // must survive that too.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
        sleep(2)
        XCTAssertTrue(hasKeyboardFocus(field), "Focus lost when the field was emptied.")
        XCTAssertEqual(
            dismiss.frame.minY, restHeaderY, accuracy: 1,
            "The sheet moved when the field was emptied."
        )

        // A run with no matches starts from the empty state and ends
        // in one.
        field.typeText("Zqx")
        XCTAssertTrue(
            app.staticTexts["No matches"].waitForExistence(timeout: 15),
            "The no-match state never appeared."
        )
        XCTAssertTrue(hasKeyboardFocus(field), "Focus lost on a run that found nothing.")
        XCTAssertEqual(
            dismiss.frame.minY, restHeaderY, accuracy: 1,
            "The sheet moved on a run that found nothing."
        )

        // And a run that starts from the no-match state.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        field.typeText("Amo")
        XCTAssertTrue(
            app.buttons["footerSelectAllButton"].waitForExistence(timeout: 15),
            "The second query returned no results."
        )
        sleep(2)
        XCTAssertTrue(hasKeyboardFocus(field), "Focus lost on a run after a no-match.")
        XCTAssertEqual(
            dismiss.frame.minY, restHeaderY, accuracy: 1,
            "The sheet moved on a run after a no-match."
        )
    }
}
