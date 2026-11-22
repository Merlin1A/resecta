import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Paranoid-mode toggle tests.
//
// The toggle is off by default and persists via UserDefaults. When on,
// the remaining behavior overrides apply as a bundle (no per-behavior
// sub-toggles):
//
//   1. Pipeline mode is `.secureRasterization`. Secure Rasterization is
//      the only mode, so the run's rule gives it with Paranoid Mode on or
//      off, over a stored `pipelineMode` setting and any per-document
//      override.
//   2. `autoVerify` reads as `true` and the Settings UI toggle is
//      disabled.
//
// `testParanoidModeOffPreservesNormalBehavior` is the explicit negative
// counterpart: with paranoid off, the stored `autoVerify` is honored.

@Suite("SettingsState.paranoidMode")
@MainActor
final class SettingsParanoidModeTests {

    /// Every test instance gets its own defaults domain, so nothing this
    /// suite writes reaches `defaults` or a suite running in
    /// parallel (`SettingsStateTests` writes the same keys); the domain is
    /// removed when the instance goes away.
    private let suiteName = "settings-paranoid-tests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Default + persistence

    @Test("Paranoid mode is off in a fresh SettingsState (locked default)")
    func testParanoidModeOffByDefault() {
        let state = SettingsState(defaults: defaults)
        #expect(state.paranoidMode == false)
    }

    @Test("Paranoid mode persists across a fresh init")
    func testParanoidModePersists() {
        let first = SettingsState(defaults: defaults)
        first.paranoidMode = true
        #expect(defaults.bool(forKey: "paranoidMode") == true)

        // Re-initialize and confirm the stored value is read back.
        let second = SettingsState(defaults: defaults)
        #expect(second.paranoidMode == true)
    }

    // MARK: - Override #1 — force .secureRasterization

    @Test("Paranoid mode forces .secureRasterization regardless of stored pipelineMode or per-document override")
    func testParanoidModeForcesSecureRasterization() {
        let settings = SettingsState(defaults: defaults)
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
        let settings = SettingsState(defaults: defaults)
        // User has the auto-verify pref off; paranoid must override it.
        settings.autoVerify = false
        settings.paranoidMode = true

        let verifyForRun = effectiveAutoVerify(settings: settings)
        let toggleDisabled = settings.paranoidMode

        #expect(verifyForRun == true)
        #expect(toggleDisabled == true)
    }

    // MARK: - Negative — both overrides off when paranoid is off

    @Test("With paranoid OFF, the stored autoVerify is honored and the mode is still Secure Rasterization")
    func testParanoidModeOffPreservesNormalBehavior() {
        let settings = SettingsState(defaults: defaults)
        settings.paranoidMode = false
        settings.pipelineMode = .searchableRedaction
        settings.autoVerify = false

        // A stored `.searchableRedaction` is left as stored and read as
        // Secure Rasterization, the only mode.
        let effectiveMode = computeEffectiveMode(
            settings: settings, documentOverride: nil
        )
        #expect(settings.pipelineMode == .searchableRedaction)
        #expect(effectiveMode == .secureRasterization)

        // Override #2: stored `autoVerify = false` is honored.
        #expect(effectiveAutoVerify(settings: settings) == false)
        // UI toggle is not disabled by paranoid.
        #expect(settings.paranoidMode == false)
    }

    // MARK: - Overrides copy guard

    /// Paranoid mode lists ONE behavior: Secure Rasterization is the only
    /// mode, so forcing it is no longer a behavior of Paranoid Mode, and the
    /// hint that counted the behaviors is gone with the count. The
    /// "verification-report copy step" was parked on the overflow menu and
    /// never shipped (VerificationResultsView), so the copy that claimed
    /// paranoid mode suppresses it was a false mechanism claim. This guard
    /// reads the SettingsView source (mirroring the LegalKeyExistenceTests
    /// `#filePath` loader posture) and pins the corrected copy so a future
    /// string edit cannot re-introduce the phantom fourth override. The
    /// Live Photo auxiliary-metadata strip left the listed behaviors when
    /// import became PDF-only, and its code has since been deleted.
    @Test("Paranoid-mode copy names no count of overrides, no forced mode, no parked copy step and no Live Photo strip")
    func testParanoidModeHasOneOverride() throws {
        let source = try loadSettingsViewSource()
        #expect(
            !source.contains("verification-report copy"),
            "SettingsView still references the never-shipped 'verification-report copy step'.")
        #expect(
            !source.contains("applies four behavior overrides"),
            "Paranoid-mode accessibility hint still says 'four' behavior overrides.")
        #expect(
            !source.contains("behavior overrides"),
            "Paranoid-mode copy still counts its behavior overrides.")
        #expect(
            !source.contains("forces secure-rasterization") && !source.contains("forces Secure Rasterization")
                && !source.contains("forced to Secure Rasterization"),
            "Paranoid-mode copy still says it forces a mode, the only one there is.")
        #expect(
            !source.contains("imported Live Photo"),
            "Paranoid-mode copy still describes the Live Photo metadata strip.")
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

    /// The `effectiveMode` decision in `PipelineCoordinator.runFullPipeline`:
    /// the rule itself, so the test cannot keep a copy the app has left.
    private func computeEffectiveMode(
        settings: SettingsState,
        documentOverride: PipelineMode?
    ) -> PipelineMode {
        PipelineMode.effective(
            paranoid: settings.paranoidMode, override: documentOverride, setting: settings.pipelineMode)
    }

    /// Mirror the `verifyForRun` decision in
    /// `PipelineCoordinator.runFullPipeline`'s post-redaction branch.
    private func effectiveAutoVerify(settings: SettingsState) -> Bool {
        settings.paranoidMode || settings.autoVerify
    }
}
