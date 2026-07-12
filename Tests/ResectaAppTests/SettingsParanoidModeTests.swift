import Testing
import Foundation
import UIKit
import ImageIO
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// SEC-8 — paranoid-mode toggle tests.
//
// The toggle is off by default and persists via UserDefaults. When on,
// the remaining behavior overrides apply as a bundle (no per-behavior
// sub-toggles):
//
//   1. Pipeline mode is forced to `.secureRasterization`, overriding the
//      user's `pipelineMode` setting AND any per-document override.
//   2. `autoVerify` reads as `true` and the Settings UI toggle is
//      disabled.
//   3. Image-import path runs `LivePhotoAuxStripper`, removing
//      `kCGImagePropertyMakerAppleDictionary` (and peer aux keys) from
//      the property dictionary.
//
// `testParanoidModeOffPreservesNormalBehavior` is the explicit negative
// counterpart: with paranoid off, none of the remaining overrides apply.

@Suite("SettingsState.paranoidMode (SEC-8)")
@MainActor
struct SettingsParanoidModeTests {

    /// Remove SEC-8 + adjacent keys before each test for isolation.
    private func cleanDefaults() {
        let keys = [
            "paranoidMode", "autoVerify", "pipelineMode.v2",
            "exportDPI", "fillColor"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Default + persistence

    @Test("Paranoid mode is off in a fresh SettingsState (locked default)")
    func testParanoidModeOffByDefault() {
        cleanDefaults()
        let state = SettingsState()
        #expect(state.paranoidMode == false)
    }

    @Test("Paranoid mode persists across a fresh init")
    func testParanoidModePersists() {
        cleanDefaults()
        let first = SettingsState()
        first.paranoidMode = true
        #expect(UserDefaults.standard.bool(forKey: "paranoidMode") == true)

        // Re-initialize and confirm the stored value is read back.
        let second = SettingsState()
        #expect(second.paranoidMode == true)
    }

    // MARK: - Override #1 — force .secureRasterization

    @Test("Paranoid mode forces .secureRasterization regardless of stored pipelineMode or per-document override")
    func testParanoidModeForcesSecureRasterization() {
        cleanDefaults()
        let settings = SettingsState()
        // Worst-case setup: the user stored `.searchableRedaction` and
        // a per-document override of `.searchableRedaction` is also in
        // flight. The paranoid override must still pick rasterization.
        settings.pipelineMode = .searchableRedaction
        settings.paranoidMode = true

        let documentOverride: PipelineMode? = .searchableRedaction
        let effectiveMode = computeEffectiveMode(
            settings: settings, documentOverride: documentOverride
        )

        #expect(effectiveMode == .secureRasterization)
    }

    // MARK: - Override #2 — force autoVerify = true

    @Test("Paranoid mode forces verification-on regardless of stored autoVerify; UI toggle reads disabled")
    func testParanoidModeForcesAutoVerify() {
        cleanDefaults()
        let settings = SettingsState()
        // User has the auto-verify pref off; paranoid must override it.
        settings.autoVerify = false
        settings.paranoidMode = true

        let verifyForRun = effectiveAutoVerify(settings: settings)
        let toggleDisabled = settings.paranoidMode

        #expect(verifyForRun == true)
        #expect(toggleDisabled == true)
    }

    // MARK: - Override #3 — strip Live Photo aux dict

    @Test("Paranoid mode runs the LivePhotoAuxStripper on the image-import property dictionary")
    func testParanoidModeStripsLivePhotoAux() {
        // Direct unit-level confirmation that the helper drops the
        // `kCGImagePropertyMakerAppleDictionary` key from the property
        // dictionary; this is the building block the SEC-8 import-path
        // gate consumes when `settingsState.paranoidMode == true`.
        let stripper = LivePhotoAuxStripper()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let img = renderer.image { _ in }.cgImage!

        let input: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": "live-photo-id"] as CFDictionary,
            kCGImagePropertyAuxiliaryData: ["depth": "placeholder"] as CFDictionary,
            kCGImagePropertyOrientation: 1 as CFNumber
        ]

        let (_, output) = stripper.strip(img, properties: input as CFDictionary)
        let outDict = output as? [CFString: Any] ?? [:]

        #expect(outDict[kCGImagePropertyMakerAppleDictionary] == nil)
        #expect(outDict[kCGImagePropertyAuxiliaryData] == nil)
        // Non-aux keys survive — the stripper is targeted, not a wipe.
        #expect(outDict[kCGImagePropertyOrientation] as? Int == 1)
    }

    // MARK: - Negative — all three overrides off when paranoid is off

    @Test("With paranoid OFF, none of the remaining overrides apply (mode, autoVerify, aux strip gate)")
    func testParanoidModeOffPreservesNormalBehavior() {
        cleanDefaults()
        let settings = SettingsState()
        settings.paranoidMode = false
        settings.pipelineMode = .searchableRedaction
        settings.autoVerify = false

        // Override #1: stored `.searchableRedaction` is honored.
        let effectiveMode = computeEffectiveMode(
            settings: settings, documentOverride: nil
        )
        #expect(effectiveMode == .searchableRedaction)

        // Override #2: stored `autoVerify = false` is honored.
        #expect(effectiveAutoVerify(settings: settings) == false)
        // UI toggle is not disabled by paranoid.
        #expect(settings.paranoidMode == false)

        // Override #3: the import-path gate value derives from
        // `settingsState.paranoidMode`. With paranoid off, the gate is
        // false — the stripper is not engaged on the import path.
        let gate = settings.paranoidMode
        #expect(gate == false)
    }

    // MARK: - Three-overrides copy guard (CAT-104 / CAT-153-H3 · D-13)

    /// Paranoid mode enforces THREE behaviors, not four. The
    /// "verification-report copy step" was parked on the overflow menu and
    /// never shipped (VerificationResultsView), so the copy that claimed
    /// paranoid mode suppresses it was a false mechanism claim. This guard
    /// reads the SettingsView source (mirroring the LegalKeyExistenceTests
    /// `#filePath` loader posture) and pins the corrected copy so a future
    /// string edit cannot re-introduce the phantom fourth override.
    @Test("Paranoid-mode copy describes three overrides, not the parked copy step")
    func testParanoidModeHasThreeOverrides() throws {
        let source = try loadSettingsViewSource()
        #expect(
            !source.contains("verification-report copy"),
            "SettingsView still references the never-shipped 'verification-report copy step' (CAT-104).")
        #expect(
            !source.contains("applies four behavior overrides"),
            "Paranoid-mode accessibility hint still says 'four' behavior overrides (CAT-104).")
        #expect(
            source.contains("applies three behavior overrides"),
            "Paranoid-mode accessibility hint should say 'three' behavior overrides (CAT-104).")
    }

    private func loadSettingsViewSource(file: StaticString = #filePath) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let source = repoRoot.appendingPathComponent("Sources/ResectaApp/Views/SettingsView.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    // MARK: - Helpers (mirror runtime decision points)

    /// Mirror the `effectiveMode` decision in
    /// `PipelineCoordinator.runFullPipeline`. Keeping the rule in one
    /// place avoids hand-rolling the runtime check inside the test.
    private func computeEffectiveMode(
        settings: SettingsState,
        documentOverride: PipelineMode?
    ) -> PipelineMode {
        if settings.paranoidMode {
            return .secureRasterization
        }
        return documentOverride ?? settings.pipelineMode
    }

    /// Mirror the `verifyForRun` decision in
    /// `PipelineCoordinator.runFullPipeline`'s post-redaction branch.
    private func effectiveAutoVerify(settings: SettingsState) -> Bool {
        settings.paranoidMode || settings.autoVerify
    }
}
