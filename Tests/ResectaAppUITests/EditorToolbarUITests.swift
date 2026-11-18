import XCTest
import UIKit

/// UI tests for the editor's iPhone toolbar: the … menu's order, the one
/// Undo control (a tap undoes; a touch and hold opens Undo and Redo named
/// for their steps), Redact staying available with selected matches not yet
/// applied — a tap raises the search sheet instead of redacting — the Add
/// to Selection capsule's Done, and the delete notice's Undo.
///
/// Launch arguments only; assertions read identifiers and labels.
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class EditorToolbarUITests: XCTestCase {

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

    private var counter: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "pageNavCounter").firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLabel(_ element: XCUIElement, notContaining text: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "NOT (label CONTAINS %@)", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Open the multipage document and mark page 1 so the page has a region.
    private func launchWithOneRegion() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()
        let mark = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(mark.waitForExistence(timeout: 30), "The page bar never appeared.")
        mark.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "1 region"), "Marking the page did not add a region.")
    }

    // MARK: - The … menu's order

    func testOverflowMenu_listsSelectionActionsFirstAndHomeLast() {
        launchWithOneRegion()
        let overflow = app.editorOverflowButton
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "The … menu button is missing.")
        overflow.tap()

        // The page is marked, so the whole-page row reads Unmark.
        let expected = ["Select Regions", "Add to Selection", "Unmark Whole Page", "Switch Mode", "Settings", "Home"]
        var ys: [CGFloat] = []
        for label in expected {
            let row = app.buttons[label].firstMatch.exists ? app.buttons[label].firstMatch
                : app.switches[label].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "The … menu has no '\(label)' row.")
            ys.append(row.frame.midY)
        }
        XCTAssertEqual(ys, ys.sorted(), "The … menu's rows are out of order: \(zip(expected, ys).map { "\($0) \($1)" })")
        XCTAssertFalse(app.buttons["More"].exists && app.buttons["Delete Selected"].exists,
                       "The separate More menu must be gone.")
        attachScreenshot(named: "toolbar-overflow-order")
    }

    // MARK: - The Undo control

    func testUndoControl_tapUndoesAndHoldNamesTheSteps() {
        launchWithOneRegion()
        let undo = app.buttons["undoButton"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "The Undo control is missing from the bar.")

        undo.press(forDuration: 0.8)
        let undoRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Undo '")).firstMatch
        XCTAssertTrue(undoRow.waitForExistence(timeout: 5), "A touch and hold must open the Undo menu with the step's name.")
        attachScreenshot(named: "toolbar-undo-menu")
        undoRow.tap()
        XCTAssertTrue(waitForLabel(counter, notContaining: "1 region"), "The menu's Undo row must undo the mark.")

        undo.press(forDuration: 0.8)
        let redoRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Redo '")).firstMatch
        XCTAssertTrue(redoRow.waitForExistence(timeout: 5), "With a step to redo, the menu must offer Redo with its name.")
        redoRow.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "1 region"), "Redo must bring the region back.")

        undo.tap()
        XCTAssertTrue(waitForLabel(counter, notContaining: "1 region"), "A tap on Undo must undo at once.")
    }

    // MARK: - Redact with unapplied matches

    func testRedact_withUnappliedMatches_raisesTheSheetInsteadOfRedacting() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
        app.launch()
        let selectAll = app.buttons["footerSelectAllButton"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        selectAll.tap()
        let next = app.buttons["resultNavNext"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        let strip = app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "The walk did not park the sheet.")

        // A region of the user's own, so only the selections stand in the
        // way: from the … menu, as the page bar steps aside while parked.
        openOverflowAndTap("Mark Whole Page")

        let redact = app.buttons["redactButton"].firstMatch
        XCTAssertTrue(redact.waitForExistence(timeout: 10), "Redact is missing from the bar.")
        XCTAssertTrue(redact.isEnabled, "Unapplied matches must not grey Redact out.")
        redact.tap()
        XCTAssertTrue(app.buttons["searchDismissButton"].waitForExistence(timeout: 10),
                      "A tap on Redact with unapplied matches must raise the sheet.")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "verificationResults").firstMatch.exists,
                       "Redact must not run without the selected matches.")
        attachScreenshot(named: "toolbar-redact-explains")
    }

    // MARK: - Add to Selection's capsule

    private func openOverflowAndTap(_ label: String) {
        let overflow = app.editorOverflowButton
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "The … menu button is missing.")
        overflow.tap()
        let row = app.buttons[label].firstMatch.exists ? app.buttons[label].firstMatch : app.switches[label].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The … menu has no '\(label)' row.")
        row.tap()
    }

    func testAddToSelection_capsuleShowsAndDoneEndsTheMode() {
        launchWithOneRegion()
        openOverflowAndTap("Add to Selection")
        let capsule = app.descendants(matching: .any).matching(identifier: "addModeCapsule").firstMatch
        XCTAssertTrue(capsule.waitForExistence(timeout: 5), "Add to Selection must show its capsule.")
        attachScreenshot(named: "toolbar-add-capsule")
        app.buttons["addModeDoneButton"].firstMatch.tap()
        XCTAssertTrue(capsule.waitForNonExistence(timeout: 5), "Done must end Add to Selection and its capsule.")
    }

    func testAddToSelection_doneAnswersAboveItsWord() {
        launchWithOneRegion()
        openOverflowAndTap("Add to Selection")
        let slot = app.descendants(matching: .any).matching(identifier: "addModeCapsule").firstMatch
        XCTAssertTrue(slot.waitForExistence(timeout: 5), "Add to Selection must show its words in the slot.")
        // The slot's glass foot is 8 pt above the page bar's glass, whose top
        // is 8 pt above the bar's reported frame (its padding). The slot's
        // element reports its words and Done's 44 pt hit area, not its glass:
        // the foot is the words' foot plus the slot's 12 pt of padding.
        let bar = app.descendants(matching: .any).matching(identifier: "pageNav").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "The page bar is missing.")
        let gap = (bar.frame.minY - 8) - DrawToolStateUITests.slotGlassFoot(slot)
        XCTAssertEqual(gap, 8, accuracy: 1, "The slot's foot must be 8 pt above the page bar's glass; the gap is \(gap) pt.")
        attachScreenshot(named: "toolbar-add-in-the-slot")
        let done = app.buttons["addModeDoneButton"].firstMatch
        XCTAssertTrue(done.exists, "Done is missing.")
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -20)).tap()
        XCTAssertTrue(slot.waitForNonExistence(timeout: 5), "A tap 20 pt above Done's word must end Add to Selection.")
    }

    // MARK: - The delete notice

    func testDeleteTwoRegions_noticeUndoRestoresThem() {
        launchWithOneRegion()
        // A second region, drawn.
        let draw = app.buttons["drawTool"].firstMatch
        XCTAssertTrue(draw.waitForExistence(timeout: 10))
        draw.tap()
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.40))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)))
        draw.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "2 regions"), "The drawn box did not count.")

        openOverflowAndTap("Select Regions")
        let selectAll = app.buttons["Select All on Page"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        openOverflowAndTap("Delete 2 Regions")
        XCTAssertTrue(waitForLabel(counter, containing: "0 regions"), "Both regions must go at once.")
        let notice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Deleted 2 regions.'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "Deleting two must show the notice.")
        attachScreenshot(named: "toolbar-delete-notice")
        // The notice's button speaks as "Undo action" (ToastView).
        let undo = app.buttons["Undo action"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "The notice must offer Undo.")
        undo.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "2 regions"), "The notice's Undo must restore both.")
    }

    // MARK: - The selection bar

    private func barPart(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The page's region count, read from the counter's label.
    private func regionCount() -> Int {
        let label = counter.label
        guard let match = label.range(of: #"(\d+) regions?"#, options: .regularExpression) else { return 0 }
        return Int(label[match].split(separator: " ").first ?? "") ?? -1
    }

    /// One box drawn and selected by a tap on it.
    private func launchWithOneDrawnBoxSelected(textSize: String? = nil) {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
            + (textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        app.launch()
        let mark = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(mark.waitForExistence(timeout: 30), "The page bar never appeared.")
        if textSize != nil {
            XCTAssertGreaterThan(counter.frame.height, 40, "The text size \(textSize ?? "") did not take.")
            // At the largest sizes the import's "Text layer detected" toast covers
            // most of the page and takes the drag: draw once it has gone.
            let toast = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Text layer detected")).firstMatch
            XCTAssertTrue(toast.waitForNonExistence(timeout: 20), "The import toast never cleared off the page.")
        }
        let draw = app.buttons["drawTool"].firstMatch
        XCTAssertTrue(draw.waitForExistence(timeout: 10))
        draw.tap()
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.40))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)))
        draw.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "1 region"), "The drawn box did not count.")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.425)).tap()
        XCTAssertTrue(barPart("selectionBar").waitForExistence(timeout: 5), "Selecting the box must show the selection bar.")
    }

    func testSelectionBar_deleteTwoShowsTheMessageWithUndo() {
        launchWithOneRegion()
        let draw = app.buttons["drawTool"].firstMatch
        XCTAssertTrue(draw.waitForExistence(timeout: 10))
        draw.tap()
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.40))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)))
        draw.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "2 regions"), "The drawn box did not count.")
        openOverflowAndTap("Select Regions")
        let selectAll = app.buttons["Select All on Page"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        XCTAssertTrue(barPart("selectionBar").waitForExistence(timeout: 5), "Two selected must show the selection bar.")
        XCTAssertEqual(barPart("selectionBarCount").label, "Selection, 2 boxes")
        XCTAssertTrue(barPart("selectionBarDuplicate").exists, "Duplicate is dimmed, never removed.")
        XCTAssertFalse(barPart("selectionBarDuplicate").isEnabled, "Two boxes cannot be duplicated, as in the hold menu.")
        attachScreenshot(named: "selection-bar-two-selected")
        barPart("selectionBarDelete").tap()
        XCTAssertTrue(waitForLabel(counter, containing: "0 regions"), "The bar's Delete must remove both at once.")
        let notice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Deleted 2 regions.'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "Deleting two from the bar must show the notice.")
        let undo = app.buttons["Undo action"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "The notice must offer Undo.")
        undo.tap()
        XCTAssertTrue(waitForLabel(counter, containing: "2 regions"), "The notice's Undo must restore both.")
    }

    func testSelectionBar_hitFramesAtTheDefaultSize() {
        launchWithOneDrawnBoxSelected()
        let undo = app.buttons["undoButton"].firstMatch
        /// A tap `dy` points from the centre of a part, then the count's change.
        func tapChanges(_ identifier: String, dy: CGFloat, dx: CGFloat = 0) -> Int {
            let before = regionCount()
            let part = barPart(identifier)
            XCTAssertTrue(part.waitForExistence(timeout: 5), "\(identifier) is missing.")
            part.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: dx, dy: dy)).tap()
            usleep(800_000)
            return regionCount() - before
        }
        XCTContext.runActivity(named: "frames: Duplicate \(barPart("selectionBarDuplicate").frame), Delete \(barPart("selectionBarDelete").frame)") { _ in }
        for dy: CGFloat in [-21, 21] {
            XCTAssertEqual(tapChanges("selectionBarDuplicate", dy: dy), 1, "A tap \(dy) pt from Duplicate's word must duplicate.")
            undo.tap()
            XCTAssertTrue(waitForLabel(counter, containing: "1 region"))
            // The copy was the one selected; Undo removes it, so nothing is
            // selected and the bar leaves. Select the box again.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.425)).tap()
            XCTAssertTrue(barPart("selectionBar").waitForExistence(timeout: 5))
            XCTAssertEqual(tapChanges("selectionBarDelete", dy: dy), -1, "A tap \(dy) pt from Delete's word must delete.")
            undo.tap()
            XCTAssertTrue(waitForLabel(counter, containing: "1 region"))
            XCTAssertTrue(barPart("selectionBar").waitForExistence(timeout: 5))
        }
        // Midway between the two words: exactly one of the two.
        let duplicate = barPart("selectionBarDuplicate").frame, delete = barPart("selectionBarDelete").frame
        let midway = (duplicate.midX + delete.midX) / 2 - duplicate.midX
        let change = tapChanges("selectionBarDuplicate", dy: 0, dx: midway)
        XCTAssertTrue(change == 1 || change == -1, "A tap between the words must run exactly one action; the count changed by \(change).")
        undo.tap()
        // Done, with Add to Selection on.
        openOverflowAndTap("Add to Selection")
        let capsule = barPart("addModeCapsule")
        XCTAssertTrue(capsule.waitForExistence(timeout: 5), "Add to Selection must show its capsule.")
        for dy: CGFloat in [-21, 21] {
            barPart("addModeDoneButton").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: dy)).tap()
            XCTAssertTrue(capsule.waitForNonExistence(timeout: 5), "A tap \(dy) pt from Done's word must end Add to Selection.")
            if dy < 0 {
                openOverflowAndTap("Add to Selection")
                XCTAssertTrue(capsule.waitForExistence(timeout: 5))
            }
        }
    }

    /// The bar's words show whole at the default size: each part is at least
    /// as wide as its words set in the bar's font, and Duplicate's teal ink
    /// is as wide as its word. A part's frame can stay wide while the word
    /// inside it is offered less and drawn cut short ("Dupli…"), so the ink
    /// is read from the screen, not from the frame.
    func testSelectionBar_wordsShowWholeAtTheDefaultSize() throws {
        launchWithOneDrawnBoxSelected()
        let pointSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        func width(_ words: String, _ font: UIFont) -> CGFloat {
            ceil((words as NSString).size(withAttributes: [.font: font]).width)
        }
        let parts: [(String, String, UIFont)] = [
            ("selectionBarCount", "1 selected", .monospacedDigitSystemFont(ofSize: pointSize, weight: .regular)),
            ("selectionBarDuplicate", "Duplicate", .systemFont(ofSize: pointSize, weight: .semibold)),
            ("selectionBarDelete", "Delete", .systemFont(ofSize: pointSize, weight: .semibold)),
        ]
        for (identifier, words, font) in parts {
            let part = barPart(identifier)
            XCTAssertTrue(part.waitForExistence(timeout: 5), "\(identifier) is missing.")
            XCTAssertGreaterThanOrEqual(part.frame.width, width(words, font) - 1,
                "\"\(words)\" is cut short: its part is \(part.frame.width) pt wide, the words \(width(words, font)) pt.")
        }
        // Duplicate's word is drawn in the brand teal: its ink, a few points
        // narrower than its set width for the letters' side bearings, and
        // about 24 pt narrower when the word is cut short.
        let duplicate = barPart("selectionBarDuplicate")
        let probe = try XCTUnwrap(CanvasPixelProbe(XCUIScreen.main.screenshot(), windowSize: app.windows.firstMatch.frame.size))
        let ink = try XCTUnwrap(probe.tintBounds(.teal, in: duplicate.frame), "No teal ink inside Duplicate's part.")
        let set = width("Duplicate", .systemFont(ofSize: pointSize, weight: .semibold))
        XCTAssertGreaterThanOrEqual(ink.width, set - 4,
            "\"Duplicate\" is drawn cut short: its teal ink is \(ink.width) pt wide, the word \(set) pt.")
    }

    func testSelectionBar_atAccessibilityOneAndTheLargestSize_holdsItsCeiling() {
        var barFrames: [CGRect] = []
        for size in ["UICTContentSizeCategoryAccessibilityM", "UICTContentSizeCategoryAccessibilityXXXL"] {
            if !barFrames.isEmpty { app.terminate() }
            launchWithOneDrawnBoxSelected(textSize: size)
            let duplicate = barPart("selectionBarDuplicate"), delete = barPart("selectionBarDelete")
            XCTAssertTrue(duplicate.waitForExistence(timeout: 5) && delete.exists, "Both actions must show at \(size).")
            for (name, part) in [("Duplicate", duplicate), ("Delete", delete)] {
                XCTAssertGreaterThanOrEqual(part.frame.width, 45.5, "\(name)'s frame is \(part.frame) at \(size).")
                XCTAssertGreaterThanOrEqual(part.frame.height, 45.5, "\(name)'s frame is \(part.frame) at \(size).")
            }
            XCTAssertFalse(duplicate.frame.insetBy(dx: 0.5, dy: 0.5).intersects(delete.frame), "The two frames must not overlap at \(size).")
            XCTAssertEqual(duplicate.label, "Duplicate Box")
            XCTAssertEqual(delete.label, "Delete Box")
            // At the accessibility sizes the bar's element reports its glass
            // (272.7 x 54 at both sizes on the 402-pt phone). Its foot
            // is 8 pt above the page bar's glass, which grows with the text.
            let bar = barPart("selectionBar").frame
            let foot = (barPart("pageNav").frame.minY - 8) - bar.maxY
            XCTAssertEqual(foot, 8, accuracy: 1, "At \(size) the bar's foot must be 8 pt above the page bar's glass; it is \(foot) pt.")
            barFrames.append(bar)
            attachScreenshot(named: "selection-bar-\(size)")
        }
        XCTAssertEqual(barFrames[0].width, barFrames[1].width, accuracy: 1, "The bar must stop growing at Accessibility 1: \(barFrames).")
        XCTAssertEqual(barFrames[0].height, barFrames[1].height, accuracy: 1, "The bar must stop growing at Accessibility 1: \(barFrames).")
    }
}
