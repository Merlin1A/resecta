import XCTest

/// UI tests for the first-launch sequence: the agreement, then the
/// developer's note once, then Home.
///
/// - A fresh install (`--resetEULA` clears the agreement and the note's
///   flag): I Agree → the note → Continue → Home; a relaunch with no
///   arguments opens on Home, with neither screen.
/// - An install that accepted the 1.0.0–1.2.0 terms
///   (`--seedLegacyAcceptance`): the gate presents again, and the note
///   follows I Agree.
/// - At AX5 the note's text scrolls and Continue stays reachable.
// nonisolated: XCUITest driving a separate process, no @MainActor app state —
// same SE-0466 posture as EULAGateLinksUITests.
nonisolated final class FirstLaunchNoteUITests: XCTestCase {

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

    func testFreshInstallShowsTheNoteOnceAfterAgree() {
        app.launchArguments = ["--resetEULA"]
        app.launch()

        agree()
        continueFromNote()
        requireHome()

        // A relaunch with no hooks reads the persisted flags: Home, no gate, no note.
        app.terminate()
        app.launchArguments = []
        app.launch()
        requireHome()
        XCTAssertFalse(app.buttons["eulaAccept"].exists, "the gate came back on relaunch")
        XCTAssertFalse(app.buttons["developerNoteContinue"].exists, "the note came back on relaunch")
    }

    func testAnInstallThatAcceptedEarlierTermsAgreesAgain() {
        // Leave the app past both screens first, so a build that does not
        // know the earlier key would open straight on Home below.
        app.launchArguments = ["--uitesting"]
        app.launch()
        requireHome()
        app.terminate()

        app.launchArguments = ["--seedLegacyAcceptance"]
        app.launch()
        XCTAssertTrue(
            app.buttons["eulaAccept"].waitForExistence(timeout: 30),
            "An install that accepted the earlier terms must see the agreement again."
        )
        agree()
        continueFromNote()
        requireHome()
    }

    func testTheNoteScrollsAndContinueIsReachableAtAX5() {
        app.launchArguments = [
            "--resetEULA",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        agree()
        let next = app.buttons["developerNoteContinue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10), "the note never presented after I Agree")
        XCTAssertTrue(next.isHittable, "Continue must stay reachable at AX5 (pinned beneath the text)")
        next.tap()
        requireHome()
    }

    // MARK: - Steps

    private func agree() {
        let accept = app.buttons["eulaAccept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 30), "the gate never presented")
        accept.tap()
    }

    private func continueFromNote() {
        let next = app.buttons["developerNoteContinue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10), "the note never presented after I Agree")
        XCTAssertTrue(
            app.staticTexts["Why I Made Resecta"].exists,
            "the note's title is missing"
        )
        XCTAssertTrue(app.buttons["eulaAccept"].waitForNonExistence(timeout: 5), "the gate is still up under the note")
        next.tap()
    }

    private func requireHome() {
        XCTAssertTrue(
            app.buttons["homeOpenDocument"].waitForExistence(timeout: 30),
            "Home never appeared"
        )
        XCTAssertFalse(app.buttons["developerNoteContinue"].exists, "the note is still up over Home")
    }
}
