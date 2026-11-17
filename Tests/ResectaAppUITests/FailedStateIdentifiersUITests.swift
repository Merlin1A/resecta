import XCTest

/// The failure screen's identifier names the screen, and its words and each
/// of its buttons answer to their own. Reached through the DEBUG failure seed.
/// nonisolated for the same reason as the sibling suites: an XCUITest
/// drives a separate process and touches no @MainActor app state.
nonisolated final class FailedStateIdentifiersUITests: XCTestCase {

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

    private func launch(seed: String) {
        app.launchArguments = ["--uitesting", "--seedFailure=\(seed)"]
        app.launch()
    }

    private func any(_ identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    func testFailedScreen_eachControlAnswersToItsOwnIdentifier() {
        launch(seed: "exportError.filePurged:editing")
        let primary = app.buttons["failedStatePrimaryButton"]
        XCTAssertTrue(primary.waitForExistence(timeout: 30), "The failure screen never came up.")
        let startOver = app.buttons["failedStateStartOverButton"]
        let report = app.buttons["failedStateReportButton"]
        XCTAssertTrue(startOver.exists)
        XCTAssertTrue(report.exists)
        XCTAssertEqual(primary.label, "Return to Editor")
        XCTAssertEqual(startOver.label, "Start Over")
        XCTAssertEqual(report.label, "Report an Issue")
        XCTAssertNotEqual(primary.frame, startOver.frame)
        XCTAssertNotEqual(primary.frame, report.frame)
        XCTAssertNotEqual(startOver.frame, report.frame)
        XCTAssertEqual(app.buttons.matching(identifier: "failedState").count, 0,
                       "No button answers to the screen's identifier.")
        XCTAssertTrue(any("failedStateMessage").firstMatch.exists, "The words have their own identifier.")
        XCTAssertEqual(any("failedState").count, 1, "One element answers to the screen's identifier.")
    }

    func testFailedScreen_fromTheStartScreen_hasNoStartOver() {
        launch(seed: "importError.corrupt:empty")
        let primary = app.buttons["failedStatePrimaryButton"]
        XCTAssertTrue(primary.waitForExistence(timeout: 30), "The failure screen never came up.")
        XCTAssertEqual(primary.label, "Choose Another File")
        XCTAssertFalse(app.buttons["failedStateStartOverButton"].exists)
        XCTAssertTrue(app.buttons["failedStateReportButton"].exists)
        XCTAssertTrue(any("failedStateMessage").firstMatch.exists)
        XCTAssertEqual(any("failedState").count, 1)
    }
}
