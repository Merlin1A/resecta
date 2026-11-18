import XCTest

/// The screen while the checks run, on a real run: the bundled 23-page
/// fixture (`--multipageDoc`), one drawn box, Redact. The screen is one
/// ring, a title and a line; no row of a check shows while it runs; Stop
/// stays in the bar; the ring sits where the results' ring will; the trust
/// line never lies over the block at the largest text size.
///
/// A run that ends before the assertions (a fast simulator) skips with
/// its reason; it never passes silently.
///
/// nonisolated for the same reason as `SearchRecheckUITests`: an XCUITest
/// drives a separate process and touches no @MainActor app state.
nonisolated final class VerificationRunningUITests: XCTestCase {

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

    /// Launches, draws one box over the first page and taps Redact; returns
    /// once the running screen is up, or skips if the checks were over first.
    private func startRun(extraArguments: [String] = []) throws {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"] + extraArguments
        app.launch()
        let drawTool = app.buttons["drawTool"]
        XCTAssertTrue(drawTool.waitForExistence(timeout: 30),
                      "The editor's Rectangle tool never appeared — check the --loadTestDocument launch hook.")
        drawTool.tap()
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.55))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.62)))
        drawTool.tap()
        tapRedact()
        let running = app.descendants(matching: .any)["verificationBanner"]
        if !running.waitForExistence(timeout: 120) {
            if app.descendants(matching: .any)["verificationMasthead"].exists {
                throw XCTSkip("The checks ended before the running screen could be read.")
            }
            XCTFail("The running screen never appeared.")
        }
    }

    func testRunningScreenIsOneRing() throws {
        try startRun()
        XCTAssertTrue(app.descendants(matching: .any)["verificationProgress"].exists,
                      "The running screen's root is missing.")
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'layerResult_'"))
        XCTAssertEqual(rows.count, 0, "A check's row shows while the checks run.")
        let stop = app.buttons["stopProcessing"]
        XCTAssertTrue(stop.exists && stop.isHittable, "Stop is not in the bar during the checks.")
        let banner = app.descendants(matching: .any)["verificationBanner"]
        XCTAssertTrue(banner.label.hasPrefix("Verification In Progress."), "The block's label: \(banner.label)")
        attachScreenshot(named: "running-01")
    }

    func testRingStaysInPlace() throws {
        try startRun()
        let running = app.descendants(matching: .any)["verificationBanner"].frame
        let masthead = app.descendants(matching: .any)["verificationMasthead"]
        XCTAssertTrue(masthead.waitForExistence(timeout: 600), "The results never appeared.")
        let results = masthead.frame
        XCTAssertEqual(running.minY, results.minY, accuracy: 1,
                       "The ring moves at the hand-off: running \(running), results \(results).")
        attachScreenshot(named: "running-02-results")
    }

    func testTrustLineFollowsTheText() throws {
        try startRun(extraArguments: ["-UIPreferredContentSizeCategoryName",
                                      "UICTContentSizeCategoryAccessibilityXXXL"])
        let block = app.descendants(matching: .any)["verificationBanner"].frame
        let trust = app.descendants(matching: .any)["verificationTrustLine"].firstMatch
        XCTAssertTrue(trust.waitForExistence(timeout: 10), "The trust line is missing.")
        XCTAssertFalse(block.intersects(trust.frame),
                       "The trust line lies over the block: block \(block), trust line \(trust.frame).")
        attachScreenshot(named: "running-03-largest")
    }

    /// Redact sits in the bar beside Undo; at the largest text sizes it is
    /// first in the … menu (DocumentEditorToolbar's overflow sections).
    private func tapRedact() {
        let redact = app.buttons["redactButton"].firstMatch
        if redact.waitForExistence(timeout: 5), redact.isHittable {
            redact.tap()
            return
        }
        let overflow = app.editorOverflowButton
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "The … menu button never appeared.")
        overflow.tap()
        let row = app.buttons["Redact"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Redact is neither in the bar nor in the … menu.")
        row.tap()
    }
}
