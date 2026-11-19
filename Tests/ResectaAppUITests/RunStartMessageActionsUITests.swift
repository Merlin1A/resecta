import XCTest

/// A message whose button changes state must not outlive the start of a
/// run. The Search sheet's "Mode switch cleared …" message carries an
/// Undo that brings a Search session back; tapped while a run is up, it
/// used to raise the Search sheet over the run and leave it standing over
/// the results.
///
/// The message is looked up by its identifier, not its words: a message
/// that carries an action is `toastMessageWithAction`, one without is
/// `toastMessage`. Every place tapped is read from a frame while nothing
/// covers it, so no place is written for one phone.
///
/// nonisolated for the same reason as the sibling suites: an XCUITest
/// drives a separate process and touches no @MainActor app state.
nonisolated final class RunStartMessageActionsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// The message lives 8 seconds. The test must reach the run inside
    /// that time or it has shown nothing: a late arrival is a failure,
    /// never a pass.
    private static let messageLifetime: TimeInterval = 8
    private static let judgeWithin: TimeInterval = 7

    /// The screen points the test taps, read before the clock starts.
    private struct Places {
        let redact: XCUICoordinate
        let regex: XCUICoordinate
        let dismiss: XCUICoordinate
    }

    private func screenPoint(_ frame: CGRect) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
    }

    private func messageWithAction() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "toastMessageWithAction").firstMatch
    }

    /// Launch, mark the whole page, open Search with a typed query, and
    /// tap the Regex tab. A typed search, not a launch hook that seeds the
    /// query: that hook runs the search again whenever the sheet appears
    /// and would hide what the Undo restores.
    private func switchModeWithResultsListed() -> Places? {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()

        let search = app.buttons["searchRedact"]
        guard search.waitForExistence(timeout: 40) else {
            XCTFail("Editor toolbar never appeared.")
            return nil
        }
        sleep(9) // the import's own message leaves

        // One box before Search opens, so Redact may start; Redact's place
        // is read now, while nothing covers it.
        let wholePage = app.buttons["pageNavMarkWholePage"]
        guard wholePage.waitForExistence(timeout: 10) else {
            XCTFail("The page bar's whole-page control is missing.")
            return nil
        }
        wholePage.tap()
        let redact = app.buttons["redactButton"]
        guard redact.waitForExistence(timeout: 10), redact.isEnabled else {
            XCTFail("Redact is not enabled after marking the whole page.")
            return nil
        }
        let redactPoint = screenPoint(redact.frame)

        search.tap()
        let field = app.textFields["Search text"]
        guard field.waitForExistence(timeout: 15) else {
            XCTFail("Search field never appeared.")
            return nil
        }
        field.typeText("Amount\n")
        guard app.buttons["footerSelectAllButton"].waitForExistence(timeout: 40) else {
            XCTFail("The typed query returned no results.")
            return nil
        }
        sleep(2)

        let regex = app.buttons["Regex"].firstMatch
        let dismiss = app.buttons["searchDismissButton"]
        guard regex.exists, dismiss.exists else {
            XCTFail("The kind tabs or Dismiss are missing.")
            return nil
        }
        let places = Places(
            redact: redactPoint,
            regex: screenPoint(regex.frame),
            dismiss: screenPoint(dismiss.frame)
        )
        places.regex.tap()
        return places
    }

    /// What makes the second test's "gone" mean "withdrawn": the mode
    /// switch raises a message that carries an action.
    func testModeSwitchRaisesAMessageWithAnAction() {
        guard switchModeWithResultsListed() != nil else { return }
        XCTAssertTrue(
            messageWithAction().waitForExistence(timeout: 3),
            "The mode switch raised no message with an action."
        )
    }

    func testModeSwitchUndo_isWithdrawnWhenARunStarts() {
        guard let places = switchModeWithResultsListed() else { return }
        let switched = Date()
        places.dismiss.tap()                   // Search closes; nothing is ticked, so it does not ask
        places.redact.tap()                    // the run starts

        let stop = app.buttons["stopProcessing"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "The run did not start.")
        let elapsed = Date().timeIntervalSince(switched)
        print("RunStartMessageActions: \(elapsed) s from the mode switch to the run's stop control")
        XCTAssertLessThan(
            elapsed, Self.judgeWithin,
            "Too slow to judge: \(elapsed) s after the mode switch the message would have left by itself (it lives \(Self.messageLifetime) s)."
        )

        let message = messageWithAction()
        let messageStillUp = message.exists
        XCTAssertFalse(messageStillUp, "A message with an action is still up after the run started.")

        // If it is still up, tap its button (the message's trailing end)
        // and show what that does.
        if messageStillUp {
            let frame = message.frame
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.maxX - 36, dy: frame.midY))
                .tap()
            sleep(2)
        }
        XCTAssertFalse(app.buttons["searchDismissButton"].exists, "Search is up over the run.")
        XCTAssertFalse(app.buttons["applyCurrentResultButton"].exists, "Search's strip is up over the run.")

        // To the end of the run: Search stays down and the results come up.
        let deadline = Date().addingTimeInterval(150)
        while stop.exists && Date() < deadline { usleep(500_000) }
        XCTAssertFalse(stop.exists, "The run did not end within 150 s.")
        sleep(2)
        XCTAssertFalse(app.buttons["searchDismissButton"].exists, "Search is up over the results.")
        XCTAssertFalse(app.buttons["applyCurrentResultButton"].exists, "Search's strip is up over the results.")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "verificationMasthead").firstMatch
                .waitForExistence(timeout: 10),
            "The results screen never appeared."
        )
    }
}
