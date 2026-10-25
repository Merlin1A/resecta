import XCTest

// The text search's no-match state over a page read by text recognition:
// the bundled image (`--loadTestImage`, no text layer, so Search reads it
// by OCR) and a query it does not hold. The description names the page
// and the recourse, VoiceOver reads it as one element, and at AX5 it
// wraps inside the window. A text-layer document keeps today's copy.
nonisolated final class NoMatchOCRCopyUITests: XCTestCase {

    private var app: XCUIApplication!

    private static let query = "--searchQuery=Zqxvj"
    private static let qualified =
        "No matches in the text Resecta could read. 1 page was read by text recognition, and a misread word won't match. Check those pages by eye, or search a shorter part of the term."
    private static let unqualified =
        "No occurrences in the document for the active query. Try a broader term or change the search options."

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    private func description(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    /// The image import's notice lies over the sheet while it shows; the
    /// screenshots wait for it to go.
    private func awaitImportNoticeGone() {
        let notice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Image pages are read")).firstMatch
        XCTAssertTrue(notice.waitForNonExistence(timeout: 30), "The image import's notice never cleared off the sheet.")
    }

    func testScannedPageNoMatchNamesTheOCRPage() {
        app.launchArguments = ["--uitesting", "--loadTestImage", "--openSearchSheet", Self.query, "--searchDetent=large"]
        app.launch()
        let copy = description(Self.qualified)
        XCTAssertTrue(copy.waitForExistence(timeout: 60), "The no-match on the scanned page never read as qualified.")
        XCTAssertFalse(description(Self.unqualified).exists, "The unqualified no-match shows beside the qualified one.")
        // The OCR controls' caption no longer awaits once the run has completed.
        let caption = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No results from text recognition")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "The OCR caption still awaits after the completed run.")
        awaitImportNoticeGone()
        attachScreenshot(named: "no-match-ocr-page")
    }

    func testTextLayerNoMatchKeepsTodaysCopy() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--openSearchSheet", Self.query, "--searchDetent=large"]
        app.launch()
        XCTAssertTrue(description(Self.unqualified).waitForExistence(timeout: 30), "The text-layer no-match lost today's copy.")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "text recognition")).firstMatch.exists,
                       "A document with a text layer on every page names text recognition.")
        attachScreenshot(named: "no-match-text-layer")
    }

    func testScannedPageNoMatchWrapsAtAX5() {
        app.launchArguments = [
            "--uitesting", "--loadTestImage", "--openSearchSheet", Self.query, "--searchDetent=large",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        let copy = description(Self.qualified)
        XCTAssertTrue(copy.waitForExistence(timeout: 60), "The qualified no-match never showed at AX5.")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(copy.frame.minX, window.minX, "The description runs off the window's leading edge.")
        XCTAssertLessThanOrEqual(copy.frame.maxX, window.maxX, "The description runs off the window's trailing edge.")
        // Wrapped, not truncated: many lines tall at AX5.
        XCTAssertGreaterThan(copy.frame.height, 200, "The description is \(copy.frame.height) pt tall at AX5: it did not wrap.")
        awaitImportNoticeGone()
        attachScreenshot(named: "no-match-ocr-page-ax5")
    }
}
