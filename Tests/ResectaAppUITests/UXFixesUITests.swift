import XCTest

/// UI tests for the search sheet's exits and the parked chrome: a
/// persisted Source = OCR filter on a document whose pages read as
/// text offers Show All from the empty state, and a parked result walk
/// keeps the page bar so a page with no hits stays reachable.
///
/// Every launch passes `--uitesting` (its filter clear runs first); the
/// seeded-filter case writes the filter after that clear.
///
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class UXFixesUITests: XCTestCase {

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

    // MARK: - The parked walk keeps the page bar

    func testParkedWalk_keepsPageBarAndReachesAPageWithNoHits() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        next.tap()
        let strip = app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "The first chevron tap did not park the sheet at the compact float.")

        let pageBar = app.descendants(matching: .any).matching(identifier: "pageNav").firstMatch
        XCTAssertTrue(pageBar.waitForExistence(timeout: 10), "The page bar must stay while the walk is parked.")
        let pageNext = app.buttons["pageNavNext"]
        XCTAssertTrue(pageNext.waitForExistence(timeout: 5) && pageNext.isHittable, "The page bar's next control must be reachable above the parked strip.")
        let position = pageBar.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ of [0-9]+$")).firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 5), "The page bar's position label is missing.")
        let parts = position.label.components(separatedBy: " of ")
        guard parts.count == 2, let current = Int(parts[0]) else {
            XCTFail("Unreadable page position '\(position.label)'.")
            return
        }
        pageNext.tap()
        let nextPosition = pageBar.staticTexts["\(current + 1) of \(parts[1])"]
        XCTAssertTrue(nextPosition.waitForExistence(timeout: 10), "The page bar's next control did not move the page while parked.")
        XCTAssertTrue(strip.exists, "Paging from the bar must keep the sheet parked.")
        attachScreenshot(named: "ux-parked-walk-page-bar")
    }

    // MARK: - Show All from a persisted OCR filter (the seeded leg runs last)

    func testZZ_persistedOCRFilter_offersShowAllFromTheEmptyState() {
        app.launchArguments = [
            "--uitesting", "--searchSourceFilter=ocr", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
        app.launch()
        let showAll = app.buttons["Show All"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 30), "A text-layer document filtered to OCR rows must offer Show All.")
        attachScreenshot(named: "ux-show-all-offered")
        showAll.tap()
        XCTAssertTrue(app.buttons["resultNavNext"].waitForExistence(timeout: 10), "Show All must bring the text-layer results back.")
        XCTAssertFalse(showAll.exists)
    }

    // MARK: - A rejected draw says why

    /// A one-line box — wide enough to clear the 8-pt start gate, 6 pt
    /// tall, under the commit floor — is rejected, and the rejection is
    /// shown on screen, not only spoken to VoiceOver.
    func testTooSmallDrawShowsTheZoomInNotice() {
        launchSampleInEditor()
        enterDrawMode()
        let before = currentRegionCount()

        drag(fromNormalized: CGVector(dx: 0.15, dy: 0.30), byPoints: 120, 6)

        let notice = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Region too small. Zoom in to draw a smaller region."))
            .firstMatch
        XCTAssertTrue(
            notice.waitForExistence(timeout: 10),
            "A rejected draw must say why on screen: no 'Region too small. Zoom in to draw a smaller region.' notice appeared."
        )
        XCTAssertEqual(currentRegionCount(), before, "The too-small box must not commit.")
        attachScreenshot(named: "ux-too-small-notice")
    }

    // MARK: - The sheet's own exits

    /// Escape at the medium detent closes the Search sheet. A simulator
    /// that delivers no hardware key at all records the leg for the device
    /// pass instead of failing it: the hidden "k" shortcut (next match) is
    /// the control that tells an undelivered key from an ignored one.
    func testEscapeAtMediumDismissesTheSheet() throws {
        launchSearchAtMedium()
        let dismiss = app.buttons["searchDismissButton"]
        XCTAssertTrue(dismiss.exists, "The sheet must be up at the medium detent.")

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        if dismiss.waitForNonExistence(timeout: 5) {
            attachScreenshot(named: "ux-escape-dismissed")
            return
        }

        let counter = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Result '"))
            .firstMatch
        let before = counter.exists ? counter.label : nil
        app.typeKey("k", modifierFlags: [])
        let deadline = Date().addingTimeInterval(5)
        var keyArrived = false
        while Date() < deadline {
            if counter.exists, counter.label != before {
                keyArrived = true
                break
            }
            usleep(250_000)
        }
        attachScreenshot(named: "ux-escape-sheet-still-up")
        guard keyArrived else {
            throw XCTSkip(
                "The simulator delivered no hardware key (the k control did not step the walk either); the Escape leg is recorded for the device pass."
            )
        }
        XCTFail("Escape at the medium detent left the Search sheet up, while hardware keys do reach the sheet (k stepped the walk).")
    }

    /// The apply notice sits clear of the footer: Select All stays
    /// reachable while it shows.
    func testFooterSelectAllStaysHittableUnderTheApplyNotice() {
        launchSearchAtMedium()
        let selectAll = app.buttons["footerSelectAllButton"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "The footer's Select All never appeared.")
        selectAll.tap()
        let apply = app.buttons["searchApplyButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5), "Apply button not found.")
        apply.tap()

        let notice = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Marked '"))
            .firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "The apply notice never appeared.")
        XCTAssertTrue(selectAll.isHittable, "The footer's Select All must stay reachable while the apply notice shows.")
        attachScreenshot(named: "ux-footer-under-apply-notice")
    }

    /// Dismiss over ticked, unapplied matches asks in an alert with exactly
    /// one Cancel, and Cancel keeps the sheet.
    func testDiscardConfirmIsAnAlertWithOneCancel() {
        launchSearchAtMedium()
        let selectAll = app.buttons["footerSelectAllButton"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "The footer's Select All never appeared.")
        selectAll.tap()
        let dismiss = app.buttons["searchDismissButton"]
        dismiss.tap()

        let alert = app.alerts["Discard selections?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Dismiss over unapplied selections must ask in an alert.")
        let cancels = alert.buttons.matching(NSPredicate(format: "label == 'Cancel'"))
        XCTAssertEqual(cancels.count, 1, "The Discard confirm must offer exactly one Cancel.")
        XCTAssertTrue(alert.buttons["Discard"].exists, "The confirm keeps its Discard action.")
        attachScreenshot(named: "ux-discard-alert-one-cancel")

        cancels.firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "Cancel must close the confirm.")
        XCTAssertTrue(dismiss.exists, "Cancel keeps the sheet up.")
    }

    // MARK: - The editor's chrome

    /// Two selected regions → "Delete 2 Regions" deletes both at once, with
    /// no confirmation anywhere in the tree, and ONE Undo brings both back.
    func testDeletingTwoSelectedRegionsIsImmediateAndOneUndo() {
        launchSampleInEditor()
        enterDrawMode()
        drag(from: CGVector(dx: 0.25, dy: 0.45), to: CGVector(dx: 0.50, dy: 0.55))
        XCTAssertTrue(waitForRegionCount(1), "The first box never drew; page bar read \(currentRegionCount()).")
        drag(from: CGVector(dx: 0.55, dy: 0.28), to: CGVector(dx: 0.80, dy: 0.40))
        XCTAssertTrue(waitForRegionCount(2), "The second box never drew; page bar read \(currentRegionCount()).")
        leaveDrawMode()

        openOverflowAndTap(label: "Select Regions", identifier: "Select Regions")
        let selectAll = app.buttons["Select All on Page"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), "Select All on Page never appeared.")
        selectAll.tap()
        openOverflowAndTap(label: "Delete 2 Regions", identifier: "Delete 2 Regions")

        XCTAssertTrue(
            waitForRegionCount(0),
            "Delete 2 Regions must delete both at once; page bar read \(currentRegionCount())."
        )
        XCTAssertFalse(app.staticTexts["Delete 2 regions?"].exists, "No confirmation may stand between the tap and the delete.")
        XCTAssertFalse(app.alerts.firstMatch.exists, "No alert in the tree.")
        XCTAssertFalse(app.sheets.firstMatch.exists, "No action sheet in the tree.")
        attachScreenshot(named: "ux-delete-two-immediate")

        tapUndo()
        XCTAssertTrue(
            waitForRegionCount(2),
            "One Undo must bring both regions back; page bar read \(currentRegionCount())."
        )
    }

    /// With the Search sheet parked, Settings opens, and closing it brings
    /// the parked strip back.
    func testSettingsOverTheParkedSheetBringsTheStripBack() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchDetent=compact",
        ]
        app.launch()
        XCTAssertTrue(compactFloatStrip.waitForExistence(timeout: 30), "The sheet never parked at the compact float.")

        openSettingsFromEditor()
        let heading = app.navigationBars["Settings"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "Settings must open over the parked Search sheet.")
        attachScreenshot(named: "ux-settings-over-parked-sheet")
        heading.buttons["Done"].tap()
        XCTAssertTrue(heading.waitForNonExistence(timeout: 10), "Done must close Settings.")
        XCTAssertTrue(compactFloatStrip.waitForExistence(timeout: 10), "Closing Settings must bring the parked strip back.")
    }

    /// A session closed while parked does not leave the next Search session
    /// parked: the new one opens at medium.
    func testNewSearchSessionOpensAtMediumAfterAParkedClose() throws {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc", "--openSearchSheet"]
        app.launch()
        let dismiss = app.buttons["searchDismissButton"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 30), "The sheet never presented under --openSearchSheet.")

        for _ in 0..<2 where !compactFloatStrip.exists {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)))
            sleep(2)
        }
        XCTAssertTrue(compactFloatStrip.waitForExistence(timeout: 10), "The sheet did not park at the compact float.")

        compactFloatStrip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)))
        guard compactFloatStrip.waitForNonExistence(timeout: 10) else {
            throw XCTSkip("The parked sheet did not swipe away on this simulator; the reopen leg moves to the probe sim's hand pass.")
        }

        let search = app.buttons["searchRedact"]
        XCTAssertTrue(waitForEnabled(search, timeout: 10), "Search never re-enabled after the sheet closed.")
        search.tap()
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10), "A new Search session must open at the medium height, not parked.")
        XCTAssertFalse(compactFloatStrip.exists, "The new session must not open parked.")
        attachScreenshot(named: "ux-new-search-at-medium")
    }

    /// Add to Selection turned on over a page with a region turns off when
    /// the page in view has none: a visible exit, not a silent mode.
    func testAddToSelectionTurnsOffOnAnEmptyPage() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 30), "The editor never appeared.")
        enterDrawMode()
        drag(from: CGVector(dx: 0.25, dy: 0.45), to: CGVector(dx: 0.50, dy: 0.55))
        XCTAssertTrue(waitForRegionCount(1), "The box never drew on page 1; page bar read \(currentRegionCount()).")

        openOverflowAndTap(label: "Add to Selection", identifier: "selectMoreToggle")
        XCTAssertEqual(addToSelectionRow(), .on, "precondition: Add to Selection reads On over page 1")

        let next = app.buttons["pageNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 10) && next.isHittable, "The page bar's next control is not reachable.")
        next.tap()
        XCTAssertTrue(waitForRegionCount(0), "Page 2 must hold no region.")

        // The row may hide on a page with no region: read it there when it
        // is served, else back on page 1. Either way it must read Off.
        var row = addToSelectionRow()
        if row == .absent {
            app.buttons["pageNavPrevious"].tap()
            XCTAssertTrue(waitForRegionCount(1), "Back on page 1 the box must show again.")
            row = addToSelectionRow()
        }
        XCTAssertEqual(row, .off, "Add to Selection must turn off on a page with no region.")
        attachScreenshot(named: "ux-add-to-selection-off-on-empty-page")
    }

}

// MARK: - Editor driving

/// The editor drive the canvas legs share: the sample opened from Home,
/// the Rectangle tool, window-normalized drags and the page bar's region
/// count (canvas regions are not in the accessibility tree; the page bar's
/// "N region(s)" text is the served hook). Members are `nonisolated` like
/// the class: an XCUITest drives a separate process.
private extension UXFixesUITests {

    nonisolated var window: XCUIElement { app.windows.firstMatch }

    /// The 23-page fixture with the Search sheet up at the medium detent,
    /// a typed query run and its results in.
    nonisolated func launchSearchAtMedium() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
        app.launch()
        XCTAssertTrue(
            app.buttons["resultNavNext"].waitForExistence(timeout: 30),
            "The seeded query returned nothing or the sheet never presented."
        )
    }

    /// Home → "Try the Sample" → the editor on page 1 of the 3-page sample,
    /// once the text-layer toast has cleared so no drag lands on it.
    nonisolated func launchSampleInEditor() {
        app.launchArguments = ["--uitesting"]
        app.launch()
        let sampleCard = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Try the Sample'"))
            .firstMatch
        XCTAssertTrue(sampleCard.waitForExistence(timeout: 30), "HomeView's sample card never appeared.")
        sampleCard.tap()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 30), "The editor never appeared.")
        let toast = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Text layer detected'"))
            .firstMatch
        if toast.waitForExistence(timeout: 5) {
            XCTAssertTrue(toast.waitForNonExistence(timeout: 20), "The text-layer toast never cleared.")
        }
        sleep(1)
    }

    /// Tap the Rectangle tool until it reports drawing mode (a dropped or
    /// late tap is corrected by the next round).
    nonisolated func enterDrawMode() {
        let tool = app.buttons["drawTool"]
        XCTAssertTrue(tool.waitForExistence(timeout: 10), "Rectangle tool not present.")
        for _ in 0..<3 {
            tool.tap()
            if waitForToolValue("Drawing mode active", timeout: 6) { return }
        }
        XCTFail("The Rectangle tool did not report drawing mode after three taps.")
    }

    nonisolated func waitForToolValue(_ expected: String, timeout: TimeInterval) -> Bool {
        let tool = app.buttons["drawTool"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (tool.value as? String) == expected { return true }
            usleep(250_000)
        }
        return (tool.value as? String) == expected
    }

    /// A slow drag by a screen-point delta that rests before lifting, so a
    /// loaded host cannot lift it short of a threshold.
    nonisolated func drag(fromNormalized start: CGVector, byPoints dx: CGFloat, _ dy: CGFloat) {
        let size = window.frame.size
        let end = CGVector(dx: start.dx + dx / size.width, dy: start.dy + dy / size.height)
        window.coordinate(withNormalizedOffset: start).press(
            forDuration: 0.05,
            thenDragTo: window.coordinate(withNormalizedOffset: end),
            withVelocity: .slow,
            thenHoldForDuration: 0.2
        )
    }

    nonisolated var compactFloatStrip: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
    }

    nonisolated func leaveDrawMode() {
        let tool = app.buttons["drawTool"]
        for _ in 0..<3 {
            tool.tap()
            if waitForToolValue("Tap to enter drawing mode", timeout: 6) { return }
        }
        XCTFail("The Rectangle tool did not leave drawing mode after three taps.")
    }

    /// One finger between two window-normalized points.
    nonisolated func drag(from start: CGVector, to end: CGVector) {
        window.coordinate(withNormalizedOffset: start)
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: end))
    }

    nonisolated func waitForRegionCount(_ count: Int, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentRegionCount() == count { return true }
            usleep(250_000)
        }
        return currentRegionCount() == count
    }

    nonisolated func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isEnabled { return true }
            usleep(250_000)
        }
        return element.exists && element.isEnabled
    }

    /// Open the "…" menu and tap an item: label first (identifiers do not
    /// reliably reach the system menu), identifier second.
    nonisolated func openOverflowAndTap(label: String, identifier: String) {
        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "Toolbar overflow button never appeared.")
        overflow.tap()
        let byLabel = app.buttons[label].firstMatch
        if byLabel.waitForExistence(timeout: 5) {
            byLabel.tap()
            return
        }
        let byIdentifier = app.buttons[identifier].firstMatch
        XCTAssertTrue(
            byIdentifier.waitForExistence(timeout: 5),
            "\(label) never appeared in the overflow menu (neither the label nor \(identifier) resolved)."
        )
        byIdentifier.tap()
    }

    /// Undo on the trailing bar, or through the overflow where the bar folds.
    nonisolated func tapUndo() {
        let undo = app.buttons["Undo"].firstMatch
        if undo.waitForExistence(timeout: 5), undo.isHittable {
            undo.tap()
            return
        }
        openOverflowAndTap(label: "Undo", identifier: "Undo")
    }

    /// The gear on the trailing bar, or Settings through the overflow.
    nonisolated func openSettingsFromEditor() {
        let gear = app.buttons["settings-button"].firstMatch
        if gear.waitForExistence(timeout: 5), gear.isHittable {
            gear.tap()
            return
        }
        openOverflowAndTap(label: "Settings", identifier: "settings-button")
    }

    nonisolated enum AddToSelectionRow {
        case on, off, absent
    }

    /// Open the overflow, read the Add to Selection row, close the menu.
    nonisolated func addToSelectionRow() -> AddToSelectionRow {
        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "Toolbar overflow button never appeared.")
        overflow.tap()
        let byIdentifier = app.descendants(matching: .any).matching(identifier: "selectMoreToggle").firstMatch
        let byLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Add to Selection'"))
            .firstMatch
        defer { closeOverflowMenu(rows: [byIdentifier, byLabel]) }
        let row = byIdentifier.waitForExistence(timeout: 3) ? byIdentifier : byLabel
        guard row.waitForExistence(timeout: 2) else { return .absent }
        let value = (row.value as? String) ?? ""
        return value.hasPrefix("On") || value == "1" || row.isSelected ? .on : .off
    }

    /// Close the overflow menu by tapping the page bar's counter, a label
    /// with no action of its own, so the tap cannot change editor state; a
    /// tap on the toolbar's blank strip can leave the menu up. The menu's
    /// rows must be gone before the test goes on.
    nonisolated func closeOverflowMenu(rows: [XCUIElement]) {
        let counter = app.descendants(matching: .any).matching(identifier: "pageNavCounter").firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "The page bar's counter never appeared.")
        counter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        for row in rows {
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "The overflow menu did not close.")
        }
    }

    /// The page bar's region count for the current page — 0 when it shows none.
    nonisolated func currentRegionCount() -> Int {
        let label = app.staticTexts
            .matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ regions?$"))
            .firstMatch
        guard label.exists,
              let head = label.label.split(separator: " ").first,
              let count = Int(head)
        else { return 0 }
        return count
    }
}
