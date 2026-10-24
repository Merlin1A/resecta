import XCTest

/// UI tests for the duplicate-name rejection on BOTH saved-search
/// collision paths.
///
/// Pre-fix, the collision handlers re-armed presentation from INSIDE the
/// alert's own button action, so the tap's dismissal swallowed the
/// re-present and both paths shipped silently dead: a duplicate-name Save
/// dropped the save (no rejection, no twin, no overwrite) and a
/// duplicate-name Rename kept the old name — each reading as success. The
/// fix decouples the re-present from the button action
/// (`SavedSearchListSheet`'s `.onChange` collision handlers); these tests
/// are the runtime pins that the rejection alert actually PRESENTS,
/// carrying the pinned copy, on each path — plus a success control per path
/// and the untouched-prefill leg (the zero-typing default that made the
/// save collision trivially reachable).
///
/// The suggested name is "Search – <date and time>" (the interface and
/// the date, never the query), so each test reads the name from the save
/// prompt and asserts against that. Two saves within the same minute get
/// the same name, which is the collision the untouched-prefill leg needs.
///
/// The saved-search store persists in the app container across XCUI
/// launches, so each test clears the list up front (leftover tolerance:
/// earlier runs' rows carry other dates) and deletes its rows on exit.
///
/// nonisolated for the same reason as `ShareRiskSheetUITests`: an
/// XCUITest drives a separate process and touches no @MainActor app state;
/// under the SE-0466 MainActor-default flip the lifecycle overrides would
/// otherwise mismatch XCTestCase's nonisolated ObjC lifecycle methods.
nonisolated final class SavedSearchCollisionUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Pinned rejection copy (`SavedSearchListSheet.duplicateNameMessage`).
    private let rejectionCopy = "That name is already in use — choose a different name."

    /// The suggested name's fixed part (`SavedSearchListSheet.generatedName`
    /// for a text search); the rest is the date and time.
    private let suggestedNamePrefix = "Search \u{2013} "

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// Save path, strongest form: save twice typing NOTHING — the auto-name
    /// prefill makes the second save collide by default. The rejection
    /// alert must present with the pinned copy; the first save is the
    /// success control; no twin row may appear.
    func testSaveCollision_untouchedPrefill_presentsRejectionAlert() {
        launchSearchSheetWithResults(query: "Sample")
        openSavedList()
        clearSavedList()

        // Both saves must fall in one minute for the suggested names to
        // match: start the first one clear of a minute boundary.
        waitUntilClearOfMinuteBoundary()
        let name = saveCurrentSearch()
        XCTAssertTrue(
            app.staticTexts[name].waitForExistence(timeout: 10),
            "First save did not create the row — success control failed."
        )

        // Repeat save, prefill untouched → identical name.
        let saveRow = app.buttons["Save current search…"]
        XCTAssertTrue(saveRow.waitForExistence(timeout: 5))
        saveRow.tap()
        let alert = app.alerts["Save current search"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertEqual(
            alert.textFields.firstMatch.value as? String, name,
            "Auto-name prefill must be intact on a same-minute repeat save."
        )
        alert.buttons["Save"].tap()

        XCTAssertTrue(
            app.alerts.staticTexts[rejectionCopy].waitForExistence(timeout: 10),
            "Duplicate-name rejection alert never presented on the save path."
        )
        app.alerts.buttons["Cancel"].tap()

        // The rejected save must not have appended a twin.
        XCTAssertEqual(
            app.cells.containing(.staticText, identifier: name).count, 1,
            "The rejected save appended a twin row."
        )
        deleteRows(named: [name])
    }

    /// Rename path: renaming one row to another row's
    /// exact name must present the rejection alert; the row keeps its old
    /// name; a non-colliding rename still commits (success control). The
    /// second row is created by editing the name in the save prompt itself
    /// (alert fields hold keyboard focus reliably; the underlying search
    /// field does not, mid-sheet-transition), which also covers the
    /// edited-name save-success leg.
    func testRenameCollision_presentsRejectionAlert_rowKeepsName() {
        launchSearchSheetWithResults(query: "Sample")
        openSavedList()
        clearSavedList()

        let name = saveCurrentSearch()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10))

        // Second row, same shape, name typed over the prefill in the alert.
        saveCurrentSearch(typingOver: "Rename Me")
        XCTAssertTrue(
            app.staticTexts["Rename Me"].waitForExistence(timeout: 10),
            "Edited-name save did not create the second row."
        )

        renameRow(named: "Rename Me", to: name)
        XCTAssertTrue(
            app.alerts.staticTexts[rejectionCopy].waitForExistence(timeout: 10),
            "Duplicate-name rejection alert never presented on the rename path."
        )
        app.alerts.buttons["Cancel"].tap()

        // Silent-discard guard: the row keeps its old name and no twin exists.
        XCTAssertTrue(
            app.staticTexts["Rename Me"].waitForExistence(timeout: 5),
            "Row lost its name after a rejected rename."
        )
        XCTAssertEqual(
            app.cells.containing(.staticText, identifier: name).count, 1,
            "The rejected rename produced a twin row."
        )

        renameRow(named: "Rename Me", to: "Control OK")
        XCTAssertTrue(
            app.staticTexts["Control OK"].waitForExistence(timeout: 10),
            "Non-colliding rename failed to commit — the fix over-rotated."
        )
        deleteRows(named: [name, "Control OK"])
    }

    /// Delete All path: with at least one row saved, the list's
    /// destructive "Delete All Saved Searches" row is present; its
    /// confirm dialog carries the pinned title and the "Delete All"
    /// role; committing clears the Search-side list to its empty state
    /// and the row hides itself (it is shown only while rows exist).
    func testDeleteAll_clearsListToEmptyState() {
        launchSearchSheetWithResults(query: "Sample")
        openSavedList()

        let name = saveCurrentSearch()
        XCTAssertTrue(
            app.staticTexts[name].waitForExistence(timeout: 10),
            "Save did not create the row — success control failed."
        )

        let clearAllRow = app.buttons["savedSearchClearAllButton"]
        XCTAssertTrue(
            clearAllRow.waitForExistence(timeout: 5),
            "Delete All row absent while the list has rows."
        )
        clearAllRow.tap()

        XCTAssertTrue(
            app.staticTexts["Delete all saved searches?"].waitForExistence(timeout: 5),
            "Delete All confirm dialog never presented."
        )
        // The dialog's destructive action resolves to more than one
        // matching element in the accessibility tree (the action sheet
        // mirrors it), so take the first by identifier.
        let confirm = app.buttons["savedSearchClearAllConfirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete All confirm button not found.")
        confirm.tap()

        XCTAssertTrue(
            app.staticTexts["No Saved Searches"].waitForExistence(timeout: 10),
            "Empty state never appeared after Delete All."
        )
        XCTAssertFalse(
            app.staticTexts[name].exists,
            "The saved row survived Delete All."
        )
        XCTAssertTrue(
            waitForAbsence(of: clearAllRow, timeout: 5),
            "Delete All row still present on the empty list."
        )
    }

    // MARK: - Launch + navigation helpers

    /// Launch straight into the search sheet over the bundled single-page
    /// test document and run a text query that yields results.
    private func launchSearchSheetWithResults(query: String) {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--openSearchSheet"]
        app.launch()

        let field = app.textFields["Search text"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 30),
            "Search sheet never presented — check the --openSearchSheet launch hook."
        )
        field.tap()
        field.typeText(query)
        XCTAssertTrue(
            app.staticTexts["Page 1"].waitForExistence(timeout: 15),
            "Text search returned no results for the bundled fixture."
        )
    }

    /// Open the saved-searches list via the search bar's bookmark control.
    private func openSavedList() {
        let bookmark = app.buttons["Saved Searches"].firstMatch
        XCTAssertTrue(
            bookmark.waitForExistence(timeout: 10),
            "Saved Searches bookmark control not found."
        )
        bookmark.tap()
        XCTAssertTrue(
            app.buttons["Save current search…"].waitForExistence(timeout: 10),
            "Saved list sheet never presented."
        )
    }

    // MARK: - Row action helpers

    /// Commit "Save current search…" and return the saved name. The
    /// suggested-name prefill is asserted first (the zero-typing default
    /// is the collision surface); when `typingOver` is given, the prefill
    /// is replaced in the alert field before committing.
    @discardableResult
    private func saveCurrentSearch(typingOver newName: String? = nil) -> String {
        let saveRow = app.buttons["Save current search…"]
        XCTAssertTrue(saveRow.waitForExistence(timeout: 10))
        saveRow.tap()
        let alert = app.alerts["Save current search"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Save prompt never presented.")
        let prefill = alert.textFields.firstMatch.value as? String ?? ""
        XCTAssertTrue(
            prefill.hasPrefix(suggestedNamePrefix),
            "Suggested-name prefill mismatch: \(prefill)"
        )
        if let newName {
            replaceText(in: alert.textFields.firstMatch,
                        clearing: prefill, with: newName)
        }
        alert.buttons["Save"].tap()
        return newName ?? prefill
    }

    /// The suggested name carries the time to the minute: wait out the
    /// last 20 seconds of a minute so two saves a few seconds apart get
    /// the same name.
    private func waitUntilClearOfMinuteBoundary() {
        let second = Calendar.current.component(.second, from: Date())
        if second >= 40 { sleep(UInt32(61 - second)) }
    }

    /// Empty the saved list through its Delete All row when it has rows
    /// (leftover tolerance: earlier runs' rows carry other dates).
    private func clearSavedList() {
        let clearAllRow = app.buttons["savedSearchClearAllButton"]
        guard clearAllRow.waitForExistence(timeout: 2) else { return }
        clearAllRow.tap()
        let confirm = app.buttons["savedSearchClearAllConfirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete All confirm button not found.")
        confirm.tap()
        XCTAssertTrue(
            app.staticTexts["No Saved Searches"].waitForExistence(timeout: 10),
            "The list did not empty before the test."
        )
    }

    /// Clear an alert text field and type a replacement, reading the value
    /// back (typed names are commit-critical). Alert fields take keyboard
    /// focus on presentation; the tap re-asserts it, at the field's trailing
    /// edge so the cursor sits after the text (a centre tap lands inside a
    /// long suggested name and the deletes leave its tail).
    private func replaceText(
        in field: XCUIElement, clearing current: String, with newText: String
    ) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                              count: current.count + 8))
        field.typeText(newText)
        XCTAssertEqual(field.value as? String, newText,
                       "Alert field retype did not land.")
    }

    /// Leading-swipe the named row, open Rename, replace the prefilled
    /// name, and commit. The commit may present the rejection alert —
    /// callers assert.
    private func renameRow(named name: String, to newName: String) {
        let cell = app.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "Row \(name) not found.")
        cell.swipeRight()
        let renameAction = app.buttons["Rename saved search \(name)"]
        XCTAssertTrue(
            renameAction.waitForExistence(timeout: 5),
            "Leading-swipe Rename action not revealed."
        )
        renameAction.tap()
        let alert = app.alerts["Rename \u{201C}\(name)\u{201D}"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Rename prompt never presented.")
        replaceText(in: alert.textFields.firstMatch, clearing: name, with: newName)
        alert.buttons["Rename"].tap()
    }

    /// Delete every listed row that exists (leftover tolerance — the store
    /// persists across launches). The confirm dialog's destructive button
    /// is the only bare "Delete" in the tree (the swipe action carries a
    /// custom label), so the query is unambiguous.
    private func deleteRows(named names: [String]) {
        for name in names {
            let cell = app.cells.containing(.staticText, identifier: name).firstMatch
            guard cell.waitForExistence(timeout: 2) else { continue }
            cell.swipeLeft()
            let deleteAction = app.buttons["Delete saved search \(name)"]
            XCTAssertTrue(
                deleteAction.waitForExistence(timeout: 5),
                "Trailing-swipe Delete action not revealed for \(name)."
            )
            deleteAction.tap()
            let confirm = app.buttons["Delete"]
            XCTAssertTrue(
                confirm.waitForExistence(timeout: 5),
                "Delete confirm dialog never presented for \(name)."
            )
            confirm.tap()
            XCTAssertTrue(
                waitForAbsence(of: cell, timeout: 5),
                "Row \(name) still present after delete."
            )
        }
    }

    private func waitForAbsence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
