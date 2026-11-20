import XCTest

/// The debug seeds of the results screen (`DebugSeedOptions`), one launch
/// each beside `--seedVerifiedReport=secureAllPass`: every seed shows the
/// state it names, and a launch with none of them is the hook's own.
///
/// Black-box: the expected sentences are compared by their first sentence
/// only, because the second carries no-break spaces.
///
/// nonisolated because an XCUITest drives a separate process and touches
/// no @MainActor app state (SE-0466; see `ShareRiskSheetUITests`).
nonisolated final class SeededStatesUITests: XCTestCase {

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

    private static let report = "--seedVerifiedReport=secureAllPass"

    // MARK: - Each seed

    func testHandBoxesShowTheirRow() {
        launchResults(["--seedHandBoxes=2"])
        XCTAssertTrue(element("resultsFinding_handRegions").waitForExistence(timeout: 10),
                      "The hand-drawn boxes row never appeared.")
    }

    func testFormValuesShowTheirRowAndShareAsksFirst() {
        launchResults(["--seedOutput", "--seedFormValues=2"])
        XCTAssertTrue(element("resultsFinding_formValues").waitForExistence(timeout: 10),
                      "The form values row never appeared.")
        assertShareAsksFirst()
    }

    func testCoveredTextShowsItsRowAndShareAsksFirst() {
        launchResults(["--seedOutput", "--seedCoveredText"])
        XCTAssertTrue(element("resultsFinding_coveredText").waitForExistence(timeout: 10),
                      "The covered text row never appeared.")
        assertShareAsksFirst()
    }

    func testItemsLeftShowTheDeselectionRow() {
        launchResults(["--seedLeft=2/5"])
        let row = element("deselectionRow")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The deselection row never appeared.")
        XCTAssertEqual(row.label, "You left 2 of 5 detected items unredacted.")
    }

    func testBoxesChangedWithTheOutputSaysRegionsChanged() {
        launchResults(["--seedOutput", "--seedBoxesChanged"])
        assertShareDisabled(firstSentence: "Regions changed after this PDF was made.")
        XCTAssertTrue(previewRow.waitForExistence(timeout: 5), "The Preview row is missing with the output present.")
    }

    func testBoxesChangedWithoutTheOutputSaysThePDFIsGone() {
        launchResults(["--seedBoxesChanged"])
        assertShareDisabled(firstSentence: "The redacted PDF is no longer available.")
        XCTAssertFalse(previewRow.exists, "The Preview row shows with no output.")
    }

    func testVerifyingStopsOnTheProgressScreen() {
        app.launchArguments = ["--uitesting", Self.report, "--seedVerifying=2"]
        app.launch()
        XCTAssertTrue(element("verificationProgress").waitForExistence(timeout: 30),
                      "The checks' progress screen never appeared.")
        XCTAssertFalse(element("verificationResults").waitForExistence(timeout: 2),
                       "The results appeared; the seeded run should stay at its checks.")
    }

    // MARK: - No seed

    func testNoSeedIsToday() {
        launchResults(["--seedOutput"])
        for identifier in ["resultsFinding_handRegions", "resultsFinding_formValues",
                           "resultsFinding_coveredText", "deselectionRow"] {
            XCTAssertFalse(element(identifier).exists, "\(identifier) shows with no seed.")
        }
        XCTAssertTrue(shareCard.waitForExistence(timeout: 10), "Share card not found.")
        XCTAssertTrue(shareCard.isEnabled, "Share is disabled with no seed.")
        XCTAssertFalse(element("shareDisabledReason").exists, "A disabled-Share reason shows with no seed.")
    }

    /// A seed without a report seeds nothing: the editor, not the results.
    func testASeedWithoutAReportLeavesTheEditor() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--seedFormValues=2"]
        app.launch()
        XCTAssertTrue(app.buttons["redactButton"].waitForExistence(timeout: 30), "The editor never appeared.")
        XCTAssertFalse(element("verificationResults").waitForExistence(timeout: 2),
                       "The results appeared with no report.")
        XCTAssertFalse(element("importAnnotationNotice").exists,
                       "The seeded form values reached the editor with no report.")
    }

    // MARK: - Helpers

    private func launchResults(_ seeds: [String]) {
        app.launchArguments = ["--uitesting", Self.report] + seeds
        app.launch()
        XCTAssertTrue(element("verificationResults").waitForExistence(timeout: 30),
                      "The seeded results screen never appeared.")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var shareCard: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Share Document'")).firstMatch
    }

    private var previewRow: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Preview Redacted Document'")).firstMatch
    }

    private func assertShareAsksFirst() {
        XCTAssertTrue(shareCard.waitForExistence(timeout: 10), "Share card not found.")
        shareCard.tap()
        XCTAssertTrue(app.buttons["shareRiskConfirmGoBack"].waitForExistence(timeout: 10),
                      "Share did not ask first.")
    }

    private func assertShareDisabled(firstSentence: String) {
        XCTAssertTrue(shareCard.waitForExistence(timeout: 10), "Share card not found.")
        XCTAssertFalse(shareCard.isEnabled, "Share is enabled.")
        let reason = element("shareDisabledReason")
        XCTAssertTrue(reason.waitForExistence(timeout: 5), "No disabled-Share reason.")
        XCTAssertTrue(reason.label.hasPrefix(firstSentence),
                      "The reason reads \"\(reason.label)\", not \"\(firstSentence) …\".")
    }
}
