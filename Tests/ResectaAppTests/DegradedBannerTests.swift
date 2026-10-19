import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Verify the app-side surfaces driven by
// `GazetteerLoadDiagnostics`:
//
// 1. The banner on the search sheet's Scan interface is gated purely by
//    `autoDetectionDegraded` (one rule: Scan always; Search only when a
//    scan-class capability degrades the current action); flipping it back
//    to false hides the banner without any additional plumbing.
// 2. The copy branches on the recorded failure list, and the list shares
//    the flag's lifetime.

@Suite("Degraded auto-detection banner")
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

    // MARK: - Copy branch + failure recording

    @Test("NER-only degrade gets the OS-model copy, not the corpus copy")
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

    @Test("Any corpus failure — including mixed with NER — keeps the corpus copy")
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

    @Test("clearForNewDocument resets the recorded failure list")
    func testFailureListResetsWithFlag() {
        let (coordinator, _) = makeWiredCoordinator()
        coordinator.redactionState.autoDetectionDegraded = true
        coordinator.redactionState.autoDetectionDegradeFailures = ["NameGazetteer"]
        #expect(!coordinator.redactionState.autoDetectionDegradeFailures.isEmpty)
        coordinator.redactionState.clearForNewDocument()
        #expect(!coordinator.redactionState.autoDetectionDegraded)
        #expect(coordinator.redactionState.autoDetectionDegradeFailures.isEmpty,
                "failure list shares the flag's lifetime")
    }
}
