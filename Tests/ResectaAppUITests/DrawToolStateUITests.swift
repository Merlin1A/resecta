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

    // MARK: - The drawing caption in the bottom slot

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The top of the page bar's glass: the bar's element reports its content
    /// without the 8 pt of padding drawn round it.
    private func pageBarGlassTop() -> CGFloat {
        let bar = element("pageNav")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "The page bar is missing.")
        return bar.frame.minY - 8
    }

    /// The caption's foot is 8 pt above the page bar's glass.
    private func checkTheCaptionSitsAboveThePageBar(_ caption: XCUIElement) {
        let gap = pageBarGlassTop() - caption.frame.maxY
        XCTAssertEqual(gap, 8, accuracy: 1, "The slot's foot must be 8 pt above the page bar's glass; the gap is \(gap) pt.")
    }

    func testDrawingCaption_sitsInTheSlotAboveThePageBar() {
        let tool = app.buttons["drawTool"]
        XCTAssertTrue(toggle(tool, until: true), "the tool did not turn on")
        let caption = element("drawingCaption")
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "The drawing caption never appeared.")
        checkTheCaptionSitsAboveThePageBar(caption)
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(abs(caption.frame.midX - window.midX), 1,
                                 "The slot must be centred: its middle is at \(caption.frame.midX), the window's at \(window.midX).")
        XCTAssertGreaterThanOrEqual(caption.frame.width, 119.5, "The slot is at least 120 pt wide: \(caption.frame.width).")
        XCTAssertLessThanOrEqual(caption.frame.width, 360.5, "The slot is at most 360 pt wide: \(caption.frame.width).")
        attachScreenshot(named: "draw-caption-in-the-slot")
        XCTAssertTrue(toggle(tool, until: false), "the tool did not turn off")
        XCTAssertTrue(caption.waitForNonExistence(timeout: 5), "The caption must go with the tool.")
    }

    func testDrawingCaption_atTheLargestTextSize_staysInTheSlot() {
        app.terminate()
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let tool = app.buttons["drawTool"]
        XCTAssertTrue(tool.waitForExistence(timeout: 60), "the editor never appeared")
        // A wrong size name is ignored: at the largest size the counter stacks.
        let counter = element("pageNavCounter")
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(counter.frame.height, 40, "The text size did not take: the counter is \(counter.frame.height) pt tall.")
        XCTAssertTrue(toggle(tool, until: true), "the tool did not turn on")
        let caption = element("drawingCaption")
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "The drawing caption never appeared.")
        checkTheCaptionSitsAboveThePageBar(caption)
        let canvasHeight = pageBarGlassTop() - app.navigationBars.firstMatch.frame.maxY
        XCTAssertLessThanOrEqual(caption.frame.height, 0.4 * canvasHeight,
                                 "The slot may take at most 40% of the canvas: \(caption.frame.height) of \(canvasHeight) pt.")
        attachScreenshot(named: "draw-caption-in-the-slot-largest")
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
