import XCTest

/// The editor's sheet slot presents a Search session only while editing,
/// importing or failed. A session set while the results screen is up is
/// not presented there, and it is not left behind to rise when the
/// editor comes back.
///
/// The two launch hooks together set a Search session after the seeded
/// results screen is reached: the seed moves the phase to the results
/// first, then the Search hook sets the session.
///
/// nonisolated because an XCUITest drives a separate process and touches no
/// @MainActor app state (see `ShareRiskSheetUITests`).
nonisolated final class SheetSlotPhaseUITests: XCTestCase {

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

    /// Whether the element stays absent for the whole of `seconds`.
    private func staysAbsent(_ element: XCUIElement, for seconds: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: seconds) == .timedOut
    }

    func testSearchSetOnTheResultsScreenIsNotPresentedAndDoesNotReturn() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--seedVerifiedReport=secureAllPass", "--openSearchSheet",
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["verificationMasthead"].waitForExistence(timeout: 40),
                      "The seeded results screen never appeared.")
        XCTAssertTrue(staysAbsent(app.buttons["searchDismissButton"], for: 5),
                      "Search was presented over the results screen.")
        XCTAssertFalse(app.buttons["applyCurrentResultButton"].exists,
                       "Search's compact strip was presented over the results screen.")

        let keepEditing = app.buttons["keepEditingAction"]
        XCTAssertTrue(keepEditing.waitForExistence(timeout: 10), "Keep Editing never appeared.")
        keepEditing.tap()

        let search = app.buttons["searchRedact"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "The editor's Search button never appeared.")
        XCTAssertTrue(search.isEnabled, "The editor's Search button is not enabled after Keep Editing.")
        XCTAssertTrue(staysAbsent(app.buttons["searchDismissButton"], for: 3),
                      "A Search session left behind on the results screen rose in the editor.")
    }
}
