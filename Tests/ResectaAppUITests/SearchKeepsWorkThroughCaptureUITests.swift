import XCTest

/// Search holds a typed search with ticked matches; the screen-capture
/// cover then replaces the sheet's content and lifts again. When it lifts,
/// the typed search, the list and the ticks are still there. The cover is
/// raised and lowered by the DEBUG timed capture hook, counted in seconds
/// from launch, so the route below has to end before the cover goes up.
// nonisolated: XCUITest driving a separate process, no @MainActor app state.
nonisolated final class SearchKeepsWorkThroughCaptureUITests: XCTestCase {

    /// The second after launch at which the cover goes up, and the second
    /// at which it lifts. The route must end before the first.
    private static let coverUpAfter = 30
    private static let coverDownAfter = 36

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

    private var shield: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "privacyShield").firstMatch
    }

    private func keepPicture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(until deadline: Date, for condition: () -> Bool) -> Bool {
        while !condition() {
            if Date() >= deadline { return false }
            usleep(200_000)
        }
        return true
    }

    func testSearchKeepsItsTicksThroughACapture() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--openSearchSheet",
            "--simulateCaptureAfter=\(Self.coverUpAfter)",
            "--simulateCaptureEndAfter=\(Self.coverDownAfter)",
        ]
        let launchedAt = Date()
        app.launch()

        let field = app.textFields["Search text"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Search sheet never presented under --openSearchSheet.")
        field.tap()
        field.typeText("Sample")
        XCTAssertTrue(app.staticTexts["Page 1"].waitForExistence(timeout: 15), "no results for the fixture's text")
        let selectAll = app.buttons["footerSelectAllButton"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "the footer's Select All never appeared")
        selectAll.tap()
        let apply = app.buttons["searchApplyButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5), "the Apply button never appeared")
        let ticked = apply.label
        XCTAssertNotEqual(ticked, "Apply 0", "Select All ticked nothing")
        XCTAssertEqual(field.value as? String, "Sample", "the field does not hold the typed search")

        let routeSeconds = Date().timeIntervalSince(launchedAt)
        XCTContext.runActivity(named: String(format: "route ended %.1f s after launch", routeSeconds)) { _ in }
        XCTAssertLessThan(
            routeSeconds, Double(Self.coverUpAfter),
            "the route took longer than the hook's delay: this run shows nothing; raise the two constants")
        keepPicture("before the cover")

        let upBy = launchedAt.addingTimeInterval(Double(Self.coverUpAfter + 15))
        XCTAssertTrue(wait(until: upBy) { shield.exists }, "the cover never came up")
        XCTAssertFalse(apply.exists, "the Apply button is on screen under the cover")
        XCTAssertFalse(field.exists, "the search field is on screen under the cover")
        let downBy = launchedAt.addingTimeInterval(Double(Self.coverDownAfter + 15))
        XCTAssertTrue(wait(until: downBy) { !shield.exists }, "the cover never lifted")
        sleep(1)
        keepPicture("after the cover lifted")

        // The expectation: what the person had is there again.
        XCTAssertTrue(apply.waitForExistence(timeout: 10), "the Apply button did not come back after the cover")
        XCTAssertEqual(apply.label, ticked, "the cover dropped the ticked matches")
        XCTAssertEqual(field.value as? String, "Sample", "the cover dropped the typed search")
        XCTAssertTrue(app.staticTexts["Page 1"].exists, "the cover dropped the list")
    }
}
