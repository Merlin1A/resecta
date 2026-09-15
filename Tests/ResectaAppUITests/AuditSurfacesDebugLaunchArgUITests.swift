import XCTest

/// D12-21 (1.2 instrumentation, I-1) — the `--enableAuditSurfaces` DEBUG
/// launch arg re-lights the dark 1.0 audit + diagnostic surfaces for
/// walkthrough evidence. Same `CommandLine.arguments` shape (and one shared
/// arg) across `SearchState.searchAuditSurfacesEnabled` and
/// `searchDiagnosticSurfacesEnabled`, mirroring `--showRetiredSheetControls`.
///
/// Assertion targets are the two RESULTS-INDEPENDENT mounts in
/// `SearchResultsSection.sectionTopChrome`, one per flag:
///   - audit flag → the Scan-coverage report panel (`CoverageReportView`;
///     the completion skeleton report is stored regardless of hit count);
///   - diagnostic flag → the WU-07 doctype banner (its "Dismiss doctype
///     banner" control; `lastDoctypeExplanation` is set by every completed
///     PII scan with extractable first-page text).
/// The FOOTER mounts behind the same flags (Export Audit, the
/// Document-profile disclosure) sit inside `SearchFooterSection`, which the
/// sheet only renders when `filteredCount > 0` — the bundled synthetic
/// fixture yields zero piiScan detections, so those mounts are not
/// UI-testable here and are exercised by the Phase-1 walkthrough on real
/// documents instead. The flag VALUES those mounts read are exactly the ones
/// this test proves.
///
/// The in-process pins (`SearchStateTests` UP-2/UP-4) keep asserting `false`
/// (the xctest runner never carries the arg); the Release binary is proven
/// arg-free by `Scripts/release-flag-check.sh`. This test covers the third
/// leg: the arg actually mounts flag-gated surfaces in a DEBUG build, and
/// their absence without it is unchanged.
///
/// nonisolated for the same reason as `DetectionTriageDismissUITests`: an
/// XCUITest drives a separate process and touches no @MainActor app state.
nonisolated final class AuditSurfacesDebugLaunchArgUITests: XCTestCase {

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

    // MARK: - Shared drive

    /// Launch into the Scan interface (no auto-run) over the bundled test
    /// document and start a scan.
    private func launchAndRunScan(enableAuditSurfaces: Bool) -> XCUIElement {
        var arguments = ["--uitesting", "--loadTestDocument",
                         "--openSearchSheet", "--searchMode=piiScan"]
        if enableAuditSurfaces {
            arguments.append("--enableAuditSurfaces")
        }
        app.launchArguments = arguments
        app.launch()

        let scanButton = app.buttons["Scan document for PII"]
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 30),
            "Scan surface never presented — check the --openSearchSheet/--searchMode hooks."
        )
        scanButton.tap()
        return scanButton
    }

    /// The WU-07 doctype banner's dismiss control (stable AX label) —
    /// the diagnostic flag's results-independent mount.
    private var doctypeBannerDismiss: XCUIElement {
        app.buttons["Dismiss doctype banner"]
    }

    /// The Scan-coverage report panel's disclosure label — the audit flag's
    /// results-independent mount. CONTAINS: the DisclosureGroup can compose
    /// state into the AX label.
    private var coveragePanel: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: #"label CONTAINS "Scan coverage""#))
            .firstMatch
    }

    // MARK: - Tests

    /// Arg ON: after a completed scan, both flags' surfaces mount. The
    /// banner doubles as the scan-completion signal (it requires
    /// `lastDoctypeExplanation`, which only the finished scan sets).
    func testLaunchArgOn_mountsCoveragePanelAndDoctypeBanner() {
        _ = launchAndRunScan(enableAuditSurfaces: true)

        XCTAssertTrue(
            doctypeBannerDismiss.waitForExistence(timeout: 30),
            "Doctype banner never mounted with --enableAuditSurfaces — either the "
            + "scan never completed or the diagnostic flag ignored the arg."
        )
        XCTAssertTrue(
            coveragePanel.waitForExistence(timeout: 15),
            "Scan-coverage panel never mounted with --enableAuditSurfaces — the "
            + "diagnostic flag read the arg (banner above), so the audit flag "
            + "or the completion report is broken."
        )
    }

    /// Arg ABSENT: the same drive leaves both surfaces unmounted (the 1.0
    /// dark posture is unchanged). Absence is asserted by a timed-out
    /// existence wait spanning the scan's completion window, then the
    /// re-enabled run control confirms the scan actually finished.
    func testLaunchArgAbsent_bothSurfacesStayAbsent() {
        let scanButton = launchAndRunScan(enableAuditSurfaces: false)

        let appeared = XCTWaiter.wait(
            for: [expectation(
                for: NSPredicate(format: "exists == true"),
                evaluatedWith: doctypeBannerDismiss
            )],
            timeout: 8
        )
        XCTAssertEqual(
            appeared, .timedOut,
            "Doctype banner mounted WITHOUT --enableAuditSurfaces."
        )
        XCTAssertFalse(
            coveragePanel.exists,
            "Scan-coverage panel mounted WITHOUT --enableAuditSurfaces."
        )
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 10) && scanButton.isEnabled,
            "Scan run control never returned to enabled — the no-arg scan may not have completed, "
            + "which would make the absence assertions vacuous."
        )
    }
}
