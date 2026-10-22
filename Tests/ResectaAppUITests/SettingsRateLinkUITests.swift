import XCTest

/// The Support section's "Rate Resecta on the App Store" row is present in
/// Settings and carries the App Store review link (the URL itself is
/// pinned by `LegalLinkExistenceTests`; a tap would leave the app for the
/// App Store, which a UI test cannot follow).
// nonisolated: XCUITest driving a separate process, no @MainActor app state.
nonisolated final class SettingsRateLinkUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--openSettings"]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testRateRowIsPresentUnderSupport() {
        XCTAssertTrue(
            app.descendants(matching: .any)["settingsView"].waitForExistence(timeout: 30),
            "Settings never presented under --openSettings."
        )
        let row = app.descendants(matching: .any)["settingsRateLink"]
        var swipes = 0
        while !row.exists && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the Rate row is missing from the Support section")
        XCTAssertTrue(row.label.contains("Rate Resecta on the App Store"), "label: \(row.label)")
    }
}
