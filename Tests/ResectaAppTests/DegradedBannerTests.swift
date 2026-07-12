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
//    persistent banner in `DetectionTriageSheet` carries the state from
//    that point on.
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
        // The banner view in DetectionTriageSheet is gated by a single
        // expression: `if redactionState.autoDetectionDegraded`. Rather
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
        // `degradedDetectionBanner` in DetectionTriageSheet — no new banner / UI.
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
}
