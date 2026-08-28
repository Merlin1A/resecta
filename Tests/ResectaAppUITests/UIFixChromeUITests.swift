import XCTest

/// Verification battery — the compact chrome and the chip
/// strips, driven end-to-end:
///
/// - GEOMETRY: no pixel/snapshot test exists, so these
///   legs assert the ACCESSIBILITY frames of the redrawn controls.
///   The floor is a 46pt LAYOUT frame placed AFTER the drawn
///   chrome, so a control's whole element measures
///   ~46pt (≈44.2 effective under the sheet's ~0.96 render scale);
///   the retired chrome drew the floor INSIDE its wash and
///   measured 50–64pt. Anything ≥48 is the old slab.
/// - STRIP COOPERATION: the two strips sit in the
///   sheet's `.safeAreaInset` chrome layer —
///   a vertical drag STARTING on a strip must still resize the sheet
///   in BOTH directions (the horizontal ScrollView must not swallow
///   vertical pans), and a horizontal drag must scroll the chips
///   (17-category reachability on the scan strip).
///
/// Rails: the MCP swipe/gesture/drag tools are E3
/// silent no-ops and `snapshot_ui` is blind on the inset-bound sheet
/// — XCUITest coordinate drives are the only admissible evidence
/// here. Drag idioms + O-1/R7 settle-retry guards mirror
/// `SearchDetentLayoutUITests`.
///
/// nonisolated for the same reason as the sibling suites: an XCUITest
/// drives a separate process and touches no @MainActor app state.
nonisolated final class UIFixChromeUITests: XCTestCase {

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

    // MARK: - Helpers

    /// Scan surface with the chips strip revealed (`scanCategoryChips`
    /// is flag-dark in the shipping build; the strip converts with its
    /// component family).
    private func launchScanWithStrip() {
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--openSearchSheet",
            "--searchMode=piiScan", "--showRetiredSheetControls",
        ]
        app.launch()
        XCTAssertTrue(
            app.buttons["Scan document for PII"].waitForExistence(timeout: 30),
            "Search sheet never presented — check the --openSearchSheet launch hook."
        )
    }

    private var window: XCUIElement { app.windows.firstMatch }

    private var scanStrip: XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "scanCategoryChips").firstMatch
    }

    private var substrateStrip: XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "chipRowSubstrate").firstMatch
    }

    /// House expand drag (grabber strip to the top; see
    /// `SearchDetentLayoutUITests.dragSheetToExpanded`).
    private func dragSheetToExpanded() {
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func assertSheetExpanded() {
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Dismiss button not found after drag.")
        XCTAssertLessThan(
            dismiss.frame.minY, window.frame.height * 0.2,
            "Sheet did not reach the expanded detent — the drag failed, so this test exercised nothing."
        )
    }

    /// Normalize a fresh presentation to the medium detent (a cold
    /// first launch can arrive expanded — the O-1 settle class).
    private func normalizeToMedium() {
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10), "Dismiss button not found.")
        if dismiss.frame.minY < window.frame.height * 0.35 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
            start.press(forDuration: 0.1, thenDragTo: end)
            sleep(1)
        }
        assertMediumBand(dismiss.frame.minY, "normalization")
    }

    private func assertMediumBand(_ headerY: CGFloat, _ context: String) {
        XCTAssertTrue(
            headerY > window.frame.height * 0.35
                && headerY < window.frame.height * 0.65,
            "Sheet not at the medium detent after \(context) (header at \(headerY))."
        )
    }

    /// Floor band: 46pt layout ⇒ [44.2, 46] rendered (render
    /// scale); the retired chrome measured ≥48 on the same element.
    private func assertRuledFloor(_ value: CGFloat, axis: String, of name: String) {
        XCTAssertGreaterThanOrEqual(
            value, 43.5,
            "\(name) \(axis) fell below the 46pt layout floor (\(value)) — the hit-area guarantee is gone."
        )
        XCTAssertLessThan(
            value, 47.9,
            "\(name) \(axis) measures \(value) — the retired ≥48pt slab chrome, not the ruled compact floor."
        )
    }

    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Geometry: Scan surface

    func testExpandedDetent_scanChromeDrawsRuledCompactGeometry() {
        launchScanWithStrip()
        // First-pan settle retry (house idiom — the first drag after
        // presentation can be swallowed while custom-detent resolution
        // settles; a genuinely dead expand still fails the assert).
        dragSheetToExpanded()
        sleep(2)
        if app.buttons["searchDismissButton"].firstMatch.frame.minY
            > window.frame.height * 0.2 {
            dragSheetToExpanded()
            sleep(2)
        }
        assertSheetExpanded()

        // Icon circles: whole element = the 46pt square floor.
        let rescan = app.buttons["rescanButton"].firstMatch
        XCTAssertTrue(rescan.waitForExistence(timeout: 10), "In-row ↻ not found under the reveal.")
        assertRuledFloor(rescan.frame.width, axis: "width", of: "rescan ↻")
        assertRuledFloor(rescan.frame.height, axis: "height", of: "rescan ↻")

        let bookmark = app.buttons["savedSearchesBookmark"].firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 10), "Saved-searches bookmark not found.")
        assertRuledFloor(bookmark.frame.width, axis: "width", of: "bookmark")
        assertRuledFloor(bookmark.frame.height, axis: "height", of: "bookmark")

        // FilterChip: floored height 46 — the retired chain drew 54+
        // (floor inside the padding/background).
        XCTAssertTrue(scanStrip.waitForExistence(timeout: 10), "scanCategoryChips strip not found.")
        let chip = scanStrip.buttons.firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "No chip found inside the strip.")
        assertRuledFloor(chip.frame.height, axis: "height", of: "category chip")
        attachScreenshot(named: "uifix-scan-geometry")
    }

    // MARK: - Geometry: Search surface

    func testExpandedDetent_searchChromeDrawsRuledCompactGeometry() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--openSearchSheet"]
        app.launch()

        let field = app.textFields["Search text"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 30),
            "Search sheet never presented — check the --openSearchSheet launch hook."
        )
        field.tap()
        field.typeText("Sample\n")
        XCTAssertTrue(
            app.staticTexts["0 of 1 selected"].waitForExistence(timeout: 15),
            "Text search returned no results for the bundled fixture."
        )

        // Results arrival raises medium → large (the blessed nudge);
        // top up via the grabber only if the raise was pre-empted.
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Dismiss button not found.")
        if dismiss.frame.minY > window.frame.height * 0.2 {
            dragSheetToExpanded()
        }
        assertSheetExpanded()

        // Sort chip (Menu label carries the stable accessibility label).
        let sortChip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Sort order, currently"))
            .firstMatch
        XCTAssertTrue(sortChip.waitForExistence(timeout: 10), "Sort chip not found with results on board.")
        assertRuledFloor(sortChip.frame.height, axis: "height", of: "sort chip")

        // Result-nav pair: two 46pt squares, 6pt pair spacing
        // (the retired pair drew ~64pt-wide bordered slabs at 2pt).
        let prev = app.buttons["resultNavPrevious"].firstMatch
        let next = app.buttons["resultNavNext"].firstMatch
        XCTAssertTrue(prev.waitForExistence(timeout: 10), "Previous chevron not found.")
        XCTAssertTrue(next.exists, "Next chevron not found.")
        assertRuledFloor(prev.frame.width, axis: "width", of: "nav previous")
        assertRuledFloor(prev.frame.height, axis: "height", of: "nav previous")
        assertRuledFloor(next.frame.width, axis: "width", of: "nav next")
        assertRuledFloor(next.frame.height, axis: "height", of: "nav next")
        let gap = next.frame.minX - prev.frame.maxX
        XCTAssertTrue(
            gap >= 4 && gap <= 9,
            "Nav pair gap \(gap) outside the ruled 6pt spacing band."
        )

        // Select All arrives prominent (none selected): the custom
        // capsule's element is the 46pt floor — the retired
        // `.borderedProminent` wash measured ~54+.
        let selectAll = app.buttons["footerSelectAllButton"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "Footer Select All not found.")
        assertRuledFloor(selectAll.frame.height, axis: "height", of: "Select All")
        attachScreenshot(named: "uifix-search-geometry")
    }

    // MARK: - Strip cooperation (leg a — scan strip)

    func testMediumDetent_verticalDragOnScanStripResizesSheetBothDirections() {
        launchScanWithStrip()
        normalizeToMedium()
        XCTAssertTrue(scanStrip.waitForExistence(timeout: 10), "scanCategoryChips strip not found.")

        let dismiss = app.buttons["searchDismissButton"].firstMatch
        let headerYAtMedium = dismiss.frame.minY

        // Vertical drag STARTING on the strip must cooperatively
        // EXPAND the sheet — the horizontal ScrollView must not
        // swallow the vertical pan (first-pan settle retry).
        for _ in 0..<2 {
            let start = scanStrip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
            start.press(forDuration: 0.1, thenDragTo: end)
            sleep(2)
            if abs(dismiss.frame.minY - headerYAtMedium) > 10 { break }
        }
        XCTAssertLessThan(
            dismiss.frame.minY, window.frame.height * 0.2,
            "A vertical drag starting on the scan chip strip did not expand the sheet — the strip swallowed the pan."
        )
        attachScreenshot(named: "uifix-scanstrip-expanded")

        // And back DOWN from the strip: collapse to medium.
        let headerYAtTop = dismiss.frame.minY
        for _ in 0..<2 {
            let start = scanStrip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            start.press(forDuration: 0.1, thenDragTo: end)
            sleep(2)
            if abs(dismiss.frame.minY - headerYAtTop) > 10 { break }
        }
        assertMediumBand(dismiss.frame.minY, "the strip down-drag")
        attachScreenshot(named: "uifix-scanstrip-collapsed")
    }

    // MARK: - Strip cooperation (leg b — horizontal scroll, 17-category reachability)

    func testScanStripHorizontalDragScrollsAllCategoriesOnScreen() {
        launchScanWithStrip()
        XCTAssertTrue(scanStrip.waitForExistence(timeout: 10), "scanCategoryChips strip not found.")

        // Single-row proof: the strip container is one chip row tall —
        // the retired 17-chip wrap measured hundreds of points.
        XCTAssertLessThan(
            scanStrip.frame.height, 60,
            "The scan chips render \(scanStrip.frame.height)pt tall — a wrap, not the ruled single-row strip."
        )

        // The last category chip overflows the strip at default type
        // size (`isHittable`, not `exists` — offscreen strip content
        // stays in the tree).
        let lastChip = app.buttons["License Plate detector"].firstMatch
        XCTAssertFalse(
            lastChip.exists && lastChip.isHittable,
            "The 17-category set no longer overflows the strip — the reachability leg would prove nothing."
        )

        var reached = false
        for _ in 0..<4 {
            let start = scanStrip.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            let end = scanStrip.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
            sleep(1)
            if lastChip.exists && lastChip.isHittable {
                reached = true
                break
            }
        }
        XCTAssertTrue(
            reached,
            "Horizontal drags never brought the last category chip on screen — the strip did not scroll (17-category reachability)."
        )
        attachScreenshot(named: "uifix-scanstrip-scrolled")
    }

    // MARK: - Strip cooperation (leg a — post-scan substrate strip)

    func testMediumDetent_verticalDragOnSubstrateStripCooperativelyExpands() {
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--openSearchSheet"]
        app.launch()

        let field = app.textFields["Search text"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 30),
            "Search sheet never presented — check the --openSearchSheet launch hook."
        )
        field.tap()
        field.typeText("Sample\n")
        XCTAssertTrue(
            app.staticTexts["0 of 1 selected"].waitForExistence(timeout: 15),
            "Text search returned no results for the bundled fixture."
        )
        // Results arrival raises the sheet — normalize back down so
        // the expand leg has somewhere to go.
        normalizeToMedium()

        XCTAssertTrue(substrateStrip.waitForExistence(timeout: 10), "chipRowSubstrate strip not found.")
        let dismiss = app.buttons["searchDismissButton"].firstMatch
        let headerYAtMedium = dismiss.frame.minY

        // Start the vertical drag on the strip's EMPTY trailing area
        // (right of the lone sort chip) — a drag starting on the Menu
        // chip itself could open the menu instead of panning.
        for _ in 0..<2 {
            let start = substrateStrip.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.05))
            start.press(forDuration: 0.1, thenDragTo: end)
            sleep(2)
            if abs(dismiss.frame.minY - headerYAtMedium) > 10 { break }
        }
        XCTAssertLessThan(
            dismiss.frame.minY, window.frame.height * 0.2,
            "A vertical drag starting on the substrate chip strip did not expand the sheet — the strip swallowed the pan."
        )
        attachScreenshot(named: "uifix-substratestrip-expanded")
    }
}
