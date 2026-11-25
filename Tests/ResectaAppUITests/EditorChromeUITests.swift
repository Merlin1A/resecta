import XCTest

/// UI tests for the editor's chrome: the page bar's whole-page control as a
/// per-page toggle that keeps its place, the page bar on a one-page
/// document, and the page bar back once a parked match walk ends.
///
/// Launch arguments only; every assertion reads identifiers and labels.
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class EditorChromeUITests: XCTestCase {

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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Wait until `element`'s label equals `label`.
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Mark ↔ Unmark

    func testWholePageControl_marksThenUnmarksInPlace() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()

        let control = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(control.waitForExistence(timeout: 30), "The page bar's whole-page control never appeared.")
        let counter = element("pageNavCounter")
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 23, 0 regions"),
                      "An empty page's counter must speak its zero count; it read '\(counter.label)'.")
        XCTAssertEqual(control.label, "Mark Whole Page")
        let xBefore = control.frame.midX

        control.tap()
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 23, 1 region"),
                      "Mark Whole Page must add one region; the counter read '\(counter.label)'.")
        XCTAssertTrue(waitForLabel(control, "Unmark Whole Page"), "A marked page's control must read Unmark Whole Page.")
        XCTAssertTrue(control.isSelected, "A marked page's control must report itself selected.")
        XCTAssertEqual(control.frame.midX, xBefore, accuracy: 0.5,
                       "The control must keep its place when the count appears.")
        attachScreenshot(named: "chrome-page-bar-marked")

        control.tap()
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 23, 0 regions"),
                      "Unmark Whole Page must remove the region; the counter read '\(counter.label)'.")
        XCTAssertTrue(waitForLabel(control, "Mark Whole Page"))
        XCTAssertFalse(control.isSelected)
        XCTAssertEqual(control.frame.midX, xBefore, accuracy: 0.5)
    }

    // MARK: - The control at large text sizes

    /// The largest text size, and Accessibility 1, the first size above the
    /// symbol's ceiling. A wrong name is ignored and the app runs at the
    /// default size, so each launch checks that its size took.
    private static let largestTextSize = "UICTContentSizeCategoryAccessibilityXXXL"
    private static let accessibilityOne = "UICTContentSizeCategoryAccessibilityM"

    /// Launch the multi-page document at `textSize` (nil: the default) and
    /// return the whole-page control.
    private func launchWholePageControl(atTextSize textSize: String?) -> XCUIElement {
        // A size name the system ignores says nothing, so a sized launch is
        // measured against the default size first: a message raised by the
        // launch hook must be taller. (The counter's own height cannot tell:
        // its tappable height is floored to the touch target at every size.)
        var defaultHeight: CGFloat?
        if textSize != nil {
            launchEditorForWholePage(textSize: nil, withMessage: true)
            defaultHeight = loadMessageHeight()
            app.terminate()
        }
        launchEditorForWholePage(textSize: textSize, withMessage: textSize != nil)
        let control = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(control.waitForExistence(timeout: 30), "The page bar's whole-page control never appeared.")
        if let defaultHeight {
            let height = loadMessageHeight()
            XCTAssertGreaterThan(height, defaultHeight + 1,
                                 "The text size did not take: the message is \(height) pt tall, \(defaultHeight) pt at the default size.")
        }
        return control
    }

    /// `withMessage` raises one message through the launch hook, as a
    /// measure of the text size (a document's arrival raises none).
    private func launchEditorForWholePage(textSize: String?, withMessage: Bool = false) {
        var arguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        if withMessage { arguments.append("--showToast=selectionLimit") }
        if let textSize { arguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launchArguments = arguments
        app.launch()
    }

    /// The launch hook's message's height once it has stopped sliding in.
    private func loadMessageHeight() -> CGFloat {
        let message = element("toastMessage")
        XCTAssertTrue(message.waitForExistence(timeout: 60), "The launch hook's message never appeared.")
        var frame = message.frame
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            let next = message.frame
            if next == frame { break }
            frame = next
        }
        return frame.height
    }

    private func screenshotProbe() throws -> CanvasPixelProbe {
        try XCTUnwrap(CanvasPixelProbe(XCUIScreen.main.screenshot(), windowSize: app.windows.firstMatch.frame.size))
    }

    /// Mark the page, then: at 8 points on a circle of radius 19 pt round
    /// the control's centre the disc shows teal, and the symbol's middle is
    /// white.
    private func markAndCheckTheDisc(_ control: XCUIElement, screenshot name: String) throws {
        control.tap()
        XCTAssertTrue(waitForLabel(control, "Unmark Whole Page"), "A marked page's control must read Unmark Whole Page.")
        let probe = try screenshotProbe()
        attachScreenshot(named: name)
        let centre = CGPoint(x: control.frame.midX, y: control.frame.midY)
        for step in 0..<8 {
            let angle = CGFloat(step) * .pi / 4
            let (r, g, b) = probe.rgb(centre.x + 19 * cos(angle), centre.y + 19 * sin(angle))
            XCTAssertTrue(CanvasPixelProbe.Tint.teal.matches(r, g, b),
                          "The disc must show teal \(step * 45)° round the symbol; it read (\(r), \(g), \(b)).")
        }
        let (r, g, b) = probe.rgb(centre.x, centre.y)
        XCTAssertTrue(r >= 235 && g >= 235 && b >= 235,
                      "The marked symbol's middle must be white; it read (\(r), \(g), \(b)).")
    }

    func testWholePageControl_atTheLargestTextSize_symbolStaysInsideItsDisc() throws {
        let control = launchWholePageControl(atTextSize: Self.largestTextSize)
        XCTAssertTrue(waitForLabel(control, "Mark Whole Page"))
        let unmarked = try screenshotProbe()
        attachScreenshot(named: "chrome-whole-page-largest-unmarked")
        let symbol = try XCTUnwrap(unmarked.tintBounds(.teal, in: control.frame), "No teal symbol inside the control.")
        XCTAssertLessThanOrEqual(symbol.width, 30, "The unmarked symbol must stop growing at its ceiling; it is \(symbol.width) pt wide.")
        XCTAssertLessThanOrEqual(symbol.height, 24, "The unmarked symbol must stop growing at its ceiling; it is \(symbol.height) pt tall.")
        try markAndCheckTheDisc(control, screenshot: "chrome-whole-page-largest-marked")
    }

    func testWholePageControl_atAccessibilityOne_symbolStaysInsideItsDisc() throws {
        let control = launchWholePageControl(atTextSize: Self.accessibilityOne)
        XCTAssertTrue(waitForLabel(control, "Mark Whole Page"))
        try markAndCheckTheDisc(control, screenshot: "chrome-whole-page-accessibility-one-marked")
    }

    func testWholePageControl_atTheDefaultSize_discIsUnchanged() throws {
        let control = launchWholePageControl(atTextSize: nil)
        XCTAssertTrue(waitForLabel(control, "Mark Whole Page"))
        try markAndCheckTheDisc(control, screenshot: "chrome-whole-page-default-marked")
        let disc = try XCTUnwrap(try screenshotProbe().tintBounds(.teal, in: control.frame), "No teal disc inside the control.")
        XCTAssertEqual(disc.width, 44, accuracy: 1, "The default size's disc must stay 44 pt wide.")
        XCTAssertEqual(disc.height, 44, accuracy: 1, "The default size's disc must stay 44 pt tall.")
    }

    // MARK: - The bar's order

    /// The bar's four pieces, left to right: the whole-page control,
    /// Previous, the counter, Next. Each ends before the next begins, and
    /// the control is one stack gap (16 pt) from Previous: the hairline
    /// between them adds no width.
    private func checkTheBarLeadsWithTheControl(_ control: XCUIElement) -> [XCUIElement] {
        let previous = app.buttons["pageNavPrevious"]
        let counter = element("pageNavCounter")
        let next = app.buttons["pageNavNext"]
        XCTAssertTrue(previous.waitForExistence(timeout: 10))
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let pieces = [control, previous, counter, next]
        let names = ["the whole-page control", "Previous", "the counter", "Next"]
        for i in 0..<(pieces.count - 1) {
            XCTAssertLessThanOrEqual(pieces[i].frame.maxX, pieces[i + 1].frame.minX + 0.5,
                                     "\(names[i]) must end before \(names[i + 1]) begins: \(pieces[i].frame) then \(pieces[i + 1].frame).")
        }
        XCTAssertEqual(previous.frame.minX - control.frame.maxX, 16, accuracy: 0.5,
                       "The control must sit one stack gap from Previous: \(control.frame) then \(previous.frame).")
        return pieces
    }

    func testPageBar_wholePageControlLeadsTheBar() {
        let control = launchWholePageControl(atTextSize: nil)
        _ = checkTheBarLeadsWithTheControl(control)
        let bar = element("pageNav")
        XCTAssertTrue(bar.exists)
        print("page bar width at the default size: \(bar.frame.width) pt")
        attachScreenshot(named: "chrome-page-bar-default-control-first")
    }

    func testPageBarCount_isNotOrangeOnAPageWithABox() throws {
        let control = launchWholePageControl(atTextSize: nil)
        let counter = element("pageNavCounter")
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        control.tap()
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 23, 1 region"),
                      "Mark Whole Page must add one region; the counter read '\(counter.label)'.")
        let probe = try screenshotProbe()
        attachScreenshot(named: "chrome-page-bar-count-with-a-box")
        XCTAssertNil(probe.tintBounds(.red, in: counter.frame),
                     "The count on a page with a box must be the support grey, not orange.")
    }

    func testPageBar_atTheLargestTextSize_controlLeadsAndNothingIsCut() {
        let control = launchWholePageControl(atTextSize: Self.largestTextSize)
        let pieces = checkTheBarLeadsWithTheControl(control)
        let window = app.windows.firstMatch.frame
        let bar = element("pageNav")
        XCTAssertTrue(bar.exists)
        for piece in pieces + [bar] {
            XCTAssertTrue(window.contains(piece.frame),
                          "Every piece of the bar must lie inside the window \(window) at the largest text size: \(piece.frame).")
        }
        print("page bar width at the largest text size: \(bar.frame.width) pt")
        attachScreenshot(named: "chrome-page-bar-largest-control-first")
    }

    // MARK: - The page menu

    /// A menu row or line found by its words.
    private func labelled(_ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", words)).firstMatch
    }

    /// Open the page menu from the counter and wait for its first row.
    private func openPageMenu() {
        let counter = element("pageNavCounter")
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        counter.tap()
        XCTAssertTrue(app.buttons["Go to Page\u{2026}"].waitForExistence(timeout: 5), "The counter must open the page menu.")
    }

    /// Type `text` into the prompt's field after clearing it, and read it back.
    private func typePage(_ text: String, into field: XCUIElement) throws {
        field.tap()
        let current = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        if !current.isEmpty, current != placeholder {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        if !text.isEmpty { field.typeText(text) }
        let read = (field.value as? String) ?? ""
        let landed = text.isEmpty ? (read.isEmpty || read == placeholder) : read == text
        if !landed {
            if #available(iOS 27, *) {
                throw XCTSkip("the iOS 27.2 simulator's software keyboard did not take the typed page")
            }
            XCTFail("The typed page did not land: the field reads '\(read)', not '\(text)'.")
        }
    }

    func testPageMenu_goToPageTwelve() throws {
        _ = launchWholePageControl(atTextSize: nil)
        let counter = element("pageNavCounter")
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        XCTAssertNil(try screenshotProbe().tintBounds(.teal, in: counter.frame),
                     "The counter at rest must keep its own colours: the menu must not tint it teal.")
        openPageMenu()
        XCTAssertTrue(labelled("No boxes yet").waitForExistence(timeout: 5), "With no box the total line reads No boxes yet.")
        XCTAssertFalse(app.buttons["Next Page with Boxes"].isEnabled, "With no box Next Page with Boxes is not available.")
        XCTAssertFalse(app.buttons["Previous Page with Boxes"].isEnabled, "With no box Previous Page with Boxes is not available.")
        attachScreenshot(named: "page-menu-no-boxes")
        app.buttons["Go to Page\u{2026}"].tap()
        let alert = app.alerts["Go to Page"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Go to Page must open its prompt.")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.placeholderValue, "Page 1 to 23")
        attachScreenshot(named: "page-menu-prompt-empty")
        try typePage("12", into: field)
        let go = alert.buttons["Go"]
        XCTAssertTrue(go.isEnabled, "Go is available for page 12.")
        attachScreenshot(named: "page-menu-prompt-twelve")
        go.tap()
        XCTAssertTrue(waitForLabel(counter, "Page 12 of 23, 0 regions"), "Go must show page 12; the counter read '\(counter.label)'.")
    }

    func testPageMenu_goIsUnavailableUntilTheNumberIsAPage() throws {
        _ = launchWholePageControl(atTextSize: nil)
        let counter = element("pageNavCounter")
        openPageMenu()
        app.buttons["Go to Page\u{2026}"].tap()
        let alert = app.alerts["Go to Page"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Go to Page must open its prompt.")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let go = alert.buttons["Go"]
        XCTAssertFalse(go.isEnabled, "Go is not available with the field empty.")
        try typePage("0", into: field)
        XCTAssertFalse(go.isEnabled, "Go is not available for 0.")
        try typePage("24", into: field)
        XCTAssertFalse(go.isEnabled, "Go is not available for 24 on 23 pages.")
        try typePage("23", into: field)
        XCTAssertTrue(go.isEnabled, "Go is available for 23.")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "Cancel must close the prompt.")
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 23, 0 regions"), "Cancel must leave the page as it was; the counter read '\(counter.label)'.")
    }

    func testPageMenu_nextAndPreviousPageWithBoxes() {
        let control = launchWholePageControl(atTextSize: nil)
        let counter = element("pageNavCounter")
        let next = app.buttons["pageNavNext"]
        let previous = app.buttons["pageNavPrevious"]
        func step(_ arrow: XCUIElement, times: Int, to label: String) {
            for _ in 0..<times { arrow.tap() }
            XCTAssertTrue(waitForLabel(counter, label), "The arrows must reach '\(label)'; the counter read '\(counter.label)'.")
        }
        step(next, times: 2, to: "Page 3 of 23, 0 regions")
        control.tap()
        XCTAssertTrue(waitForLabel(counter, "Page 3 of 23, 1 region"))
        step(next, times: 4, to: "Page 7 of 23, 0 regions")
        control.tap()
        XCTAssertTrue(waitForLabel(counter, "Page 7 of 23, 1 region"))
        step(previous, times: 6, to: "Page 1 of 23, 0 regions")

        openPageMenu()
        XCTAssertTrue(labelled("2 boxes on 2 pages").waitForExistence(timeout: 5), "The total line counts both boxes and both pages.")
        XCTAssertFalse(app.buttons["Previous Page with Boxes"].isEnabled, "No page before page 1 holds a box.")
        attachScreenshot(named: "page-menu-two-boxes")
        app.buttons["Next Page with Boxes"].tap()
        XCTAssertTrue(waitForLabel(counter, "Page 3 of 23, 1 region"), "Next Page with Boxes from page 1 is page 3; the counter read '\(counter.label)'.")
        openPageMenu()
        app.buttons["Next Page with Boxes"].tap()
        XCTAssertTrue(waitForLabel(counter, "Page 7 of 23, 1 region"), "Next Page with Boxes from page 3 is page 7; the counter read '\(counter.label)'.")
        openPageMenu()
        XCTAssertFalse(app.buttons["Next Page with Boxes"].isEnabled, "No page after page 7 holds a box: the row must not wrap round.")
        app.buttons["Previous Page with Boxes"].tap()
        XCTAssertTrue(waitForLabel(counter, "Page 3 of 23, 1 region"), "Previous Page with Boxes from page 7 is page 3; the counter read '\(counter.label)'.")
    }

    func testOnePageDocument_counterOpensNoMenu() {
        app.launchArguments = ["--uitesting", "--loadTestDocument"]
        app.launch()
        let counter = element("pageNavCounter")
        XCTAssertTrue(counter.waitForExistence(timeout: 30), "The page bar's counter never appeared.")
        XCTAssertNotEqual(counter.elementType, .button, "On a one-page document the counter is not a button.")
        counter.tap()
        XCTAssertFalse(app.buttons["Go to Page\u{2026}"].waitForExistence(timeout: 3), "On a one-page document the counter opens no menu.")
    }

    // MARK: - The one-page bar

    func testOnePageDocument_showsTheCountWithoutArrowsOrControl() {
        app.launchArguments = ["--uitesting", "--loadTestDocument"]
        app.launch()

        let counter = element("pageNavCounter")
        XCTAssertTrue(counter.waitForExistence(timeout: 30), "A one-page document must show the page bar's counter.")
        XCTAssertTrue(waitForLabel(counter, "Page 1 of 1, 0 regions"),
                      "The one-page counter read '\(counter.label)'.")
        XCTAssertTrue(app.staticTexts["1 of 1"].exists, "The drawn counter must read '1 of 1'.")
        XCTAssertFalse(app.buttons["pageNavPrevious"].exists, "No page arrows on a one-page document.")
        XCTAssertFalse(app.buttons["pageNavNext"].exists, "No page arrows on a one-page document.")
        XCTAssertFalse(app.buttons["pageNavMarkWholePage"].exists,
                       "No whole-page control on a one-page document; the … menu keeps the action.")
        attachScreenshot(named: "chrome-page-bar-one-page")
    }

    // MARK: - The page bar comes back when the walk ends

    /// The bar steps aside while the walk is parked and is back, usable,
    /// once the sheet is dismissed and the walk ends.
    func testWalkEnds_pageBarReturns() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        next.tap()
        XCTAssertTrue(element("compactFloatStrip").waitForExistence(timeout: 10), "The first chevron tap did not park the sheet.")
        let pageBar = element("pageNav")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pageBar)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "The page bar must step aside while the walk is parked.")

        let dismiss = raiseSheetToDismiss()
        XCTAssertNotNil(dismiss, "The sheet's Dismiss never appeared after the raise.")
        dismiss?.tap()
        let pageNext = app.buttons["pageNavNext"]
        XCTAssertTrue(pageNext.waitForExistence(timeout: 10), "The page bar must be back once the walk ends.")
        XCTAssertTrue(pageNext.isHittable, "The page bar's next control must be usable once the walk ends.")
        let counter = element("pageNavCounter")
        let before = counter.label
        pageNext.tap()
        let paged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: counter)
        XCTAssertEqual(XCTWaiter().wait(for: [paged], timeout: 8), .completed, "The returned page bar must page.")
        attachScreenshot(named: "chrome-walk-ended-page-bar-back")
    }

    // MARK: - A bottom message above the page bar, at every text size

    /// The gap between a bottom message's foot and the page bar's glass at
    /// every text size: the 8 pt the message host adds above the chrome
    /// (`MessagePlacement.aboveChrome`). Read from the receipt's own
    /// element, whose frame is its capsule.
    private static let gapAbovePageBar: CGFloat = 8

    /// The page bar's padding above its content, which the bar's element
    /// does not report (its identifier sits on the content).
    private static let pageBarTopPadding: CGFloat = 8

    private func launchEditor(textSize: String?) {
        var arguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        if let textSize { arguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launchArguments = arguments
        app.launch()
    }

    /// A bottom message and the page bar, read once the message has stopped
    /// sliding in.
    private struct BottomReading {
        let message: CGRect
        let bar: CGRect
        /// The gap between the message's foot and the top of the bar's glass.
        var gap: CGFloat { (bar.minY - EditorChromeUITests.pageBarTopPadding) - message.maxY }
    }

    private func readBottom(_ name: String) -> BottomReading {
        let bar = element("pageNav")
        XCTAssertTrue(bar.waitForExistence(timeout: 60), "The page bar never appeared.")
        raiseDeletedTwoRegions()
        // "Deleted 2 regions." offers Undo, so its receipt carries the
        // with-action identifier; its frame is the capsule either way.
        let message = element("toastMessageWithAction")
        XCTAssertTrue(message.waitForExistence(timeout: 10), "The bottom message never appeared.")
        var frame = message.frame
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            let next = message.frame
            if next == frame { break }
            frame = next
        }
        let read = BottomReading(message: frame, bar: bar.frame)
        let reading = XCTAttachment(string: "gap \(read.gap) pt; message \(read.message); page bar \(read.bar)")
        reading.name = "\(name)-gap"
        reading.lifetime = .keepAlways
        add(reading)
        attachScreenshot(named: name)
        return read
    }

    /// Raises "Deleted 2 regions." with its Undo, as the shipped
    /// `EditorToolbarUITests.testDeleteTwoRegions_noticeUndoRestoresThem`
    /// does: page 1 marked whole, a second box drawn, both selected and
    /// deleted. The message stays at least 8 s.
    private func raiseDeletedTwoRegions() {
        let counter = element("pageNavCounter")
        let mark = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(mark.waitForExistence(timeout: 30), "The page bar's whole-page control never appeared.")
        mark.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "1 region"), "Marking the page did not add a region.")
        let draw = app.buttons["drawTool"].firstMatch
        XCTAssertTrue(draw.waitForExistence(timeout: 10), "The Rectangle tool is missing.")
        draw.tap()
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.40))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)))
        draw.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "2 regions"), "The drawn box did not count.")
        openOverflowAndTap("Select Regions")
        let selectAll = app.buttons["Select All on Page"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), "Select All on Page is missing.")
        selectAll.tap()
        openOverflowAndTap("Delete 2 Regions")
        XCTAssertTrue(waitForLabel(counter, containing: "0 regions"), "Both regions must go at once.")
        let notice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Deleted 2 regions.'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "Deleting two did not show its message.")
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func openOverflowAndTap(_ label: String) {
        let overflow = app.editorOverflowButton
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "The … menu button is missing.")
        overflow.tap()
        let row = app.buttons[label].firstMatch.exists ? app.buttons[label].firstMatch : app.switches[label].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The … menu has no '\(label)' row.")
        row.tap()
    }

    /// The same reading at the default text size, then at `textSize`. The
    /// counter's tappable height is floored to the touch target, so its own
    /// height no longer tells one line from two; the default reading is the
    /// measure instead. The message is taller than at the default size, or
    /// the size name was ignored (the system says nothing).
    private func readBottomAgainstTheDefault(textSize: String, _ name: String) -> (base: BottomReading, sized: BottomReading) {
        launchEditor(textSize: nil)
        let base = readBottom("\(name)-default")
        app.terminate()
        launchEditor(textSize: textSize)
        let sized = readBottom(name)
        XCTAssertGreaterThan(sized.message.height, base.message.height + 1,
                             "The text size did not take: the message is \(sized.message.height) pt tall, \(base.message.height) pt at the default size.")
        return (base, sized)
    }

    func testBottomMessage_atTheDefaultSize_keepsItsGapAboveThePageBar() {
        launchEditor(textSize: nil)
        let gap = readBottom("bottom-message-default-size").gap
        XCTAssertLessThanOrEqual(abs(gap - Self.gapAbovePageBar), 2,
                                 "The message's gap above the page bar is \(gap) pt.")
    }

    func testBottomMessage_atTheLargestOrdinarySize_keepsItsGapAboveThePageBar() {
        let read = readBottomAgainstTheDefault(textSize: "UICTContentSizeCategoryXXXL", "bottom-message-largest-ordinary-size")
        XCTAssertLessThanOrEqual(abs(read.sized.bar.height - read.base.bar.height), 1,
                                 "Below the accessibility sizes the counter is on one line: the page bar is \(read.sized.bar.height) pt tall, \(read.base.bar.height) pt at the default size.")
        let gap = read.sized.gap
        XCTAssertLessThanOrEqual(abs(gap - Self.gapAbovePageBar), 2,
                                 "The message's gap above the page bar is \(gap) pt.")
    }

    func testBottomMessage_atAccessibilityOne_keepsItsGapAboveThePageBar() {
        let gap = readBottomAgainstTheDefault(textSize: "UICTContentSizeCategoryAccessibilityM", "bottom-message-accessibility-one").sized.gap
        XCTAssertLessThanOrEqual(abs(gap - Self.gapAbovePageBar), 2,
                                 "The message's gap above the page bar is \(gap) pt.")
    }

    func testBottomMessage_atTheLargestTextSize_keepsItsGapAboveThePageBar() {
        let read = readBottomAgainstTheDefault(textSize: "UICTContentSizeCategoryAccessibilityXXXL", "bottom-message-largest-text-size")
        XCTAssertGreaterThan(read.sized.bar.height, read.base.bar.height + 1,
                             "At the largest size the counter stacks: the page bar is \(read.sized.bar.height) pt tall, \(read.base.bar.height) pt at the default size.")
        let gap = read.sized.gap
        XCTAssertGreaterThanOrEqual(gap, 0, "The message overlaps the page bar by \(-gap) pt.")
        XCTAssertLessThanOrEqual(abs(gap - Self.gapAbovePageBar), 2,
                                 "The message's gap above the page bar is \(gap) pt.")
    }

    /// Grabber drag from the parked strip up until the sheet's Dismiss
    /// shows (`ResultWalkUITests`' idiom); the Dismiss, or nil.
    private func raiseSheetToDismiss() -> XCUIElement? {
        let window = app.windows.firstMatch
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        for _ in 0..<3 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.1, thenDragTo: end)
            if dismiss.waitForExistence(timeout: 3), dismiss.isHittable { return dismiss }
        }
        return nil
    }

    // MARK: - The image note in the band

    /// The image note stays in the editor's band until the person closes
    /// it: not by time, not by a Search opened and closed over it. Closed,
    /// it does not come back for that document.
    func testImageImportNote_staysInTheEditorUntilClosed() {
        app.launchArguments = ["--uitesting", "--loadTestImage"]
        app.launch()
        XCTAssertTrue(element("drawTool").waitForExistence(timeout: 60), "The editor never loaded.")
        let note = element("imagePagesNote")
        XCTAssertTrue(note.waitForExistence(timeout: 10), "The image note did not arrive in the band.")
        let words = note.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Image pages are read")).firstMatch
        XCTAssertTrue(words.exists, "The band's note does not read \"Image pages are read…\".")
        let mark = element("noticeFoldedMark")

        // Past a toast's longest stay, the note is still there.
        sleep(12)
        XCTAssertTrue(note.exists || mark.exists, "The image note left by time.")

        // A Search opened and closed over it leaves it in place.
        let search = element("searchRedact")
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Search is missing.")
        search.tap()
        let dismiss = element("searchDismissButton")
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10), "Search never opened.")
        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 10), "Search did not close.")
        if !note.waitForExistence(timeout: 5), mark.exists {
            mark.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(note.waitForExistence(timeout: 5), "The image note did not stay through a Search.")
        attachScreenshot(named: "image-note-open")

        // Closed with a tap 20 above the close's glyph: gone, and Search again
        // does not bring it back.
        let close = app.buttons["noticeClose"].firstMatch
        XCTAssertTrue(close.exists, "The image note has no close.")
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -20)).tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 5), "A tap 20 above the close's glyph did not close the note.")
        search.tap()
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10), "Search never opened again.")
        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 10), "Search did not close again.")
        XCTAssertFalse(note.waitForExistence(timeout: 3), "The closed image note came back.")
        XCTAssertFalse(mark.exists, "The closed image note came back folded.")
    }
}
