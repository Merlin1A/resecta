import XCTest

/// One case per DEBUG launch hook form and per fixture: each launch reaches
/// its screen, and the case looks up that screen's element by its
/// accessibility identifier, never by its words. The hooks and their
/// parsers are in `ResectaApp.swift` and `ContentView.swift`; the fixtures
/// come from `Scripts/generate_uitest_locked.py` and
/// `Scripts/generate_uitest_annotated_form.py`.
/// nonisolated for the same reason as the sibling suites: an XCUITest
/// drives a separate process and touches no @MainActor app state.
nonisolated final class DebugHookSmokeUITests: XCTestCase {

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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func launch(_ arguments: [String]) {
        app.launchArguments = ["--uitesting"] + arguments
        app.launch()
    }

    private func assertToastShows(_ hook: String) {
        launch(["--loadTestDocument", hook])
        XCTAssertTrue(element("toast").waitForExistence(timeout: 30),
                      "No toast came up for \(hook).")
    }

    func testShowToastShareSheetUnavailable() {
        assertToastShows("--showToast=shareSheetUnavailable")
    }

    func testShowToastSelectionLimit() {
        assertToastShows("--showToast=selectionLimit")
    }

    func testShowToastCustomTermTimeout() {
        assertToastShows("--showToast=customTermTimeout")
    }

    func testBareShowToastKeepsPurgeWarning() {
        assertToastShows("--showToast")
    }

    func testSeedFailureShowsFailedState() {
        launch(["--seedFailure=redactionError.renderTimeout:editing"])
        XCTAssertTrue(element("failedState").waitForExistence(timeout: 30),
                      "The failure screen never came up for the seeded render timeout.")
        let primary = element("failedStatePrimaryButton")
        XCTAssertTrue(primary.waitForExistence(timeout: 5), "The failure screen has no primary button.")
        XCTAssertEqual(primary.label, "Return to Editor",
                       "A recoverable failure from the editor offers the way back to it.")
    }

    func testForceDetectionDegradeShowsBanner() {
        launch(["--loadTestDocument", "--forceDetectionDegrade", "--openSearchSheet", "--searchMode=piiScan"])
        XCTAssertTrue(element("degradedDetectionBanner").waitForExistence(timeout: 30),
                      "The Scan banner for a failed name model never came up.")
    }

    func testOCRSkipPageShowsBanner() {
        launch(["--loadTestDocument", "--uitestOCRSkipPage=0", "--openSearchSheet", "--searchQuery=Sample"])
        XCTAssertTrue(element("ocrSkipBanner").waitForExistence(timeout: 60),
                      "The skipped-pages banner never came up after the search.")
    }

    func testForceSnapshotOverlayShowsPlaceholder() {
        launch(["--forceSnapshotOverlay"])
        XCTAssertTrue(element("snapshotPrivacyOverlay").waitForExistence(timeout: 30),
                      "The app-switcher placeholder was not held up.")
    }

    func testLockedDocShowsPasswordSheet() {
        launch(["--lockedDoc"])
        XCTAssertTrue(element("importPasswordSheet").waitForExistence(timeout: 30),
                      "The locked fixture did not bring up the password sheet.")
    }

    func testAnnotatedFormDocShowsNotice() {
        launch(["--loadTestDocument", "--annotatedFormDoc"])
        XCTAssertTrue(element("importAnnotationNotice").waitForExistence(timeout: 30),
                      "The annotated form fixture did not bring up the import notice.")
    }
}
