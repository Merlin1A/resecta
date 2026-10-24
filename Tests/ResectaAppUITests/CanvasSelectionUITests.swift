import XCTest

/// The canvas's selection gestures on regions that already exist, driven
/// on the 23-page fixture. The instruments are the page bar's counter
/// ("Page k of N, n regions"), the overflow menu's delete row ("Delete
/// Region", "Delete N Regions", or absent when nothing is selected), the
/// long-press menu's rows, and the Undo button. Points are window-normalized
/// so the suite reads the same on the 390- and 402-point simulators; an open
/// menu is closed by tapping the page bar's counter, a label with no action.
///
/// nonisolated: an XCUITest drives a separate process and touches no
/// @MainActor state.
nonisolated final class CanvasSelectionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 30), "The editor never appeared.")
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // Two boxes side by side on page 1, an empty spot below them on the
    // page, and the canvas gutter below the page.
    private static let boxA = (from: CGVector(dx: 0.25, dy: 0.42), to: CGVector(dx: 0.42, dy: 0.50))
    private static let boxB = (from: CGVector(dx: 0.58, dy: 0.42), to: CGVector(dx: 0.75, dy: 0.50))
    private static let centreA = CGVector(dx: 0.335, dy: 0.46)
    private static let centreB = CGVector(dx: 0.665, dy: 0.46)
    private static let emptyPage = CGVector(dx: 0.5, dy: 0.65)
    private static let gutterBelowPage = CGVector(dx: 0.5, dy: 0.84)

    // MARK: - (i) A whole-page region and the gutter

    func testTapOnTheGutterClearsAWholePageSelection() {
        let mark = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(mark.waitForExistence(timeout: 10))
        mark.tap()
        XCTAssertTrue(waitForRegionCount(1), "Mark Whole Page did not add a region.")
        tap(CGVector(dx: 0.5, dy: 0.45))
        XCTAssertEqual(deleteRow(), "Delete Region", "a tap on the whole-page region selects it")
        tap(Self.gutterBelowPage)
        XCTAssertNil(deleteRow(), "a tap below the page clears the selection")
    }

    // MARK: - (ii) A tap on empty page

    func testTapOnEmptyPageDeselectsUnlessAddToSelectionIsOn() {
        drawTwoBoxes()
        tap(Self.centreA)
        XCTAssertEqual(deleteRow(), "Delete Region")
        tap(Self.emptyPage)
        XCTAssertNil(deleteRow(), "a tap on empty page clears the selection")

        setAddToSelection(on: true)
        tap(Self.centreA)
        tap(Self.emptyPage)
        XCTAssertNotNil(deleteRow(), "with Add to Selection on, a tap on empty page changes nothing")
    }

    // MARK: - (iii) A still tap on a group member

    func testStillTapOnOneOfAPairSelectsOnlyIt() {
        drawTwoBoxes()
        selectAllOnPage()
        XCTAssertEqual(deleteRow(), "Delete 2 Regions")
        tap(Self.centreB)
        XCTAssertEqual(deleteRow(), "Delete Region", "the still tap narrows the pair to the tapped box")
    }

    // MARK: - (iv) The long-press menu on a selection

    func testLongPressMenuOnAPairActsOnThePair() {
        drawTwoBoxes()
        selectAllOnPage()
        hold(Self.centreA)
        XCTAssertTrue(app.buttons["Delete 2 Regions"].waitForExistence(timeout: 5), "the menu deletes the pair")
        XCTAssertTrue(app.buttons["Deselect All"].exists)
        XCTAssertFalse(app.buttons["Duplicate Region"].exists, "no Duplicate on a selection")
        app.buttons["Deselect All"].tap()
        XCTAssertNil(deleteRow(), "Deselect All empties the selection")
        XCTAssertEqual(currentRegionCount(), 2, "and deletes nothing")

        selectAllOnPage()
        hold(Self.centreA)
        let delete = app.buttons["Delete 2 Regions"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(waitForRegionCount(0), "both boxes are deleted at once")
        XCTAssertEqual(app.alerts.count, 0, "no confirmation dialog")
        app.buttons["Undo"].tap()
        XCTAssertTrue(waitForRegionCount(2), "one Undo brings both back")
    }

    // MARK: - (v) A marquee is not an undo step

    func testUndoAfterAMarqueeUndoesTheLastDrawing() {
        drawTwoBoxes()
        setAddToSelection(on: true)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.40))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.53)))
        XCTAssertEqual(deleteRow(), "Delete 2 Regions", "the marquee selects both")
        app.buttons["Undo"].tap()
        XCTAssertTrue(waitForRegionCount(1), "Undo undoes the last drawing, not the marquee")
    }

    // MARK: - (vi) A hold never moves a box

    func testHoldThenDragOnAnUnselectedBoxDoesNotMoveIt() {
        drawTwoBoxes()
        tap(Self.emptyPage)
        let before = screenshotOfBoxB()
        window.coordinate(withNormalizedOffset: Self.centreB).press(
            forDuration: 0.7,
            thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.665, dy: 0.58)),
            withVelocity: .slow,
            thenHoldForDuration: 0.2
        )
        dismissMenus()
        XCTAssertEqual(currentRegionCount(), 2)
        tap(Self.emptyPage)   // unselected again, as in the first screenshot
        XCTAssertEqual(before, screenshotOfBoxB(), "box B did not move")

        hold(Self.centreB)
        XCTAssertTrue(app.buttons["Delete Region"].waitForExistence(timeout: 5)
                      || app.buttons["Delete 2 Regions"].exists, "a still hold opens the menu")
        dismissMenus()
    }

    // MARK: - (vii) A double tap at zoom

    func testDoubleTapAtZoomKeepsTheSelection() {
        drawTwoBoxes()
        tap(Self.centreA)
        XCTAssertEqual(deleteRow(), "Delete Region")
        let canvas = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Document editor'")).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.pinch(withScale: 2.0, velocity: 1.0)
        sleep(1)
        window.coordinate(withNormalizedOffset: Self.emptyPage).doubleTap()
        sleep(1)
        XCTAssertNotNil(deleteRow(), "the double tap returns to fit and keeps the selection")
    }
}

// MARK: - Helpers

private extension CanvasSelectionUITests {

    nonisolated var window: XCUIElement { app.windows.firstMatch }

    /// A tap, then a pause past the double-tap window so the canvas's single
    /// tap (which waits for the double tap to fail) has landed.
    nonisolated func tap(_ point: CGVector) {
        window.coordinate(withNormalizedOffset: point).tap()
        usleep(700_000)
    }

    nonisolated func hold(_ point: CGVector) {
        window.coordinate(withNormalizedOffset: point).press(forDuration: 0.8)
    }

    nonisolated var counter: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "pageNavCounter").firstMatch
    }

    /// Close an open overflow or long-press menu on the page bar's counter.
    nonisolated func dismissMenus() {
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "The page bar's counter never appeared.")
        counter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        usleep(500_000)
    }

    nonisolated func drawTwoBoxes() {
        enterDrawMode()
        for box in [Self.boxA, Self.boxB] {
            window.coordinate(withNormalizedOffset: box.from).press(
                forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: box.to),
                withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        leaveDrawMode()
        XCTAssertTrue(waitForRegionCount(2), "the two boxes did not draw; the counter read \(currentRegionCount())")
    }

    nonisolated func enterDrawMode() { setDrawTool(value: "Drawing mode active") }
    nonisolated func leaveDrawMode() { setDrawTool(value: "Tap to enter drawing mode") }

    nonisolated func setDrawTool(value: String) {
        let tool = app.buttons["drawTool"]
        XCTAssertTrue(tool.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            tool.tap()
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if (tool.value as? String) == value { return }
                usleep(250_000)
            }
        }
        XCTFail("The Rectangle tool never read \(value).")
    }

    /// The overflow menu's delete row's label, or nil when it offers none.
    nonisolated func deleteRow() -> String? {
        openOverflow()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete'")).firstMatch
        let label = row.waitForExistence(timeout: 2) ? row.label : nil
        dismissMenus()
        return label
    }

    nonisolated func openOverflow() {
        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "Toolbar overflow button never appeared.")
        overflow.tap()
        XCTAssertTrue(app.buttons["Select Regions"].waitForExistence(timeout: 5)
                      || app.buttons["Home"].waitForExistence(timeout: 1), "the overflow menu did not open")
    }

    nonisolated func selectAllOnPage() {
        openOverflow()
        app.buttons["Select Regions"].tap()
        let row = app.buttons["Select All on Page"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        usleep(500_000)
    }

    /// Set Add to Selection by its row's checkmark; the row is a toggle.
    nonisolated func setAddToSelection(on: Bool) {
        openOverflow()
        let row = app.buttons["Add to Selection"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let isOn = (row.value as? String).map { $0.hasPrefix("On") || $0 == "1" } ?? row.isSelected
        if isOn != on { row.tap() }
        dismissMenus()
    }

    nonisolated func currentRegionCount() -> Int {
        guard counter.waitForExistence(timeout: 5) else { return -1 }
        let label = counter.label
        guard let match = label.range(of: #"(\d+) regions?"#, options: .regularExpression) else { return 0 }
        return Int(label[match].split(separator: " ").first ?? "") ?? -1
    }

    nonisolated func waitForRegionCount(_ count: Int, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentRegionCount() == count { return true }
            usleep(250_000)
        }
        return currentRegionCount() == count
    }

    /// The pixels of box B's area, to tell a moved box from one that stayed.
    nonisolated func screenshotOfBoxB() -> Data {
        let shot = window.screenshot().image
        let scale = shot.scale
        let size = shot.size
        let rect = CGRect(x: 0.56 * size.width * scale, y: 0.40 * size.height * scale,
                          width: 0.21 * size.width * scale, height: 0.12 * size.height * scale)
        guard let cg = shot.cgImage?.cropping(to: rect) else { return Data() }
        return UIImage(cgImage: cg).pngData() ?? Data()
    }
}
