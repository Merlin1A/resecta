import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

@Suite("SettingsState Persistence")
@MainActor
final class SettingsStateTests {

    /// Every test instance gets its own defaults domain, so nothing this
    /// suite writes reaches `defaults` or a suite running in
    /// parallel (`SettingsParanoidModeTests` writes the same keys); the
    /// domain is removed when the instance goes away.
    private let suiteName = "settings-state-tests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Default Values

    @Test("Fresh init with no stored values yields correct defaults")
    func defaultValues() {
        let state = SettingsState(defaults: defaults)
        #expect(state.exportDPI == 300)
        #expect(state.fillColor == .black)
        #expect(state.autoVerify == true)
        #expect(state.pipelineMode == .secureRasterization)
    }

    // MARK: - DPI Clamping

    @Test("DPI 150 is accepted", arguments: [150, 200, 300])
    func dpiValidValues(_ dpi: Int) {
        defaults.set(dpi, forKey: "exportDPI")
        let state = SettingsState(defaults: defaults)
        #expect(state.exportDPI == dpi)
    }

    @Test("Invalid DPI falls back to 300", arguments: [0, -1, 100, 250, 400, 999])
    func dpiInvalidFallback(_ dpi: Int) {
        defaults.set(dpi, forKey: "exportDPI")
        let state = SettingsState(defaults: defaults)
        #expect(state.exportDPI == 300)
    }

    // MARK: - FillColor

    @Test("FillColor round-trips through UserDefaults")
    func fillColorRoundTrip() {
        defaults.set("white", forKey: "fillColor")
        let state = SettingsState(defaults: defaults)
        #expect(state.fillColor == .white)
    }

    @Test("Invalid fillColor falls back to black")
    func fillColorInvalidFallback() {
        defaults.set("red", forKey: "fillColor")
        let state = SettingsState(defaults: defaults)
        #expect(state.fillColor == .black)
    }

    // MARK: - AutoVerify

    @Test("autoVerify false persists and reads back")
    func autoVerifyFalse() {
        defaults.set(false, forKey: "autoVerify")
        let state = SettingsState(defaults: defaults)
        #expect(state.autoVerify == false)
    }

    @Test("Missing autoVerify key defaults to true")
    func autoVerifyMissing() {
        let state = SettingsState(defaults: defaults)
        #expect(state.autoVerify == true)
    }

    // MARK: - PipelineMode

    @Test("PipelineMode round-trips through UserDefaults")
    func pipelineModeRoundTrip() {
        defaults.set("searchableRedaction", forKey: "pipelineMode.v2")
        let state = SettingsState(defaults: defaults)
        #expect(state.pipelineMode == .searchableRedaction)
    }

    @Test("Invalid pipelineMode falls back to secureRasterization")
    func pipelineModeInvalidFallback() {
        defaults.set("invalidMode", forKey: "pipelineMode.v2")
        let state = SettingsState(defaults: defaults)
        #expect(state.pipelineMode == .secureRasterization)
    }

    // MARK: - S7 / design 03 §3.6 — detection preset + active vector

    @Test("detectionPreset defaults to balanced with no stored value")
    func detectionPresetDefault() {
        let state = SettingsState(defaults: defaults)
        #expect(state.detectionPreset == .balanced)
    }

    @Test("detectionPreset round-trips through UserDefaults")
    func detectionPresetRoundTrip() {
        let state = SettingsState(defaults: defaults)
        state.detectionPreset = .conservative
        #expect(defaults.string(forKey: "detectionPreset.v1") == "conservative")
        let rehydrated = SettingsState(defaults: defaults)
        #expect(rehydrated.detectionPreset == .conservative)
    }

    @Test("Invalid stored preset falls back to balanced")
    func detectionPresetInvalidFallback() {
        defaults.set("turbo", forKey: "detectionPreset.v1")
        let state = SettingsState(defaults: defaults)
        #expect(state.detectionPreset == .balanced)
    }

    @Test("Switching balanced→conservative changes the active gating vector")
    func presetSwitchChangesActiveVector() {
        let state = SettingsState(defaults: defaults)
        let balanced = state.activeThresholdVector
        state.detectionPreset = .conservative
        let conservative = state.activeThresholdVector

        // At least one category must gate differently across the two
        // calibrated vectors — that difference IS the picker's effect on
        // scan behavior (exit criterion 3).
        let differs = PIICategory.allCases.contains { category in
            balanced.threshold(for: category) != conservative.threshold(for: category)
        }
        #expect(differs, "conservative and balanced vectors must not be identical")
    }

    @Test("Engine bundle carries all three presets (fallback unused in production)")
    func engineBundleCarriesAllPresets() {
        let bundle = PresetThresholdBundle.loadFromEngineBundle()
        for preset in SettingsPreset.allCases {
            #expect(bundle.presets[preset] != nil,
                    "calibrated bundle must carry \(preset.rawValue)")
        }
    }

    @Test("Preset display labels read Sensitive for aggressive")
    func presetDisplayLabels() {
        #expect(SettingsPreset.conservative.displayLabel == "Conservative")
        #expect(SettingsPreset.balanced.displayLabel == "Balanced")
        #expect(SettingsPreset.aggressive.displayLabel == "Sensitive")
        for preset in SettingsPreset.allCases {
            #expect(!preset.mechanismDescription.isEmpty)
        }
    }

    @Test("resetToDefaults restores the balanced preset")
    func resetRestoresBalancedPreset() {
        let state = SettingsState(defaults: defaults)
        state.detectionPreset = .aggressive
        state.resetToDefaults()
        #expect(state.detectionPreset == .balanced)
    }

    // MARK: - didSet Persistence

    @Test("Setting exportDPI triggers immediate UserDefaults write")
    func didSetDPI() {
        let state = SettingsState(defaults: defaults)
        state.exportDPI = 200
        #expect(defaults.integer(forKey: "exportDPI") == 200)
    }

    @Test("Setting fillColor triggers immediate UserDefaults write")
    func didSetFillColor() {
        let state = SettingsState(defaults: defaults)
        state.fillColor = .white
        #expect(defaults.string(forKey: "fillColor") == "white")
    }

    @Test("Setting autoVerify triggers immediate UserDefaults write")
    func didSetAutoVerify() {
        let state = SettingsState(defaults: defaults)
        state.autoVerify = false
        #expect(defaults.bool(forKey: "autoVerify") == false)
    }

    @Test("Setting pipelineMode writes through to UserDefaults at pipelineMode.v2")
    func didSetPipelineMode() {
        let state = SettingsState(defaults: defaults)
        state.pipelineMode = .searchableRedaction
        #expect(defaults.string(forKey: "pipelineMode.v2") == "searchableRedaction")
        #expect(state.pipelineMode == .searchableRedaction)
    }

    // MARK: - Retired auto-apply preference (stale-key cleanup)

    @Test("Init removes the retired autoApplyDetections key")
    func initRemovesRetiredAutoApplyKey() {
        // A value persisted by an earlier build. The setting is gone —
        // every detection run stages for review — so init removes the
        // stale key rather than hydrating it.
        defaults.set(true, forKey: "autoApplyDetections")
        _ = SettingsState(defaults: defaults)
        #expect(defaults.object(forKey: "autoApplyDetections") == nil)
    }

    @Test("Retired-key cleanup is idempotent across inits")
    func retiredAutoApplyCleanupIdempotent() {
        _ = SettingsState(defaults: defaults)
        _ = SettingsState(defaults: defaults)
        #expect(defaults.object(forKey: "autoApplyDetections") == nil)
    }

    // MARK: - resetToDefaults

    @Test("resetToDefaults snaps every scalar back to defaults")
    func resetClearsAll() {
        let state = SettingsState(defaults: defaults)
        state.exportDPI = 200
        state.fillColor = .white
        state.autoVerify = false
        state.pipelineMode = .searchableRedaction
        state.resetToDefaults()
        #expect(state.exportDPI == 300)
        #expect(state.fillColor == .black)
        #expect(state.autoVerify == true)
        #expect(state.pipelineMode == .secureRasterization)
    }

    @Test("resetToDefaults preserves successfulExportCount (lifetime review-gate metric, CAT-400)")
    func resetPreservesSuccessfulExportCount() {
        let state = SettingsState(defaults: defaults)
        state.successfulExportCount = 5
        state.resetToDefaults()
        // CAT-400: the count gates the StoreKit review prompt (fires once as it
        // crosses 2 -> 3). It is a lifetime metric, not a preference, so a
        // Settings reset must not zero it and re-arm the prompt.
        #expect(state.successfulExportCount == 5)
    }
}
