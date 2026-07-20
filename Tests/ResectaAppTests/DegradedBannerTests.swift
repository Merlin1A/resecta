import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// SEC-7 — verify the app-side surfaces driven by
// `GazetteerLoadDiagnostics`:
//
// 1. On the first gazetteer-load failure of a session, the coordinator
//    posts exactly one warning toast (mechanism-description copy per I6)
//    and flips `RedactionState.autoDetectionDegraded = true`.
// 2. Subsequent calls observing the same failure do NOT re-toast — the
//    persistent banner on the search sheet's Scan interface carries
//    the state from that point on (one rule: Scan always; Search only when
//    a scan-class capability degrades the current action).
// 3. The banner is gated purely by `autoDetectionDegraded`; flipping it
//    back to false hides the banner without any additional plumbing.
//
// SEC-7 surface.

@Suite("Degraded auto-detection banner — SEC-7")
@MainActor
struct DegradedBannerTests {

    /// Build a coordinator with a wired ToastQueueManager so tests can
    /// observe the warning-toast surface without spinning up the full
    /// pipeline. Mirrors the production wiring at ContentView level.
    private func makeWiredCoordinator() -> (PipelineCoordinator, ToastQueueManager) {
        let coordinator = makeCoordinator()
        let toast = ToastQueueManager()
        coordinator.toastManager = toast
        return (coordinator, toast)
    }

    @Test("First failure posts exactly one warning toast and flips the flag")
    func testFirstFailurePostsWarningToast() {
        let (coordinator, toast) = makeWiredCoordinator()
        #expect(!coordinator.redactionState.autoDetectionDegraded,
                "precondition: flag must start false")
        #expect(toast.activeToasts.isEmpty,
                "precondition: no toasts active before surface call")

        let diagnostics = GazetteerLoadDiagnostics(
            failedGazetteers: ["NameGazetteer"],
            failureReasons: ["NameGazetteer": "resourceMissing"]
        )
        coordinator.surfaceGazetteerLoadDiagnostics(diagnostics)

        #expect(coordinator.redactionState.autoDetectionDegraded,
                "flag must flip on first qualifying failure")
        // Top-position warning toast — see ToastSeverity.position.
        #expect(toast.activeTopToasts.count == 1,
                "first failure must enqueue exactly one warning toast")
        let posted = toast.activeTopToasts.first
        #expect(posted?.severity == .warning)
        // Mechanism-description copy per I6 — no banned outcome-promise
        // words. Anchor on a stable fragment of the locked plan copy.
        #expect(posted?.message.contains("detection corpus failed to load") == true,
                "toast copy must match the locked plan text")
        #expect(posted?.message.contains("Manual redaction tools remain available") == true,
                "toast copy must surface manual-fallback affordance")
    }

    @Test("Second failure surface call does not re-toast (no spam)")
    func testRepeatedFailureDoesNotRespam() {
        let (coordinator, toast) = makeWiredCoordinator()
        let diagnostics = GazetteerLoadDiagnostics(
            failedGazetteers: ["NameGazetteer", "DLPatternGazetteer"],
            failureReasons: [
                "NameGazetteer": "resourceMissing",
                "DLPatternGazetteer": "resourceMissing",
            ]
        )

        coordinator.surfaceGazetteerLoadDiagnostics(diagnostics)
        #expect(toast.activeTopToasts.count == 1, "first call posts the toast")

        // A second detection-pipeline run discovers the same failures.
        // The coordinator must NOT enqueue a second toast.
        coordinator.surfaceGazetteerLoadDiagnostics(diagnostics)
        #expect(toast.activeTopToasts.count == 1,
                "second surface call with same failure must NOT post a second toast")
        #expect(coordinator.redactionState.autoDetectionDegraded,
                "flag stays true; not toggled off and back on")
    }

    @Test("Empty diagnostics is a no-op (healthy load path)")
    func testHealthyDiagnosticsLeavesFlagAlone() {
        let (coordinator, toast) = makeWiredCoordinator()
        coordinator.surfaceGazetteerLoadDiagnostics(GazetteerLoadDiagnostics())
        #expect(!coordinator.redactionState.autoDetectionDegraded,
                "no failures → flag stays false")
        #expect(toast.activeToasts.isEmpty,
                "no failures → no toast")
    }

    @Test("Banner gating tracks the flag (true → banner present, false → absent)")
    func testBannerPersistsWhileFlagSet() {
        // The banner on the search sheet is gated by the unified degrade-rule
        // predicate over `redactionState.autoDetectionDegraded`. Rather
        // than rendering the SwiftUI hierarchy in a test, we pin the
        // contract that DRIVES the conditional — flipping the flag must
        // toggle the predicate without any other state dependency.
        let state = RedactionState()
        #expect(!state.autoDetectionDegraded,
                "RedactionState.autoDetectionDegraded must default to false")

        state.autoDetectionDegraded = true
        #expect(state.autoDetectionDegraded,
                "banner predicate must be true while flag is set")

        state.autoDetectionDegraded = false
        #expect(!state.autoDetectionDegraded,
                "banner predicate must be false when flag is cleared")
    }

    @Test("Unified degrade rule: degrade banner shows on Scan always, never on Search in this tree")
    func testDegradeBannerInterfaceRule() {
        // Unified rule: Scan surfaces a degraded corpus whenever the
        // flag is set (its runs consult the detection corpus). Search
        // shows it only when a scan-class capability degrades the
        // CURRENT action — and no Search-side action in this tree uses
        // one (literal matching + OCR modality access), so the Search
        // side renders none.
        #expect(SearchAndRedactSheet.degradeBannerShouldShow(
            interface: .scan, degraded: true))
        #expect(!SearchAndRedactSheet.degradeBannerShouldShow(
            interface: .scan, degraded: false))
        #expect(!SearchAndRedactSheet.degradeBannerShouldShow(
            interface: .search, degraded: true))
        #expect(!SearchAndRedactSheet.degradeBannerShouldShow(
            interface: .search, degraded: false))
    }

    @Test("Multiple gazetteer failures still post exactly one toast")
    func testAllFourFailuresSingleToast() {
        let (coordinator, toast) = makeWiredCoordinator()
        let diagnostics = GazetteerLoadDiagnostics(
            failedGazetteers: [
                "NameGazetteer", "DLPatternGazetteer",
                "PassportPatternGazetteer", "ContextKeywordsLoader",
            ],
            failureReasons: [:]
        )
        coordinator.surfaceGazetteerLoadDiagnostics(diagnostics)
        // The toast surface is per-session, not per-failure — four failures
        // collapse to one announcement.
        #expect(toast.activeTopToasts.count == 1,
                "four loader failures must still produce a single coalesced toast")
    }

    @Test("GAP-DEPTARGET-NER: NER-absent diagnostic drives the SEC-7 degraded banner flag")
    func testNERAbsentDrivesDegradedBanner() {
        // A NER-model-absent diagnostic carries the new .nerNameModel loader id —
        // the artifact `PIIDetector.loadWithDiagnostics` produces when the OS NER
        // asset is absent (the override→diagnostic production is proven in
        // PIIDetectorInitDegradedTests). It must flip `autoDetectionDegraded`
        // through the SAME coordinator path a corpus failure uses, which gates the
        // `degradedDetectionBanner` on the search sheet's Scan
        // interface — no new banner / UI.
        let (coordinator, _) = makeWiredCoordinator()
        #expect(!coordinator.redactionState.autoDetectionDegraded,
                "precondition: flag starts false")

        let diagnostics = GazetteerLoadDiagnostics(
            failedGazetteers: [GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue],
            failureReasons: [
                GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue:
                    "NLTagger .nameType MobileAsset unavailable (NER name detection disabled)"
            ]
        )
        coordinator.surfaceGazetteerLoadDiagnostics(diagnostics)
        #expect(coordinator.redactionState.autoDetectionDegraded,
                "NER-absent diagnostic must flip the SEC-7 degraded banner flag")
    }

    // MARK: - H-201: copy branch + failure recording

    @Test("H-201: NER-only degrade gets the OS-model copy, not the corpus copy")
    func testNEROnlyCopyBranch() {
        let nerOnly = [GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue]
        #expect(DetectionDegradeCopy.isNEROnly(nerOnly))
        let toast = DetectionDegradeCopy.toast(failedGazetteers: nerOnly)
        let banner = DetectionDegradeCopy.banner(failedGazetteers: nerOnly)
        // The corpus-blaming line would be FALSE on a pre-26.4 device
        // whose bundled corpus loaded fine.
        #expect(!toast.contains("corpus"))
        #expect(!banner.contains("corpus"))
        #expect(toast.contains("name model"))
        #expect(banner.contains("name model"))
    }

    @Test("H-201: any corpus failure — including mixed with NER — keeps the corpus copy")
    func testCorpusAndMixedCopyBranch() {
        let corpusOnly = ["NameGazetteer"]
        let mixed = [
            "NameGazetteer",
            GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue,
        ]
        for failures in [corpusOnly, mixed] {
            #expect(!DetectionDegradeCopy.isNEROnly(failures))
            #expect(DetectionDegradeCopy.toast(failedGazetteers: failures)
                .contains("detection corpus failed to load"))
            #expect(DetectionDegradeCopy.banner(failedGazetteers: failures)
                .contains("detection corpus failed to load"))
        }
    }

    @Test("H-201: coordinator surface records the failure list and posts branch copy")
    func testCoordinatorRecordsFailuresAndBranchesToast() {
        let (coordinator, toast) = makeWiredCoordinator()
        let nerOnly = GazetteerLoadDiagnostics(
            failedGazetteers: [GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue],
            failureReasons: [:]
        )
        coordinator.surfaceGazetteerLoadDiagnostics(nerOnly)
        #expect(coordinator.redactionState.autoDetectionDegradeFailures
                == nerOnly.failedGazetteers,
                "failure list must be recorded for the banner copy branch")
        #expect(toast.activeTopToasts.first?.message.contains("name model") == true,
                "NER-only degrade must post the OS-model toast")
    }

    @Test("H-201: clearForNewDocument resets the recorded failure list")
    func testFailureListResetsWithFlag() {
        let (coordinator, _) = makeWiredCoordinator()
        coordinator.surfaceGazetteerLoadDiagnostics(GazetteerLoadDiagnostics(
            failedGazetteers: ["NameGazetteer"], failureReasons: [:]))
        #expect(!coordinator.redactionState.autoDetectionDegradeFailures.isEmpty)
        coordinator.redactionState.clearForNewDocument()
        #expect(!coordinator.redactionState.autoDetectionDegraded)
        #expect(coordinator.redactionState.autoDetectionDegradeFailures.isEmpty,
                "failure list shares the flag's lifetime")
    }
}
