import XCTest

/// UI tests for the H-74 duplicate-name rejection on BOTH saved-search
/// collision paths (RW-F-005, ruled D-86).
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
/// The saved-search store persists in the app container across XCUI
/// launches, so each test deletes its rows up front (leftover tolerance)
/// and again on exit.
///
/// nonisolated for the same reason as `DetectionTriageDismissUITests`: an
/// XCUITest drives a separate process and touches no @MainActor app state;
/// under the SE-0466 MainActor-default flip the lifecycle overrides would
/// otherwise mismatch XCTestCase's nonisolated ObjC lifecycle methods.
nonisolated final class SavedSearchCollisionUITests: XCTestCase {

    private var app: XCUIApplication!

    /// H-74 pinned rejection copy (`SavedSearchListSheet.duplicateNameMessage`).
    private let rejectionCopy = "That name is already in use — choose a different name."

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
        deleteRows(named: ["Text: Sample"])

        saveCurrentSearch(expectingPrefill: "Text: Sample")
        XCTAssertTrue(
            app.staticTexts["Text: Sample"].waitForExistence(timeout: 10),
            "First save did not create the row — success control failed."
        )

        // Repeat save, prefill untouched → identical name.
        let saveRow = app.buttons["Save current search…"]
        XCTAssertTrue(saveRow.waitForExistence(timeout: 5))
        saveRow.tap()
        let alert = app.alerts["Save current search"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertEqual(
            alert.textFields.firstMatch.value as? String, "Text: Sample",
            "Auto-name prefill must be intact on the repeat save."
        )
        alert.buttons["Save"].tap()

        XCTAssertTrue(
            app.alerts.staticTexts[rejectionCopy].waitForExistence(timeout: 10),
            "Duplicate-name rejection alert never presented on the save path (RW-F-005)."
        )
        app.alerts.buttons["Cancel"].tap()

        // The rejected save must not have appended a twin.
        XCTAssertEqual(
            app.cells.containing(.staticText, identifier: "Text: Sample").count, 1,
            "The rejected save appended a twin row."
        )
        deleteRows(named: ["Text: Sample"])
    }

    /// Rename path (the W4 extension): renaming one row to another row's
    /// exact name must present the rejection alert; the row keeps its old
    /// name; a non-colliding rename still commits (success control). The
    /// second row is created by editing the name in the save prompt itself
    /// (alert fields hold keyboard focus reliably; the underlying search
    /// field does not, mid-sheet-transition), which also covers the
    /// edited-name save-success leg.
    func testRenameCollision_presentsRejectionAlert_rowKeepsName() {
        launchSearchSheetWithResults(query: "Sample")
        openSavedList()
        deleteRows(named: ["Text: Sample", "Rename Me", "Control OK"])

        saveCurrentSearch(expectingPrefill: "Text: Sample")
        XCTAssertTrue(app.staticTexts["Text: Sample"].waitForExistence(timeout: 10))

        // Second row, same shape, name typed over the prefill in the alert.
        saveCurrentSearch(expectingPrefill: "Text: Sample", typingOver: "Rename Me")
        XCTAssertTrue(
            app.staticTexts["Rename Me"].waitForExistence(timeout: 10),
            "Edited-name save did not create the second row."
        )

        renameRow(named: "Rename Me", to: "Text: Sample")
        XCTAssertTrue(
            app.alerts.staticTexts[rejectionCopy].waitForExistence(timeout: 10),
            "Duplicate-name rejection alert never presented on the rename path (RW-F-005 W4 extension)."
        )
        app.alerts.buttons["Cancel"].tap()

        // Silent-discard guard: the row keeps its old name and no twin exists.
        XCTAssertTrue(
            app.staticTexts["Rename Me"].waitForExistence(timeout: 5),
            "Row lost its name after a rejected rename."
        )
        XCTAssertEqual(
            app.cells.containing(.staticText, identifier: "Text: Sample").count, 1,
            "The rejected rename produced a twin row."
        )

        renameRow(named: "Rename Me", to: "Control OK")
        XCTAssertTrue(
            app.staticTexts["Control OK"].waitForExistence(timeout: 10),
            "Non-colliding rename failed to commit — the fix over-rotated."
        )
        deleteRows(named: ["Text: Sample", "Control OK"])
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

    /// Commit "Save current search…". The auto-name prefill is asserted
    /// first (the zero-typing default is the collision surface); when
    /// `typingOver` is given, the prefill is replaced in the alert field
    /// before committing.
    private func saveCurrentSearch(
        expectingPrefill prefill: String, typingOver newName: String? = nil
    ) {
        let saveRow = app.buttons["Save current search…"]
        XCTAssertTrue(saveRow.waitForExistence(timeout: 10))
        saveRow.tap()
        let alert = app.alerts["Save current search"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Save prompt never presented.")
        XCTAssertEqual(
            alert.textFields.firstMatch.value as? String, prefill,
            "Auto-name prefill mismatch."
        )
        if let newName {
            replaceText(in: alert.textFields.firstMatch,
                        clearing: prefill, with: newName)
        }
        alert.buttons["Save"].tap()
    }

    /// Clear an alert text field and type a replacement, reading the value
    /// back (typed names are commit-critical). Alert fields take keyboard
    /// focus on presentation; the tap re-asserts it.
    private func replaceText(
        in field: XCUIElement, clearing current: String, with newText: String
    ) {
        field.tap()
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
