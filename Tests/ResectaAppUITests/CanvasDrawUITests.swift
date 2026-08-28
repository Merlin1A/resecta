import XCTest

/// The 1.1.0 draw-tool program — the S3 verification
/// battery for the S1 + S2 overlay changes, driven end to end on the
/// real device tree (black-box XCUITest, no `@testable import`):
///
///  - T1 a drag on empty page space draws one box.
///  - T2 a 4-pt drag sits under the 8-pt start gate: nothing commits,
///    the editor stays up.
///  - T3 a drag STARTING INSIDE the first box draws a second one — draw
///    wins while the tool is on.
///  - T4 More › Add to Selection leaves the tool; re-entering the tool
///    clears the toggle and the next drag draws, not a marquee.
///  - T5 zoom: after a pinch a 24 × 24 screen-pt drag commits and a
///    9 × 9 one does not (the commit floor is measured on screen).
///    The pinch is proven through the served count itself: the band
///    beneath the page is off-page at fit and on-page once zoomed, so a
///    drag there commits only after a real zoom. A simulator pinch that
///    never zooms skips the leg with the reason (the device pass and
///    the unit-level `snapZoomScaleOverride` proofs in
///    `DrawWinsTests` carry it).
///  - T6 Undo removes the drawn box.
///  - T7 with the Search sheet parked at the compact
///    float, a drag on the page still draws one box — beneath the float
///    iOS 26's window-level sheet pan cancelled every moving canvas
///    touch (0/6 on the parent tree); the overlay's claim recognizer and
///    failure requirement carry the drag through.
///  - T8 Redact with the sheet parked at the compact
///    float closes the sheet before the run — no float over the results
///    screen — and Keep Editing returns with Search available again.
///
/// Rails: canvas regions are not in the accessibility
/// tree, so every assertion reads the page bar's "N region(s)"
/// text — the one served canvas hook (the bar shows nothing at zero);
/// drags are window-normalized coordinate presses
/// (`press(forDuration:thenDragTo:)`), the only admissible drive on
/// this rig (the MCP swipe/drag tools deliver no touch-move). Geometry:
/// the bundled 3-page Letter sample at fit sits at ≈ x 5–397 /
/// y 190–696 pt on the iPhone 17 (402 × 874) — box drags are placed
/// well inside it. Injected touches can land seconds late on a loaded
/// host (as S1 and S2 recorded), so waits are generous and a leg's
/// baseline draw gets one settle retry, with the count read back rather
/// than assumed (the house R7 idiom).
///
/// nonisolated for the same reason as the sibling suites: an XCUITest
/// drives a separate process and touches no @MainActor app state.
nonisolated final class CanvasDrawUITests: XCTestCase {

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

    // MARK: - Geometry

    /// Box A: a comfortable rectangle in the upper-middle of page 1.
    private let boxAStart = CGVector(dx: 0.25, dy: 0.45)
    private let boxAEnd = CGVector(dx: 0.50, dy: 0.55)

    private var window: XCUIElement { app.windows.firstMatch }

    // MARK: - Tests

    /// T1 — a drag on empty page space draws one box (no retry: one drag,
    /// one box is the leg).
    func testDragOnEmptyPageDrawsOneBox() {
        launchSampleInEditor()
        enterDrawMode()

        drag(from: boxAStart, to: boxAEnd)
        XCTAssertTrue(
            waitForRegionCount(1),
            "A drag on empty page space must draw one box (page bar read \(currentRegionCount()) regions)."
        )
        attachScreenshot(named: "canvasdraw-t1-one-box")
    }

    /// T2 — a sub-threshold drag commits nothing and leaves the editor up.
    func testSubThresholdDragCommitsNothing() {
        launchSampleInEditor()
        enterDrawMode()
        let base = drawBaselineBox("Box A never drew — the sub-threshold leg has no baseline.")

        // 4 pt each way, clear of box A: under the 8-pt start gate.
        drag(fromNormalized: CGVector(dx: 0.70, dy: 0.30), byPoints: 4, 4)
        sleep(2)
        XCTAssertEqual(
            currentRegionCount(), base,
            "A 4-pt drag sits under the 8-pt start gate and must not commit."
        )
        XCTAssertTrue(
            app.buttons["drawTool"].exists,
            "The editor must still be up after a sub-threshold drag."
        )
        attachScreenshot(named: "canvasdraw-t2-subthreshold")
    }

    /// T3 — a drag starting INSIDE an existing box draws a new box (draw wins).
    func testDragStartingInsideABoxDrawsANewBox() {
        launchSampleInEditor()
        enterDrawMode()
        let base = drawBaselineBox("Box A never drew — the draw-wins leg has no baseline.")

        // Start at box A's centre, finish past its far corner.
        drag(from: CGVector(dx: 0.375, dy: 0.50), to: CGVector(dx: 0.62, dy: 0.66))
        XCTAssertTrue(
            waitForRegionCount(base + 1),
            "With the tool on, a drag starting inside an existing box must draw another box — draw wins; page bar read \(currentRegionCount())."
        )
        attachScreenshot(named: "canvasdraw-t3-draw-over-box")
    }

    /// T4 — Add to Selection leaves the tool; re-entering clears the toggle and draws.
    func testAddToSelectionThenToolReentryDraws() {
        launchSampleInEditor()
        enterDrawMode()
        let base = drawBaselineBox("Box A never drew — the toggle row needs a region on the page to mount.")

        openOverflowAndTap(label: "Add to Selection", identifier: "selectMoreToggle")
        XCTAssertTrue(
            waitForToolValue("Tap to enter drawing mode"),
            "Turning Add to Selection on must leave the Rectangle tool (mutual exclusion)."
        )

        enterDrawMode()
        drag(from: CGVector(dx: 0.55, dy: 0.28), to: CGVector(dx: 0.80, dy: 0.40))
        XCTAssertTrue(
            waitForRegionCount(base + 1),
            "After re-entering the tool the drag must draw a box, not run the marquee; page bar read \(currentRegionCount())."
        )
        attachScreenshot(named: "canvasdraw-t4-toggle-roundtrip")
    }

    /// T5 — zoomed thresholds are screen points.
    func testZoomedThresholdsAreScreenPoints() throws {
        launchSampleInEditor()
        enterDrawMode()

        // The band beneath the page: on the iPhone 17 at fit the page
        // ends well above the page bar, so a drag starting 60 pt above
        // the bar has no overlay under the finger — and lands on the
        // page once the canvas is zoomed. Verified below before it is
        // relied on.
        let bar = pageBarPosition
        let bandTop = (bar.frame.minY - 60) / window.frame.height
        let bandLeft = CGVector(dx: 0.30, dy: bandTop)
        let bandMid = CGVector(dx: 0.50, dy: bandTop)
        let bandRight = CGVector(dx: 0.70, dy: bandTop)

        drag(fromNormalized: bandMid, byPoints: 24, 24)
        sleep(2)
        if currentRegionCount() > 0 {
            throw XCTSkip(
                "The band beneath the page drew at fit on this device — no off-page band to prove the zoom with; the zoom leg moves to the device pass."
            )
        }
        attachScreenshot(named: "canvasdraw-t5-fit")

        // Pinch the canvas (the tallest scroll view is PDFKit's); two
        // honest attempts, each proven by the band drag committing.
        let canvas = tallestScrollView()
        var zoomed = false
        for attempt in 1...2 {
            canvas.pinch(withScale: 2.0, velocity: 1.0)
            // Let PDFKit's zoom settle before the finger lands.
            sleep(3)
            drag(fromNormalized: bandMid, byPoints: 24, 24)
            if waitForRegionCount(1, timeout: 5) {
                zoomed = true
                break
            }
            attachScreenshot(named: "canvasdraw-t5-pinch-attempt-\(attempt)")
        }
        attachScreenshot(named: "canvasdraw-t5-zoomed")
        guard zoomed else {
            throw XCTSkip(
                "The zoom leg did not prove out in two attempts on this simulator (the pinch did not zoom, or the post-pinch drag was dropped — see the attached stills); the leg stays with the unit-level snapZoomScaleOverride proofs (DrawWinsTests) and the device pass."
            )
        }

        // Zoomed: 9 × 9 screen pt stays under the 20-pt commit floor …
        drag(fromNormalized: bandLeft, byPoints: 9, 9)
        sleep(2)
        XCTAssertEqual(
            currentRegionCount(), 1,
            "A 9 × 9 screen-pt drag must not commit at zoom — the commit floor is measured on screen."
        )
        // … and 24 × 24 commits again.
        drag(fromNormalized: bandRight, byPoints: 24, 24)
        XCTAssertTrue(
            waitForRegionCount(2),
            "A 24 × 24 screen-pt drag must commit at zoom; page bar read \(currentRegionCount())."
        )
        attachScreenshot(named: "canvasdraw-t5-zoomed-floor")
    }

    /// T6 — Undo removes the drawn box.
    func testUndoRemovesTheDrawnBox() {
        launchSampleInEditor()
        enterDrawMode()
        let base = drawBaselineBox("Box A never drew — the undo leg has nothing to undo.")

        tapUndo()
        XCTAssertTrue(
            waitForRegionCount(base - 1),
            "Undo must remove the drawn box (page bar read \(currentRegionCount()), expected \(base - 1))."
        )
        attachScreenshot(named: "canvasdraw-t6-after-undo")
    }

    /// T7 — the compact-float draw.
    func testDragBeneathCompactFloatDrawsOneBox() {
        launchSampleInEditor(extraArguments: ["--searchDetent=compact"])
        openSearchSheetAtCompact()
        enterDrawMode()
        drag(from: boxAStart, to: boxAEnd)
        XCTAssertTrue(
            waitForRegionCount(1, timeout: 12),
            "A drag beneath the compact float must draw one box (page bar read \(currentRegionCount()))."
        )
        attachScreenshot(named: "canvasdraw-t7-compact-float-draw")
    }

    /// T8 — Redact with the sheet parked at the compact float: the
    /// sheet is down on the results screen and Keep Editing
    /// re-enables Search.
    func testRedactWithCompactFloatClosesTheSheet() {
        launchSampleInEditor(extraArguments: ["--searchDetent=compact"])
        enterDrawMode()
        _ = drawBaselineBox("Box A never drew — the Redact leg has nothing to redact.")
        leaveDrawMode()
        openSearchSheetAtCompact()
        openOverflowAndTap(label: "Redact", identifier: "redactButton")

        let resultsHome = app.buttons["verificationDoneButton"]
        XCTAssertTrue(
            resultsHome.waitForExistence(timeout: 90),
            "The results screen never appeared after Redact."
        )
        XCTAssertFalse(
            compactFloatStrip.exists,
            "The Search sheet must be down on the results screen."
        )
        attachScreenshot(named: "canvasdraw-t8-results-no-float")

        let keepEditing = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Keep Editing'"))
            .firstMatch
        XCTAssertTrue(keepEditing.waitForExistence(timeout: 10), "The Keep Editing card never appeared.")
        keepEditing.tap()
        let search = app.buttons["searchRedact"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "The editor's Search button never came back.")
        XCTAssertTrue(
            waitForEnabled(search, timeout: 10),
            "Search must be enabled again after Keep Editing."
        )
        attachScreenshot(named: "canvasdraw-t8-keep-editing-search-enabled")
    }

    // MARK: - Launch + tool

    /// Home → "Try the Sample" → editor on page 1 of the 3-page sample;
    /// waits for the text-layer toast (bottom edge, ~7 s) to clear so
    /// no drag lands on it.
    private func launchSampleInEditor(extraArguments: [String] = []) {
        app.launchArguments = ["--uitesting"] + extraArguments
        app.launch()
        let sampleCard = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Try the Sample'"))
            .firstMatch
        XCTAssertTrue(
            sampleCard.waitForExistence(timeout: 30),
            "HomeView's sample card never appeared — check the --uitesting launch hook."
        )
        sampleCard.tap()
        XCTAssertTrue(
            app.buttons["drawTool"].waitForExistence(timeout: 30),
            "The editor's Rectangle tool never appeared after opening the sample."
        )
        XCTAssertTrue(
            pageBarPosition.waitForExistence(timeout: 10),
            "The page bar never read '1 of 3' — the 3-page sample did not open on page 1."
        )
        let toast = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Text layer detected'"))
            .firstMatch
        if toast.waitForExistence(timeout: 5) {
            XCTAssertTrue(
                toast.waitForNonExistence(timeout: 20),
                "The text-layer toast never cleared."
            )
        }
        // Let the Home → editor cross-dissolve finish before the first tap.
        sleep(1)
    }

    private var pageBarPosition: XCUIElement { app.staticTexts["1 of 3"] }

    /// Tap the Rectangle tool and wait for its "Drawing mode active"
    /// value. The tool is a toggle, so a dropped tap is retried and a
    /// late-landing one (which the retry would have toggled off again)
    /// is corrected by the next round — three rounds cover both.
    private func enterDrawMode() {
        let tool = app.buttons["drawTool"]
        XCTAssertTrue(tool.waitForExistence(timeout: 10), "Rectangle tool not present.")
        for _ in 0..<3 {
            tool.tap()
            if waitForToolValue("Drawing mode active", timeout: 6) { return }
        }
        XCTFail("The Rectangle tool did not report drawing mode after three taps.")
    }

    /// Poll the tool's accessibility value.
    private func waitForToolValue(_ expected: String, timeout: TimeInterval = 10) -> Bool {
        let tool = app.buttons["drawTool"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (tool.value as? String) == expected { return true }
            usleep(250_000)
        }
        return (tool.value as? String) == expected
    }

    /// Leave the Rectangle tool (same retry shape as `enterDrawMode`).
    private func leaveDrawMode() {
        let tool = app.buttons["drawTool"]
        for _ in 0..<3 {
            tool.tap()
            if waitForToolValue("Tap to enter drawing mode", timeout: 6) { return }
        }
        XCTFail("The Rectangle tool did not leave drawing mode after three taps.")
    }

    /// Tap the toolbar Search button; under the `--searchDetent=compact`
    /// launch hook the sheet's onAppear parks it at the compact float.
    private func openSearchSheetAtCompact() {
        let search = app.buttons["searchRedact"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Search button not present.")
        search.tap()
        XCTAssertTrue(
            compactFloatStrip.waitForExistence(timeout: 15),
            "The Search sheet never parked at the compact float — check the --searchDetent launch hook."
        )
        // Let the pager's compact inset re-fit the page before any drag.
        sleep(1)
    }

    private var compactFloatStrip: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isEnabled { return true }
            usleep(250_000)
        }
        return element.exists && element.isEnabled
    }

    // MARK: - Drags

    /// One finger, pressed briefly then dragged between two
    /// window-normalized points.
    private func drag(from start: CGVector, to end: CGVector) {
        let a = window.coordinate(withNormalizedOffset: start)
        let b = window.coordinate(withNormalizedOffset: end)
        a.press(forDuration: 0.05, thenDragTo: b)
    }

    /// Drag by a screen-point delta from a window-normalized start. These
    /// are the threshold drags (4 / 9 / 24 pt), so the finger moves slowly
    /// and rests before lifting: a fast synthesized drag can lift a few
    /// points short of its target on a loaded host, which turns a
    /// just-over-the-floor drag into a rejected one.
    private func drag(fromNormalized start: CGVector, byPoints dx: CGFloat, _ dy: CGFloat) {
        let size = window.frame.size
        let end = CGVector(dx: start.dx + dx / size.width, dy: start.dy + dy / size.height)
        let a = window.coordinate(withNormalizedOffset: start)
        let b = window.coordinate(withNormalizedOffset: end)
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// Draw box A as a leg's baseline. One settle retry: if the first
    /// drag has not registered within the wait, drag once more — a late
    /// first drag then leaves two stacked boxes, which the caller absorbs
    /// by working from the count read back here.
    private func drawBaselineBox(
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) -> Int {
        drag(from: boxAStart, to: boxAEnd)
        if !waitForRegionCount(1) {
            drag(from: boxAStart, to: boxAEnd)
            _ = waitForRegionCount { $0 >= 1 }
        }
        let count = currentRegionCount()
        XCTAssertGreaterThanOrEqual(count, 1, message, file: file, line: line)
        return count
    }

    /// PDFKit's scroll view is the tallest one on the editor.
    private func tallestScrollView() -> XCUIElement {
        let all = app.scrollViews.allElementsBoundByIndex
        return all.max(by: { $0.frame.height < $1.frame.height }) ?? app.scrollViews.firstMatch
    }

    // MARK: - Page bar

    /// The page bar's region count for the current page — 0 when the bar
    /// shows no count.
    private func currentRegionCount() -> Int {
        let label = app.staticTexts
            .matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ regions?$"))
            .firstMatch
        guard label.exists,
              let head = label.label.split(separator: " ").first,
              let count = Int(head)
        else { return 0 }
        return count
    }

    /// Poll the page bar until its count satisfies `accept`.
    private func waitForRegionCount(
        timeout: TimeInterval = 8, accept: (Int) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if accept(currentRegionCount()) { return true }
            usleep(250_000)
        }
        return accept(currentRegionCount())
    }

    /// Poll the page bar until it reads exactly `count`.
    private func waitForRegionCount(_ count: Int, timeout: TimeInterval = 8) -> Bool {
        waitForRegionCount(timeout: timeout) { $0 == count }
    }

    // MARK: - Chrome

    /// Open the "…" menu and tap an item — label first (identifiers do
    /// not reliably propagate into the system menu, the
    /// `EditorHomeUITests` / `ShareRiskSheetUITests` precedent),
    /// identifier second.
    private func openOverflowAndTap(label: String, identifier: String) {
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

    /// Undo lives on the trailing bar; on a width where the bar folds
    /// it resolves through the overflow menu instead.
    private func tapUndo() {
        let undo = app.buttons["Undo"].firstMatch
        if undo.waitForExistence(timeout: 5), undo.isHittable {
            undo.tap()
            return
        }
        openOverflowAndTap(label: "Undo", identifier: "Undo")
    }

    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
