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
        XCTAssertTrue(element("finding_formValuesNotCarried").waitForExistence(timeout: 10),
                      "The form values row never appeared.")
        assertShareAsksFirst()
    }

    func testCoveredTextShowsItsRowAndShareAsksFirst() {
        launchResults(["--seedOutput", "--seedCoveredText"])
        XCTAssertTrue(element("finding_coveredTextInOriginal").waitForExistence(timeout: 10),
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

    func testBurnedBoxesShowTheirLine() {
        launchResults(["--seedBurnedBoxes=19"])
        let line = text(beginningWith: "19 boxes can still show")
        XCTAssertTrue(line.waitForExistence(timeout: 10), "The boxes line never appeared.")
        XCTAssertEqual(line.label, "19 boxes can still show how long their text is.")
    }

    func testOutputSizeShowsWithTheOutput() {
        launchResults(["--seedOutput", "--seedOutputBytes=38200000"])
        let line = text(beginningWith: "This PDF is ")
        XCTAssertTrue(line.waitForExistence(timeout: 10), "The size line never appeared.")
        XCTAssertEqual(line.label, "This PDF is 38.2 MB.")
    }

    func testOutputSizeIsGoneWithTheOutput() {
        launchResults(["--seedOutputBytes=38200000"])
        XCTAssertTrue(shareCard.waitForExistence(timeout: 10), "Share card not found.")
        XCTAssertFalse(text(beginningWith: "This PDF is ").exists, "The size line shows with no output.")
    }

    func testLongImageOnlyShowsItsLine() {
        launchResults(["--seedOutput", "--seedSecurePages=140"])
        let line = text(beginningWith: "This PDF has 140 pages and no text")
        XCTAssertTrue(line.waitForExistence(timeout: 10), "The long image-only line never appeared.")
        XCTAssertEqual(line.label, Self.longImageOnly)
    }

    func testLongImageOnlyIsGoneAtEightyPages() {
        launchResults(["--seedOutput", "--seedSecurePages=80"])
        XCTAssertTrue(shareCard.waitForExistence(timeout: 10), "Share card not found.")
        XCTAssertFalse(text(beginningWith: "This PDF has ").exists, "The long image-only line shows at 80 pages.")
    }

    func testUnreadPagesShowTheirLines() {
        launchResults(["--seedSecurePages=48", "--seedUnread=12/38"])
        let named = text(beginningWith: "Before Redact, ")
        XCTAssertTrue(named.waitForExistence(timeout: 10), "The not-searched line never appeared.")
        XCTAssertEqual(named.label, "Before Redact, 12 pages were not searched in full.")
        XCTAssertEqual(text(beginningWith: "Small pictures on ").label,
                       "Small pictures on 38 pages, such as logos and stamps, were not searched. A name inside a logo or stamp is not found.")
        XCTAssertEqual(text(beginningWith: "The checks then ran on ").label,
                       "The checks then ran on all 48 pages, looking for your boxed text.")
    }

    func testScopeNoteShowsWithTheOutput() {
        launchResults(["--seedOutput"])
        let note = element("checksPassedScope")
        XCTAssertTrue(note.waitForExistence(timeout: 10), "The note beside Checks Passed never appeared.")
        XCTAssertEqual(note.label, Self.checksPassedScope)
    }

    func testScopeNoteIsGoneWithTheOutput() {
        launchResults([])
        XCTAssertTrue(shareCard.waitForExistence(timeout: 10), "Share card not found.")
        XCTAssertFalse(element("checksPassedScope").exists, "The note beside Checks Passed shows with no output.")
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
        for start in ["boxes can still show how long their text is.", "box can still show how long its text is.",
                      "This PDF is ", "This PDF has ",
                      "Before Redact, ", "Small pictures on ", "The checks then ran on "] {
            XCTAssertFalse(text(containing: start).exists, "A run line with \"\(start)\" shows with no seed.")
        }
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

    /// On a failed run the failed check's row still says it failed, in
    /// its main line, whatever colour Share is drawn in.
    func testFailedFindingStillSaysFailed() {
        app.launchArguments = ["--uitesting", "--seedVerifiedReport=secureFail", "--seedOutput"]
        app.launch()
        XCTAssertTrue(element("verificationResults").waitForExistence(timeout: 30),
                      "The seeded results screen never appeared.")
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'finding_'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "No findings row appeared.")
        let saysFailed = "label CONTAINS ': failed'"
        let inRow = rows.descendants(matching: .any).matching(NSPredicate(format: saysFailed)).firstMatch
        XCTAssertTrue(inRow.waitForExistence(timeout: 5) || rows.matching(NSPredicate(format: saysFailed)).firstMatch.exists,
                      "The failed check's row does not say it failed.")
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

    /// The line beside Checks Passed, as the results screen shows it.
    private static let checksPassedScope =
        "Checks Passed means no check reported your boxed text in this PDF. In this version the checks do not show that they read every part of the file. What remains can still identify someone."

    private static let longImageOnly =
        "This PDF has 140 pages and no text, so an AI assistant that reads only the text of a PDF this long will read nothing of it."

    private func text(beginningWith start: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", start)).firstMatch
    }

    private func text(containing part: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
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
