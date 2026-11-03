import XCTest

/// The editor toolbar's controls say why and how on iOS 27. iOS 27 drops a
/// toolbar button's accessibility hint, so there the hint follows the label
/// after ", "; earlier iOS keeps the plain label and speaks the hint.
///
/// nonisolated: an XCUITest drives a separate process and touches no
/// @MainActor state.
nonisolated final class ToolbarHintLabelUITests: XCTestCase {

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

    func testRedactSaysWhyItIsNotAvailableWithNoRegions() {
        launchEditor()
        let redact = app.buttons["redactButton"]
        XCTAssertFalse(redact.isEnabled, "with no regions Redact is not available")
        XCTAssertTrue(waitForLabel(redact, labelled("Redact", "Draw regions or apply Scan or Search results first")),
                      "Redact reads '\(redact.label)'")
    }

    func testRedactSaysWhyWithUnappliedMatches() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
        app.launch()
        let selectAll = app.buttons["footerSelectAllButton"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 30), "the seeded query returned nothing")
        selectAll.tap()
        let next = app.buttons["resultNavNext"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        let strip = app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "the walk parked the sheet")
        openOverflowAndTap("Mark Whole Page")
        let redact = app.buttons["redactButton"]
        XCTAssertTrue(waitForLabel(redact, labelled("Redact", "Apply or clear the selected matches first")),
                      "Redact reads '\(redact.label)'")
    }

    func testUndoSaysHowItWorks() {
        launchEditor()
        let undo = app.buttons["undoButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(undo, "Undo"), "with no history Undo reads '\(undo.label)'")

        let mark = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(mark.waitForExistence(timeout: 10))
        mark.tap()
        XCTAssertTrue(waitForLabel(undo, labelled("Undo", "Touch and hold for Undo and Redo.")),
                      "with a step to undo Undo reads '\(undo.label)'")

        undo.tap()
        XCTAssertTrue(waitForLabel(undo, labelled("Undo", "Shows Undo and Redo.")),
                      "with only a redo left Undo reads '\(undo.label)'")
    }

    func testStopSaysWhatItDoes() {
        launchEditor()
        let mark = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(mark.waitForExistence(timeout: 10))
        mark.tap()
        let redact = app.buttons["redactButton"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: redact)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed, "a region makes Redact available")
        redact.tap()
        let stop = app.buttons["stopProcessing"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "a run shows its Stop control")
        let expected = [
            labelled("Stop Processing", "Stops processing. Your document is preserved."),
            labelled("Stop Verification", "Stops processing. Your document is preserved."),
        ]
        XCTAssertTrue(expected.contains(stop.label), "Stop reads '\(stop.label)'")
        stop.tap()
    }

    // MARK: - Helpers

    /// The label a toolbar control carries on this iOS.
    private func labelled(_ label: String, _ hint: String) -> String {
        if #available(iOS 27, *) { return "\(label), \(hint)" }
        return label
    }

    private func launchEditor() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 60), "the editor never appeared")
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label == label { return true }
            usleep(250_000)
        }
        return false
    }

    private func openOverflowAndTap(_ item: String) {
        let overflow = app.editorOverflowButton
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "the … menu is missing")
        overflow.tap()
        let row = app.buttons[item].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the … menu has no \(item)")
        row.tap()
    }
}
