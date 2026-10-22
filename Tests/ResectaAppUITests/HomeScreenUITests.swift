import XCTest

/// The home screen as VoiceOver and a finger meet it: every entry speaks
/// its title and description under its identifier, the gear has its own
/// identifier, the trust words are one line, and at the largest
/// accessibility size the first entry is whole on the first screen with
/// no scroll. Black-box XCUITest, no `@testable import`.
///
/// nonisolated for the same reason as the sibling suites: an XCUITest
/// drives a separate process and touches no @MainActor app state.
nonisolated final class HomeScreenUITests: XCTestCase {

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

    /// Each entry's identifier resolves to a button whose label is the copy
    /// of record's title and description; the gear has its identifier; the
    /// trust words read as one static text.
    func testHomeEntriesSpeakTheirLabels() {
        app.launchArguments = ["--uitesting"]
        app.launch()

        let expected: [(id: String, label: String)] = [
            ("homeOpenDocument", "Open a Document, Import a PDF or an image from Files. Nothing is uploaded."),
            ("homeImportPhotos", "Import Photos, Choose up to 20 photos, one page each. Nothing is uploaded."),
            ("homeTrySample", "Try the Sample, A bundled 3-page bank statement."),
        ]
        for entry in expected {
            let button = app.buttons[entry.id]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "\(entry.id) is on Home")
            XCTAssertEqual(button.label, entry.label, "\(entry.id) speaks the copy of record")
        }
        XCTAssertTrue(app.buttons["homeSettingsButton"].exists, "the gear has its identifier")
        XCTAssertTrue(app.staticTexts["On-device, No tracking, Open source"].exists,
                      "the trust words are one spoken line")
    }

    /// At the largest accessibility size the first entry is hittable with
    /// no scroll: a door on the first screen.
    func testOpenDocumentOnFirstScreenAtAX5() {
        app.launchArguments = ["--uitesting",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        let open = app.buttons["homeOpenDocument"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "the first entry exists")
        XCTAssertTrue(open.isHittable, "the first entry is whole on the first screen at the largest size")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(open.frame.maxY, window.maxY, "the first entry ends above the screen's bottom")
    }
}
