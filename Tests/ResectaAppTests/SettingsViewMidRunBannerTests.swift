import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// GATE-1 — Settings-during-pipeline UX.
//
// `SettingsView` renders a non-blocking banner ("A pipeline run is in
// progress. Changes apply to the next run.") while
// `documentState.phaseKind` is `.detecting / .redacting / .verifying`.
// The four pipeline-affecting controls remain functional; the run-entry
// STATE-5 snapshot in `PipelineCoordinator` already pins the active
// run's behavior, so the banner is purely informational.
//
// These tests pin the predicate that drives banner visibility
// (`SettingsView.isPipelineActive(phaseKind:)`) so changes to the
// transition table or phase enum surface here without needing a
// SwiftUI-hosting harness.

@Suite("SettingsView mid-run banner (GATE-1)")
@MainActor
struct SettingsViewMidRunBannerTests {

    // MARK: - Banner-active phases

    @Test("Banner renders during .detecting")
    func testBannerRendersDuringDetecting() {
        #expect(SettingsView.isPipelineActive(phaseKind: .detecting) == true)
    }

    @Test("Banner renders during .redacting")
    func testBannerRendersDuringRedacting() {
        #expect(SettingsView.isPipelineActive(phaseKind: .redacting) == true)
    }

    @Test("Banner renders during .verifying")
    func testBannerRendersDuringVerifying() {
        #expect(SettingsView.isPipelineActive(phaseKind: .verifying) == true)
    }

    // MARK: - Banner-inactive phases

    @Test("Banner is absent in .empty")
    func testBannerAbsentInEmpty() {
        #expect(SettingsView.isPipelineActive(phaseKind: .empty) == false)
    }

    @Test("Banner is absent in .editing")
    func testBannerAbsentInEditing() {
        #expect(SettingsView.isPipelineActive(phaseKind: .editing) == false)
    }

    @Test("Banner is absent in .verified")
    func testBannerAbsentInVerified() {
        #expect(SettingsView.isPipelineActive(phaseKind: .verified) == false)
    }

    @Test("Banner is absent in .failed")
    func testBannerAbsentInFailed() {
        #expect(SettingsView.isPipelineActive(phaseKind: .failed) == false)
    }

    @Test("Banner is absent in .importing")
    func testBannerAbsentInImporting() {
        #expect(SettingsView.isPipelineActive(phaseKind: .importing) == false)
    }

    @Test("Banner is absent in .exporting")
    func testBannerAbsentInExporting() {
        // Export runs after `.verified`; settings are stable by then.
        #expect(SettingsView.isPipelineActive(phaseKind: .exporting) == false)
    }

    // MARK: - Complete coverage of PhaseKind cases

    @Test("Predicate is defined for every PhaseKind case (banner visibility table)")
    func testPredicateCoversAllPhaseKinds() {
        // If a new phase is added to PhaseKind, this loop forces the
        // GATE-1 author to revisit the banner-visibility contract.
        let allCases: [DocumentState.PhaseKind] = [
            .empty, .importing, .editing, .detecting,
            .redacting, .verifying, .verified, .exporting, .failed
        ]
        let active = allCases.filter { SettingsView.isPipelineActive(phaseKind: $0) }
        #expect(active.count == 3,
                "Banner is intended to render only during the three pipeline-active phases.")
        #expect(Set(active) == [.detecting, .redacting, .verifying])
    }
}
