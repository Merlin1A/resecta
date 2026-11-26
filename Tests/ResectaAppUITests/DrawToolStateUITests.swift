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

    // MARK: - The tool's look on and off

    /// The six items of the bar whose frames turning the tool on must not
    /// move, by name.
    private func barFrames() -> [(String, CGRect)] {
        let items: [(String, XCUIElement)] = [
            ("drawTool", app.buttons["drawTool"]), ("Scan", app.buttons["Scan"]), ("Search", app.buttons["Search"]),
            ("undoButton", app.buttons["undoButton"]), ("redactButton", app.buttons["redactButton"]),
            ("overflow", app.editorOverflowButton),
        ]
        return items.map { name, element in
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(name) is not on the bar")
            return (name, element.frame)
        }
    }

    private static func describe(_ frames: [(String, CGRect)]) -> String {
        frames.map { name, f in
            String(format: "%@ %.2f,%.2f,%.2fx%.2f", name, f.minX, f.minY, f.width, f.height)
        }.joined(separator: "; ")
    }

    /// The points of `frame`, one a point, read from a fresh screenshot:
    /// how many match the brand teal, and how many are white with teal on
    /// both sides in their row (the glyph on the pill, not the bar's glass
    /// round it).
    private func tealAndWhitePoints(in frame: CGRect) -> (teal: Int, white: Int, total: Int) {
        let shot = XCUIScreen.main.screenshot()
        guard let probe = CanvasPixelProbe(shot, windowSize: shot.image.size) else {
            XCTFail("the screenshot could not be read"); return (0, 0, 0)
        }
        var teal = 0, white = 0, total = 0
        for y in stride(from: frame.minY + 0.5, to: frame.maxY, by: 1) {
            var tealXs: [CGFloat] = [], whiteXs: [CGFloat] = []
            for x in stride(from: frame.minX + 0.5, to: frame.maxX, by: 1) {
                let (r, g, b) = probe.rgb(x, y)
                total += 1
                if CanvasPixelProbe.Tint.teal.matches(r, g, b) { teal += 1; tealXs.append(x) }
                if r >= 235 && g >= 235 && b >= 235 { whiteXs.append(x) }
            }
            if let left = tealXs.first, let right = tealXs.last {
                white += whiteXs.filter { $0 > left && $0 < right }.count
            }
        }
        return (teal, white, total)
    }

    func testTheRectangleTool_onIsAFilledPill_andNothingMoves() {
        let tool = app.buttons["drawTool"]
        XCTAssertTrue(reads(tool, on: false), "the tool must start off")
        let off = barFrames()
        XCTAssertTrue(toggle(tool, until: true), "the tool did not turn on")
        sleep(1)
        let on = barFrames()
        let record = XCTAttachment(string: "off: \(Self.describe(off))\non: \(Self.describe(on))")
        record.name = "toolbar-frames"
        record.lifetime = .keepAlways
        add(record)
        print("TOOLBAR-FRAMES off: \(Self.describe(off)) | on: \(Self.describe(on))")
        // Nothing moves: each item's frame on is its frame off, to half a point.
        for ((name, before), (_, after)) in zip(off, on) {
            let moved = max(abs(before.minX - after.minX), abs(before.minY - after.minY),
                            abs(before.maxX - after.maxX), abs(before.maxY - after.maxY))
            XCTAssertLessThanOrEqual(moved, 0.5, "\(name) moved \(moved) pt when the tool turned on: \(before) off, \(after) on")
        }
        // On: a filled teal pill over most of the item, the glyph white on it.
        attachScreenshot(named: "rectangle-tool-on")
        let frame = on[0].1
        let lit = tealAndWhitePoints(in: frame)
        print("PILL-POINTS on: teal \(lit.teal) of \(lit.total), white inside the pill \(lit.white)")
        XCTAssertGreaterThanOrEqual(Double(lit.teal), 0.6 * Double(lit.total),
                                    "on: \(lit.teal) of \(lit.total) points in the tool's frame are brand teal")
        XCTAssertGreaterThanOrEqual(lit.white, 12, "on: \(lit.white) white points inside the teal pill (the glyph)")
        // Off again: no teal in the frame, as shipped.
        XCTAssertTrue(toggle(tool, until: false), "the tool did not turn off")
        sleep(1)
        attachScreenshot(named: "rectangle-tool-off")
        let plain = tealAndWhitePoints(in: frame)
        XCTAssertEqual(plain.teal, 0, "off: \(plain.teal) points in the tool's frame are still brand teal")
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

    /// The slot's glass foot: the slot's element reports the frame of the
    /// words it holds, not its glass, so the foot is the words' foot plus the
    /// slot's 12 pt of vertical padding (`DocumentEditorView.bottomSlotVerticalPadding`).
    static func slotGlassFoot(_ slot: XCUIElement) -> CGFloat {
        let words = slot.staticTexts.firstMatch
        return (words.exists ? words.frame : slot.frame).maxY + 12
    }

    /// The caption's glass foot is 8 pt above the page bar's glass.
    private func checkTheCaptionSitsAboveThePageBar(_ caption: XCUIElement) {
        let gap = pageBarGlassTop() - Self.slotGlassFoot(caption)
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
        // The glass is the words and 16 pt of padding each side, at least 120 wide.
        let glassWidth = max(caption.frame.width + 32, 120)
        XCTAssertLessThanOrEqual(glassWidth, 360.5, "The slot is at most 360 pt wide: \(glassWidth).")
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
