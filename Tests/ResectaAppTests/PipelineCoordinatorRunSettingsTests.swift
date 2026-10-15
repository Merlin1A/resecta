import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Settings snapshot at run entry.
//
// `RunSettings` captures pipeline-affecting settings once at the top of
// `runFullPipeline`, mirroring the existing
// `effectiveMode` snapshot pattern. Mid-run reads of
// `autoVerify`, `paranoidMode`, `pipelineMode`, `fillColor`, and
// `exportDPI` route through the snapshot — a user toggling SettingsView
// during `.redacting / .verifying` cannot divert kickoff-
// time behavior from run-time behavior.
//
// These tests pin the snapshot value itself (independence from the live
// SettingsState after capture). The end-to-end "mid-run toggle does not
// affect the run" contract is enforced structurally by the runSettings
// threading in `runFullPipeline`; the live pipeline path is exercised by
// `FullPipelineFlowTests`, which already round-trips the run-entry
// snapshot.

@Suite("PipelineCoordinator.RunSettings")
@MainActor
struct PipelineCoordinatorRunSettingsTests {

    // MARK: - Snapshot capture

    @Test("Snapshot captures all five pipeline-affecting fields")
    func snapshotCapturesAllFields() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsState(defaults: defaults)
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
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsState(defaults: defaults)
        settings.autoVerify = true

        // Snapshot captured at run entry (mirrors `runFullPipeline`).
        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: settings)
        #expect(snapshot.autoVerify == true)

        // User mid-run toggles via SettingsView. The live state mutates,
        // but the snapshot — which the pipeline reads — does not.
        settings.autoVerify = false

        #expect(snapshot.autoVerify == true,
                "Snapshot must be immutable after capture.")
        #expect(settings.autoVerify == false,
                "Live SettingsState reflects the user's toggle for the *next* run.")
    }

    @Test("Mid-run toggle of paranoidMode does not affect a captured snapshot")
    func testParanoidModeSnapshotIndependence() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsState(defaults: defaults)
        settings.paranoidMode = false

        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: settings)
        #expect(snapshot.paranoidMode == false)

        settings.paranoidMode = true
        #expect(snapshot.paranoidMode == false)
    }

    @Test("Mid-run toggle of pipelineMode does not affect a captured snapshot")
    func testPipelineModeSnapshotIndependence() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsState(defaults: defaults)
        settings.pipelineMode = .secureRasterization

        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: settings)
        #expect(snapshot.pipelineMode == .secureRasterization)

        settings.pipelineMode = .searchableRedaction
        #expect(snapshot.pipelineMode == .secureRasterization)
    }

    @Test("Mid-run toggle of fillColor does not affect a captured snapshot")
    func testFillColorSnapshotIndependence() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsState(defaults: defaults)
        settings.fillColor = .black

        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: settings)
        #expect(snapshot.fillColor == .black)

        settings.fillColor = .white
        #expect(snapshot.fillColor == .black)
    }

    @Test("Mid-run toggle of exportDPI does not affect a captured snapshot")
    func testExportDPISnapshotIndependence() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsState(defaults: defaults)
        settings.exportDPI = 300

        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: settings)
        #expect(snapshot.exportDPI == 300)

        settings.exportDPI = 150
        #expect(snapshot.exportDPI == 300)
    }

    // MARK: - buildPDFPageData honors runSettings override

    @Test("buildPDFPageData routes fillColor / DPI through the runSettings snapshot")
    func buildPDFPageDataHonorsSnapshot() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coord = makeCoordinator(settingsState: SettingsState(defaults: defaults))
        coord.documentState.sourceDocument = makeTestPDFDocument()

        // Stamp a region so the page survives the sub-threshold filter.
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
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coord = makeCoordinator(settingsState: SettingsState(defaults: defaults))
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.redactionState.regions[0] = [RedactionRegion.mock()]

        coord.settingsState.fillColor = .white
        coord.settingsState.exportDPI = 200

        let pages = coord.buildPDFPageData(effectiveMode: .secureRasterization)
        #expect(pages.first?.fillColor == .white)
        #expect(pages.first?.targetDPI == 200)
    }
}
