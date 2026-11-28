import XCTest

/// Where brief messages are drawn and how their action answers: the
/// receipt's Undo, the sheet that raised a warning, the place above the
/// page bar, and the size a tall message is drawn at.
nonisolated final class ReceiptPlacementUITests: XCTestCase {

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

    private static let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    private var counter: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "pageNavCounter").firstMatch
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func labelled(_ prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Launches the multipage document. A document's arrival raises no
    /// message, so the next message is the one under test.
    private func launchEditor(_ extra: [String] = []) {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["pageNavMarkWholePage"].waitForExistence(timeout: 30), "The page bar never appeared.")
    }

    /// Two boxes on page 1 (the whole page marked, one drawn), both
    /// selected, deleted from the selection bar: "Deleted 2 regions." with Undo.
    private func deleteTwoBoxes() -> (receipt: XCUIElement, undo: XCUIElement) {
        launchEditor()
        app.buttons["pageNavMarkWholePage"].tap()
        XCTAssertTrue(waitForLabel(counter, containing: "1 region"), "Marking the page did not add a region.")
        let draw = app.buttons["drawTool"].firstMatch
        XCTAssertTrue(draw.waitForExistence(timeout: 10))
        draw.tap()
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.40))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)))
        draw.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "2 regions"), "The drawn box did not count.")
        let overflow = app.editorOverflowButton
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "The … menu button is missing.")
        overflow.tap()
        let selectRegions = app.buttons["Select Regions"].firstMatch
        XCTAssertTrue(selectRegions.waitForExistence(timeout: 5))
        selectRegions.tap()
        let selectAll = app.buttons["Select All on Page"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        let delete = element("selectionBarDelete")
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Two selected must show the selection bar.")
        delete.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "0 regions"), "Both boxes must go at once.")
        let receipt = element("toastMessageWithAction")
        XCTAssertTrue(receipt.waitForExistence(timeout: 8), "Deleting two must show the receipt with its action.")
        let undo = app.buttons["Undo action"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "The receipt must offer Undo.")
        return (receipt, undo)
    }

    // 1
    func testTapBesideUndoLeavesTheUndoOnScreen() {
        let (receipt, undo) = deleteTwoBoxes()
        receipt.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        sleep(1)
        XCTAssertTrue(undo.exists, "A tap on the receipt's words must leave its Undo on screen.")
        let search = app.buttons["searchRedact"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "The Search button is missing.")
        search.tap()
        XCTAssertTrue(app.textFields["Search text"].waitForExistence(timeout: 10), "Search never opened.")
        XCTAssertFalse(element("toastMessageWithAction").exists, "The editor's Undo must not be drawn over Search.")
        // It must be seen, so Search over it pauses it: closing Search
        // brings it back, and the toolbar's Undo still undoes.
        let close = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Search's close is missing.")
        close.tap()
        XCTAssertTrue(app.buttons["Undo action"].firstMatch.waitForExistence(timeout: 10),
                      "The paused Undo receipt did not come back after Search.")
        let toolbarUndo = app.buttons["undoButton"].firstMatch
        XCTAssertTrue(toolbarUndo.waitForExistence(timeout: 5), "The toolbar's Undo is missing.")
        toolbarUndo.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "2 regions"), "The toolbar's Undo did not undo the delete.")
    }

    // 2
    func testUndoAnswersAcrossTheReceiptsHeightFromBeforeItsPill() {
        let (receipt, undo) = deleteTwoBoxes()
        XCTContext.runActivity(named: "frames: receipt \(receipt.frame), Undo \(undo.frame)") { _ in }
        XCTAssertGreaterThanOrEqual(undo.frame.height, 45, "Undo's frame is \(undo.frame.height) pt high.")
        XCTAssertEqual(undo.frame.maxX, receipt.frame.maxX, accuracy: 1, "Undo's frame must run to the receipt's trailing edge.")
        undo.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0)).tap()
        XCTAssertTrue(waitForLabel(counter, containing: "2 regions"), "A tap 2 pt inside Undo's leading edge must undo.")
    }

    // 3
    func testTheReceiptsWordsAndItsUndoAreTwoElements() {
        let (receipt, undo) = deleteTwoBoxes()
        let words = app.staticTexts["Deleted 2 regions."].firstMatch
        XCTAssertTrue(words.exists, "The receipt's words are not their own element.")
        XCTAssertNotEqual(words.frame, undo.frame, "The words and Undo must be two elements.")
        XCTAssertTrue(receipt.frame.contains(words.frame), "The words lie outside the receipt.")
        XCTAssertTrue(receipt.frame.insetBy(dx: -1, dy: -1).contains(undo.frame), "Undo lies outside the receipt.")
    }

    // 4
    func testWarningRaisedWithSearchAtFullHeightIsDrawnInTheSheet() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc",
                               "--openSearchSheet", "--searchQuery=e", "--searchDetent=large"]
        app.launch()
        let warning = labelled("Search results truncated")
        XCTAssertTrue(warning.waitForExistence(timeout: 45), "The truncation warning never showed.")
        // It slides in first. A receipt stays in the layer that drew it, so
        // one drawn under the sheet never becomes hittable.
        let deadline = Date().addingTimeInterval(5)
        while !warning.isHittable, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(warning.isHittable, "The warning is drawn under the sheet.")
        let footer = app.buttons["footerSelectAllButton"].firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "Search's footer is missing.")
        XCTAssertLessThanOrEqual(warning.frame.maxY, footer.frame.minY, "The warning must sit above Search's footer.")
        attachScreenshot(named: "receipt-search-full-height")
    }

    // 5
    func testClosingSearchBySwipeShowsItsNoticeInTheEditor() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc",
                               "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium"]
        app.launch()
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 30), "Search never opened.")
        XCTAssertTrue(app.staticTexts["Page 1"].waitForExistence(timeout: 20), "no results for the fixture's text")
        // Nothing ticked, so the system close is allowed: a drag down off the screen.
        let strip = element("compactFloatStrip")
        let window = app.windows.firstMatch
        var sheetUp: Bool { dismiss.exists || strip.exists }
        for _ in 0..<4 where sheetUp {
            let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: strip.exists ? 0.86 : 0.45))
            top.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995)))
            sleep(1)
        }
        XCTAssertFalse(sheetUp, "A drag down did not close Search.")
        let notice = labelled("Search closed")
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "Closing Search dropped its notice.")
        XCTAssertTrue(notice.isHittable, "The notice is not drawn in the editor.")
    }

    // 6
    func testReceiptSitsAboveTheKeyboardInSearch() throws {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc",
                               "--openSearchSheet", "--searchDetent=large"]
        app.launch()
        let field = app.textFields["Search text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Search never opened.")
        field.tap()
        guard app.keyboards.count > 0 else {
            throw XCTSkip("software keyboard not shown on this simulator")
        }
        field.typeText("Amount")
        XCTAssertTrue(app.staticTexts["Page 1"].waitForExistence(timeout: 20), "no results for the fixture's text")
        app.buttons["footerSelectAllButton"].firstMatch.tap()
        // Return in the field adds a term or runs the search; Apply is the
        // footer's button, tapped with the field focused and the keyboard up.
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard went away.")
        let apply = app.buttons["searchApplyButton"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5) && apply.isHittable, "Apply is not reachable over the keyboard.")
        apply.tap()
        let receipt = labelled("Marked")
        XCTAssertTrue(receipt.waitForExistence(timeout: 10), "Apply showed no receipt.")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists, "The keyboard went away after Apply, so its place was not read.")
        XCTAssertLessThanOrEqual(receipt.frame.maxY, keyboard.frame.minY, "The receipt is under the keyboard.")
        XCTAssertTrue(receipt.isHittable, "The receipt is not drawn in Search.")
    }

    // 7
    func testReceiptInTheEditorSitsEightPointsAboveThePageBar() {
        let (receipt, _) = deleteTwoBoxes()
        let bar = element("pageNav")
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "The page bar is missing.")
        // The bar's element reports its content without its 8 points of padding.
        let gap = (bar.frame.minY - 8) - receipt.frame.maxY
        XCTAssertEqual(gap, 8, accuracy: 2, "The receipt's foot is \(gap) pt above the page bar's glass.")
        attachScreenshot(named: "receipt-editor-undo")
    }

    // 8
    func testTallMessageAtTheLargestSizeIsDrawnSmaller() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc",
                               "--showToast=searchResultsTruncated"] + Self.largest
        app.launch()
        XCTAssertTrue(app.buttons["pageNavMarkWholePage"].waitForExistence(timeout: 30), "The page bar never appeared.")
        XCTAssertGreaterThan(counter.frame.height, 40, "The largest text size did not take.")
        // Read the receipt while its words are the truncation's.
        let words = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Search results truncated")).firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 30), "The truncation message never showed.")
        let receipt = element("toastMessage")
        XCTAssertTrue(receipt.exists && receipt.frame.contains(words.frame), "The truncation's receipt is not the one drawn.")
        let bar = element("pageNav")
        let top = app.navigationBars.firstMatch.frame.maxY
        let space = (bar.frame.minY - 8) - top
        XCTContext.runActivity(named: "receipt \(receipt.frame), space \(space)") { _ in }
        let height = receipt.frame.height
        XCTAssertLessThanOrEqual(height, 0.4 * space + 2, "The message is \(height) pt high in \(space) pt of canvas.")
        // Drawn at the third accessibility size: 215.7 pt at 402 wide, as
        // the receipt's own measure gives it in the hosted tests.
        XCTAssertEqual(height, 215.7, accuracy: 4, "The message is not drawn at the third accessibility size.")
        attachScreenshot(named: "receipt-largest-drawn-smaller")
    }

    // 9
    /// A recall closes the saved list and starts Search's run at once, so
    /// the run's first warning can arrive while the list is still in front.
    /// The warning belongs to Search's run: it is seen on Search after the
    /// list is gone. The image has no text layer, so with Include OCR off
    /// the run raises the scanned-page warning.
    func testWarningOfARecalledSearchIsSeenOnSearch() {
        app.launchArguments = ["--uitesting", "--loadTestImage", "--openSearchSheet", "--searchDetent=large"]
        app.launch()
        let field = app.textFields["Search text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Search never opened.")
        // The image note is drawn in the editor's band, not queued as a
        // message, so it holds back no warning; with Search at its large
        // height the band is hidden.
        let imageNote = labelled("Image pages are read")
        XCTAssertFalse(imageNote.exists && imageNote.isHittable, "The image note shows over Search at its large height.")
        let options = app.buttons["Options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10), "Search's options are missing.")
        options.tap()
        let ocr = app.buttons["Include scanned page text"].firstMatch
        XCTAssertTrue(ocr.waitForExistence(timeout: 5), "The Include OCR Pages chip is missing.")
        if (ocr.value as? String) == "on" { ocr.tap() }
        XCTAssertEqual(ocr.value as? String, "off", "Include OCR Pages did not turn off.")
        field.tap()
        field.typeText("Amount")
        // The first run's own warning shows and ends before the recall, so
        // the recalled run's warning is a new one.
        let warning = labelled("Some pages hold scanned regions")
        XCTAssertTrue(warning.waitForExistence(timeout: 30), "With OCR off the image raised no warning.")
        XCTAssertTrue(warning.waitForNonExistence(timeout: 45), "The first warning never ended.")

        let bookmark = app.buttons["Saved Searches"].firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 10), "The Saved Searches control is missing.")
        bookmark.tap()
        let saveRow = app.buttons["Save current search…"]
        XCTAssertTrue(saveRow.waitForExistence(timeout: 10), "The saved list never opened.")
        let clearAll = app.buttons["savedSearchClearAllButton"]
        if clearAll.waitForExistence(timeout: 2) {
            clearAll.tap()
            let confirm = app.buttons["savedSearchClearAllConfirm"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete All has no confirm.")
            confirm.tap()
            XCTAssertTrue(app.staticTexts["No Saved Searches"].waitForExistence(timeout: 10), "The list did not empty.")
        }
        saveRow.tap()
        let alert = app.alerts["Save current search"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "The save prompt never showed.")
        let name = alert.textFields.firstMatch.value as? String ?? ""
        alert.buttons["Save"].tap()
        let row = app.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The saved search has no row.")
        row.tap()
        XCTAssertTrue(saveRow.waitForNonExistence(timeout: 10), "The recall did not close the saved list.")
        XCTAssertTrue(warning.waitForExistence(timeout: 30), "The recalled run's warning was lost with the saved list.")
        XCTAssertTrue(warning.isHittable, "The recalled run's warning is not drawn on Search.")
        attachScreenshot(named: "receipt-recalled-search-warning")
    }
}
