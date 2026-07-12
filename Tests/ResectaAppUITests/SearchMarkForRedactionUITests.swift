import XCTest

/// UI tests for the Search & Redact toolbar apply path (q10 / UXF-01;
/// direct apply — the "Mark for Redaction" confirm dialog is gone).
///
/// Regression guard for the SearchState cache-in-getter observation crash:
/// the apply ran `appliedResultIDs.formUnion`, whose
/// `didSet` invalidated the filter/grouping caches; the next List body
/// evaluation then recomputed a grouping getter (`resultsByPage` /
/// `resultsByTerm` / `resultsByCategory`) and WROTE its cache var mid-body-
/// evaluation. With the cache vars observation-wrapped, that write re-entered
/// the ObservationRegistrar during the in-flight GraphHost transaction and
/// aborted with `AG::precondition_failure` (SIGABRT). The shipped fix marks
/// the backing cache/key vars `@ObservationIgnored` so getter memoization is
/// invisible to the observation graph.
///
/// These tests drive the real end-to-end flow the crash lived in: load the
/// bundled single-page test document, present the search sheet via the DEBUG
/// `--openSearchSheet` hook, run a search that yields results, select all,
/// tap the "Apply N" toolbar button (which applies directly), and assert the
/// app survived AND the apply produced regions (the success toast only fires
/// after `applySearchResults` returns a non-nil result).
///
/// Grouping coverage here: page grouping (text mode) and term grouping
/// (multi-term mode, "By Term" toggle). The category-grouping branch needs
/// piiScan results, which the bundled synthetic fixture cannot produce; that
/// branch is pinned in-process by `SearchResultsListObservationCrashTests`
/// (ResectaAppTests), which hosts the same List body over seeded PII results.
///
/// nonisolated for the same reason as `DetectionTriageDismissUITests`: an
/// XCUITest drives a separate process and touches no @MainActor app state;
/// under the SE-0466 MainActor-default flip the lifecycle overrides would
/// otherwise mismatch XCTestCase's nonisolated ObjC lifecycle methods.
nonisolated final class SearchMarkForRedactionUITests: XCTestCase {

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

    // MARK: - Tests

    /// Page grouping (the demonstrated ts2 crash route): text search →
    /// select all → Apply.
    func testMarkForRedaction_pageGrouping_survivesAndCreatesRegions() {
        launchSearchSheet(mode: nil)

        // Text-mode query against the bundled fixture's known content
        // ("Sample Document Page 1"). The 300 ms debounce kicks off the
        // search; the "Page 1" section header proves the page-grouped
        // List branch rendered results.
        let field = app.textFields["Search text"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 30),
            "Search sheet never presented — check the --openSearchSheet launch hook."
        )
        field.tap()
        field.typeText("Sample")

        XCTAssertTrue(
            app.staticTexts["Page 1"].waitForExistence(timeout: 15),
            "Text search returned no page-grouped results for the bundled fixture."
        )

        selectAllAndApply()
    }

    /// Term grouping: multi-term search with two terms, "By Term" grouping
    /// toggled on, then the same select → apply route.
    func testMarkForRedaction_termGrouping_survivesAndCreatesRegions() {
        launchSearchSheet(mode: "multiTerm")

        let field = app.textFields["Search term input"]
        XCTAssertTrue(
            field.waitForExistence(timeout: 30),
            "Multi-term search sheet never presented — check --openSearchSheet/--searchMode."
        )
        // Each newline submits the typed term via .onSubmit and re-triggers
        // the search. Both terms exist in the fixture's text layer.
        field.tap()
        field.typeText("Sample\n")
        field.tap()
        field.typeText("Document\n")

        // The "By Term" grouping toggle only appears once 2+ terms exist.
        // Toggle(.button style) surfaces as a SWITCH in the AX tree (verified
        // against the live 26.4 hierarchy), so query by identifier across
        // element types rather than app.buttons.
        let byTerm = app.descendants(matching: .any)
            .matching(NSPredicate(format: #"label == "By Term""#))
            .firstMatch
        XCTAssertTrue(
            byTerm.waitForExistence(timeout: 15),
            "'By Term' toggle never appeared — second term submission likely failed."
        )
        byTerm.tap()

        // Both terms searched: footer reads "0 of 2 selected". (The
        // term-grouped SECTION HEADERS are lazily materialized and sit
        // offscreen at this detent — the results list viewport is ~18 pt
        // tall on the 26.4 sim — so they can be absent from the AX tree
        // even though the List content closure, where the crash lived,
        // has already evaluated `resultsByTerm`. Assert on the footer
        // count instead; the By Term toggle state above pins the branch.)
        let footerCount = app.staticTexts["0 of 2 selected"]
        XCTAssertTrue(
            footerCount.waitForExistence(timeout: 15),
            "Footer never showed both terms' results — a term submission failed."
        )

        selectAllAndApply()
    }

    // MARK: - Launch

    /// Launch straight into the search sheet over the bundled single-page
    /// test document. `mode` maps to the DEBUG `--searchMode=` hook.
    private func launchSearchSheet(mode: String?) {
        var arguments = ["--uitesting", "--loadTestDocument", "--openSearchSheet"]
        if let mode {
            arguments.append("--searchMode=\(mode)")
        }
        app.launchArguments = arguments
        app.launch()
    }

    // MARK: - Shared apply route + survival assertion

    /// Select all results, tap the "Apply N" toolbar button (direct
    /// apply — no confirmation dialog, triage parity), then assert the
    /// app survived the apply and regions were created. On the pre-fix
    /// build the process SIGABRTs inside the List body re-evaluation
    /// right after the apply tap, so the foreground check (and every
    /// later assertion) detects the crash.
    private func selectAllAndApply() {
        let selectAll = app.buttons["Select All"]
        XCTAssertTrue(
            selectAll.waitForExistence(timeout: 10),
            "Footer 'Select All' button not found."
        )
        selectAll.tap()

        // The Apply button's label carries the live selected count
        // ("Apply 2"), so query by accessibility identifier.
        let apply = app.buttons["searchApplyButton"]
        XCTAssertTrue(
            apply.waitForExistence(timeout: 5),
            "Apply toolbar button not found."
        )
        XCTAssertTrue(
            apply.isEnabled,
            "Apply stayed disabled — Select All did not select any results."
        )
        apply.tap()

        // Survival: the pre-fix build dies here (AG::precondition_failure in
        // the List body re-evaluation triggered by appliedResultIDs.formUnion).
        // A bare "toast exists" check alone would false-pass semantics but not
        // survival; assert both.
        let toast = app.staticTexts.matching(
            NSPredicate(format: #"label BEGINSWITH "Marked""#)
        ).firstMatch
        XCTAssertTrue(
            toast.waitForExistence(timeout: 10),
            "Success toast never appeared — apply failed or the app crashed."
        )
        XCTAssertEqual(
            app.state, .runningForeground,
            "App left the foreground after Apply — observation crash regressed."
        )
        // Sheet chrome should still be interactive after the apply.
        XCTAssertTrue(
            app.buttons["searchApplyButton"].waitForExistence(timeout: 5),
            "Search sheet chrome gone after apply."
        )
    }
}
