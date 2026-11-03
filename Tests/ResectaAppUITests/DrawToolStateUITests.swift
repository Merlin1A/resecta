import XCTest

/// The Rectangle tool tells assistive technologies whether drawing mode is
/// on. iOS 27 serves no accessibility value for a toolbar button, so there
/// the label carries the state ("Rectangle, Drawing mode active", else
/// "Rectangle"); earlier iOS keeps the label "Rectangle" and the value
/// says it ("Drawing mode active" / "Tap to enter drawing mode").
///
/// nonisolated: an XCUITest drives a separate process and touches no
/// @MainActor state.
nonisolated final class DrawToolStateUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 60), "the editor never appeared")
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testTheToolSaysWhetherDrawingModeIsOn() {
        let tool = app.buttons["drawTool"]
        XCTAssertTrue(reads(tool, on: false), "off: label '\(tool.label)', value '\(tool.value as? String ?? "")'")
        XCTAssertTrue(toggle(tool, until: true), "on: label '\(tool.label)', value '\(tool.value as? String ?? "")'")
        XCTAssertTrue(toggle(tool, until: false), "off again: label '\(tool.label)', value '\(tool.value as? String ?? "")'")
    }

    // MARK: - Helpers

    /// The accessibility state for drawing mode `on`, per OS.
    private func reads(_ tool: XCUIElement, on: Bool) -> Bool {
        if #available(iOS 27, *) {
            return tool.label == (on ? "Rectangle, Drawing mode active" : "Rectangle")
        }
        return tool.label == "Rectangle"
            && (tool.value as? String) == (on ? "Drawing mode active" : "Tap to enter drawing mode")
    }

    /// Tap the tool until it reads `on` (a toolbar tap can be dropped while
    /// the bar settles), at most three taps.
    private func toggle(_ tool: XCUIElement, until on: Bool) -> Bool {
        for _ in 0..<3 {
            tool.tap()
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                if reads(tool, on: on) { return true }
                usleep(250_000)
            }
        }
        return false
    }
}
