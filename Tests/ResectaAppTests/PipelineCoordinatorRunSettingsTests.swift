import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// STATE-5 — Settings snapshot at run entry.
//
// `RunSettings` captures pipeline-affecting settings once at the top of
// `runFullPipeline` / `runDetectionPipeline`, mirroring the existing
// `effectiveMode` snapshot pattern. Mid-run reads of
// `autoVerify`, `paranoidMode`, `pipelineMode`, `fillColor`, and
// `exportDPI` route through the snapshot — a user toggling SettingsView
// during `.detecting / .redacting / .verifying` cannot divert kickoff-
// time behavior from run-time behavior.
//
// These tests pin the snapshot value itself (independence from the live
// SettingsState after capture). The end-to-end "mid-run toggle does not
// affect the run" contract is enforced structurally by the runSettings
// threading in `runFullPipeline` and `runDetectionPipeline`; the live
// pipeline path is exercised by `FullPipelineFlowTests` /
// `DetectionPipelineTests` which already round-trip the run-entry
// snapshot.

@Suite("PipelineCoordinator.RunSettings (STATE-5)")
@MainActor
struct PipelineCoordinatorRunSettingsTests {

    private func cleanSettingsDefaults() {
        let keys = [
            "paranoidMode", "autoVerify", "pipelineMode.v2",
            "exportDPI", "fillColor"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Snapshot capture

    @Test("Snapshot captures all five pipeline-affecting fields")
    func snapshotCapturesAllFields() {
        cleanSettingsDefaults()
        let settings = SettingsState()
        settings.pipelineMode = .searchableRedaction
        settings.autoVerify = false
        settings.paranoidMode = false
        settings.fillColor = .white
        settings.exportDPI = 200

        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: settings)

        #expect(snapshot.pipelineMode == .searchableRedaction)
        #expect(snapshot.autoVerify == false)
        #expect(snapshot.paranoidMode == false)
        #expect(snapshot.fillColor == .white)
        #expect(snapshot.exportDPI == 200)
    }

    // MARK: - Independence from live SettingsState

    @Test("Mid-run SettingsState toggle of autoVerify does not affect a captured snapshot")
    func testMidRunSettingsToggleDoesNotAffectRun() {
        cleanSettingsDefaults()
        let settings = SettingsState()
        settings.autoVerify = true

        // Snapshot captured at run entry (mirrors `runFullPipeline`).
        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: settings)
        #expect(snapshot.autoVerify == true)

        // User mid-run toggles via SettingsView. The live state mutates,
        // but the snapshot — which the pipeline reads — does not.
        settings.autoVerify = false

        #expect(snapshot.autoVerify == true,
                "Snapshot must be immutable after capture (STATE-5).")
        #expect(settings.autoVerify == false,
                "Live SettingsState reflects the user's toggle for the *next* run.")
    }

    @Test("Mid-run toggle of paranoidMode does not affect a captured snapshot")
    func testParanoidModeSnapshotIndependence() {
        cleanSettingsDefaults()
        let settings = SettingsState()
        settings.paranoidMode = false

        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: settings)
        #expect(snapshot.paranoidMode == false)

        settings.paranoidMode = true
        #expect(snapshot.paranoidMode == false)
    }

    @Test("Mid-run toggle of pipelineMode does not affect a captured snapshot")
    func testPipelineModeSnapshotIndependence() {
        cleanSettingsDefaults()
        let settings = SettingsState()
        settings.pipelineMode = .secureRasterization

        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: settings)
        #expect(snapshot.pipelineMode == .secureRasterization)

        settings.pipelineMode = .searchableRedaction
        #expect(snapshot.pipelineMode == .secureRasterization)
    }

    @Test("Mid-run toggle of fillColor does not affect a captured snapshot")
    func testFillColorSnapshotIndependence() {
        cleanSettingsDefaults()
        let settings = SettingsState()
        settings.fillColor = .black

        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: settings)
        #expect(snapshot.fillColor == .black)

        settings.fillColor = .white
        #expect(snapshot.fillColor == .black)
    }

    @Test("Mid-run toggle of exportDPI does not affect a captured snapshot")
    func testExportDPISnapshotIndependence() {
        cleanSettingsDefaults()
        let settings = SettingsState()
        settings.exportDPI = 300

        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: settings)
        #expect(snapshot.exportDPI == 300)

        settings.exportDPI = 150
        #expect(snapshot.exportDPI == 300)
    }

    // MARK: - buildPDFPageData honors runSettings override

    @Test("buildPDFPageData routes fillColor / DPI through the runSettings snapshot")
    func buildPDFPageDataHonorsSnapshot() {
        cleanSettingsDefaults()
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()

        // Stamp a region so the page survives the AD-4-1 sub-threshold filter.
        let region = RedactionRegion.mock()
        coord.redactionState.regions[0] = [region]

        // Live settings say black + 300 DPI; snapshot pins white + 150.
        coord.settingsState.fillColor = .black
        coord.settingsState.exportDPI = 300

        let snapshot = PipelineCoordinator.RunSettings(
            pipelineMode: .secureRasterization,
            autoVerify: true,
            paranoidMode: false,
            fillColor: .white,
            exportDPI: 150
        )

        let pages = coord.buildPDFPageData(
            effectiveMode: .secureRasterization,
            runSettings: snapshot)
        let first = pages.first

        #expect(first?.fillColor == .white,
                "buildPDFPageData must read fillColor from the snapshot, not live settingsState.")
        #expect(first?.targetDPI == 150,
                "buildPDFPageData must read targetDPI from the snapshot, not live settingsState.")
    }

    @Test("buildPDFPageData with nil runSettings falls back to live settingsState (back-compat for tests)")
    func buildPDFPageDataNilSnapshotFallback() {
        cleanSettingsDefaults()
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.redactionState.regions[0] = [RedactionRegion.mock()]

        coord.settingsState.fillColor = .white
        coord.settingsState.exportDPI = 200

        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.first?.fillColor == .white)
        #expect(pages.first?.targetDPI == 200)
    }

    // MARK: - buildOCRSkipHint honors runSettings override

    @Test("buildOCRSkipHint routes pipelineMode through the runSettings snapshot")
    func buildOCRSkipHintHonorsSnapshot() {
        cleanSettingsDefaults()
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        // Mark page 0 as rich so non-mode gates pass.
        coord.documentState.textLayerStatus[0] = .rich

        // Live settings would allow OCR skip; snapshot forces .secureRasterization
        // which is the OCR-skip "hard stop" — buildOCRSkipHint must return nil.
        coord.settingsState.pipelineMode = .searchableRedaction

        let snapshot = PipelineCoordinator.RunSettings(
            pipelineMode: .secureRasterization,
            autoVerify: true,
            paranoidMode: false,
            fillColor: .black,
            exportDPI: 300
        )

        guard let doc = coord.documentState.sourceDocument,
              let page = doc.page(at: 0) else {
            Issue.record("Test fixture missing source page")
            return
        }
        let (source, _) = coord.buildOCRSkipHint(
            for: page, pageIndex: 0, runSettings: snapshot,
            textLayerStatus: coord.documentState.textLayerStatus)

        #expect(source == nil,
                "Snapshot pipelineMode=.secureRasterization must hard-stop OCR skip even when live settingsState says .searchableRedaction.")
    }

    // MARK: - CAT-041 (D-27b) — hint runs off the MainActor

    @Test("buildOCRSkipHint is nonisolated and runs off the MainActor (CAT-041)")
    func buildOCRSkipHintRunsOffMainActor() async {
        cleanSettingsDefaults()
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.documentState.textLayerStatus[0] = .rich

        // .secureRasterization hard-stops the hint → (nil, nil), so the result
        // is deterministic without running Vision/OCR on the simulator.
        let snapshot = PipelineCoordinator.RunSettings(
            pipelineMode: .secureRasterization,
            autoVerify: true,
            paranoidMode: false,
            fillColor: .black,
            exportDPI: 300
        )
        guard let doc = coord.documentState.sourceDocument,
              let page = doc.page(at: 0) else {
            Issue.record("Test fixture missing source page")
            return
        }
        let statusSnapshot = coord.documentState.textLayerStatus
        // Compiles + runs only because `buildOCRSkipHint` is `nonisolated`: a
        // MainActor-isolated method could not be invoked inside Task.detached.
        // PipelineCoordinator is Sendable so it crosses in directly; only the
        // non-Sendable PDFPage needs the unsafe capture.
        nonisolated(unsafe) let offMainPage = page
        let (source, _) = await Task.detached(priority: .userInitiated) {
            coord.buildOCRSkipHint(
                for: offMainPage, pageIndex: 0,
                runSettings: snapshot, textLayerStatus: statusSnapshot)
        }.value

        #expect(source == nil)
    }
}
