import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

@Suite("SettingsState Persistence")
@MainActor
struct SettingsStateTests {

    // Keys SettingsState now writes after the general-purpose pivot. The
    // profile-store keys + detection-preset/override/customUserTerms
    // legacy keys are gone; saved regexes and user terms moved to
    // SavedRegexStore / UserTermsStore (own UserDefaults blobs).
    private static let keys = [
        "exportDPI",
        "fillColor",
        "autoVerify",
        "successfulExportCount",
        "pipelineMode.v2",
        "autoApplyDetections",
        "detectionPreset.v1",
        "search.recents.enabled.v1",  // design 04 §4.6
    ]

    /// Remove all SettingsState keys before each test to ensure isolation.
    private func cleanDefaults() {
        for key in Self.keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Default Values

    @Test("Fresh init with no stored values yields correct defaults")
    func defaultValues() {
        cleanDefaults()
        let state = SettingsState()
        #expect(state.exportDPI == 300)
        #expect(state.fillColor == .black)
        #expect(state.autoVerify == true)
        #expect(state.pipelineMode == .secureRasterization)
        #expect(state.autoApplyDetections == false)
    }

    // MARK: - DPI Clamping

    @Test("DPI 150 is accepted", arguments: [150, 200, 300])
    func dpiValidValues(_ dpi: Int) {
        cleanDefaults()
        UserDefaults.standard.set(dpi, forKey: "exportDPI")
        let state = SettingsState()
        #expect(state.exportDPI == dpi)
    }

    @Test("Invalid DPI falls back to 300", arguments: [0, -1, 100, 250, 400, 999])
    func dpiInvalidFallback(_ dpi: Int) {
        cleanDefaults()
        UserDefaults.standard.set(dpi, forKey: "exportDPI")
        let state = SettingsState()
        #expect(state.exportDPI == 300)
    }

    // MARK: - FillColor

    @Test("FillColor round-trips through UserDefaults")
    func fillColorRoundTrip() {
        cleanDefaults()
        UserDefaults.standard.set("white", forKey: "fillColor")
        let state = SettingsState()
        #expect(state.fillColor == .white)
    }

    @Test("Invalid fillColor falls back to black")
    func fillColorInvalidFallback() {
        cleanDefaults()
        UserDefaults.standard.set("red", forKey: "fillColor")
        let state = SettingsState()
        #expect(state.fillColor == .black)
    }

    // MARK: - AutoVerify

    @Test("autoVerify false persists and reads back")
    func autoVerifyFalse() {
        cleanDefaults()
        UserDefaults.standard.set(false, forKey: "autoVerify")
        let state = SettingsState()
        #expect(state.autoVerify == false)
    }

    @Test("Missing autoVerify key defaults to true")
    func autoVerifyMissing() {
        cleanDefaults()
        let state = SettingsState()
        #expect(state.autoVerify == true)
    }

    // MARK: - PipelineMode

    @Test("PipelineMode round-trips through UserDefaults")
    func pipelineModeRoundTrip() {
        cleanDefaults()
        UserDefaults.standard.set("searchableRedaction", forKey: "pipelineMode.v2")
        let state = SettingsState()
        #expect(state.pipelineMode == .searchableRedaction)
    }

    @Test("Invalid pipelineMode falls back to secureRasterization")
    func pipelineModeInvalidFallback() {
        cleanDefaults()
        UserDefaults.standard.set("invalidMode", forKey: "pipelineMode.v2")
        let state = SettingsState()
        #expect(state.pipelineMode == .secureRasterization)
    }

    // MARK: - S7 / design 03 §3.6 — detection preset + active vector

    @Test("detectionPreset defaults to balanced with no stored value")
    func detectionPresetDefault() {
        cleanDefaults()
        let state = SettingsState()
        #expect(state.detectionPreset == .balanced)
    }

    @Test("detectionPreset round-trips through UserDefaults")
    func detectionPresetRoundTrip() {
        cleanDefaults()
        let state = SettingsState()
        state.detectionPreset = .conservative
        #expect(UserDefaults.standard.string(forKey: "detectionPreset.v1") == "conservative")
        let rehydrated = SettingsState()
        #expect(rehydrated.detectionPreset == .conservative)
        cleanDefaults()
    }

    @Test("Invalid stored preset falls back to balanced")
    func detectionPresetInvalidFallback() {
        cleanDefaults()
        UserDefaults.standard.set("turbo", forKey: "detectionPreset.v1")
        let state = SettingsState()
        #expect(state.detectionPreset == .balanced)
        cleanDefaults()
    }

    @Test("Switching balanced→conservative changes the active gating vector")
    func presetSwitchChangesActiveVector() {
        cleanDefaults()
        let state = SettingsState()
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
        cleanDefaults()
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
        cleanDefaults()
        let state = SettingsState()
        state.detectionPreset = .aggressive
        state.resetToDefaults()
        #expect(state.detectionPreset == .balanced)
        cleanDefaults()
    }

    // MARK: - design 04 §4.6 — saveRecentSearches round-trip

    @Test("saveRecentSearches defaults to true with no stored value")
    func saveRecentSearchesDefault() {
        cleanDefaults()
        let state = SettingsState()
        #expect(state.saveRecentSearches == true)
    }

    @Test("saveRecentSearches false persists and reads back")
    func saveRecentSearchesRoundTrip() {
        cleanDefaults()
        let state = SettingsState()
        state.saveRecentSearches = false
        #expect(UserDefaults.standard.object(forKey: "search.recents.enabled.v1") as? Bool == false)
        let rehydrated = SettingsState()
        #expect(rehydrated.saveRecentSearches == false)
        cleanDefaults()
    }

    @Test("saveRecentSearches true persists and reads back")
    func saveRecentSearchesTrueRoundTrip() {
        cleanDefaults()
        let state = SettingsState()
        state.saveRecentSearches = false  // set to false first
        state.saveRecentSearches = true   // then back to true
        #expect(UserDefaults.standard.object(forKey: "search.recents.enabled.v1") as? Bool == true)
        let rehydrated = SettingsState()
        #expect(rehydrated.saveRecentSearches == true)
        cleanDefaults()
    }

    @Test("resetToDefaults restores saveRecentSearches to true")
    func resetRestoresSaveRecentSearches() {
        cleanDefaults()
        let state = SettingsState()
        state.saveRecentSearches = false
        state.resetToDefaults()
        #expect(state.saveRecentSearches == true)
        cleanDefaults()
    }

    // MARK: - didSet Persistence

    @Test("Setting exportDPI triggers immediate UserDefaults write")
    func didSetDPI() {
        cleanDefaults()
        let state = SettingsState()
        state.exportDPI = 200
        #expect(UserDefaults.standard.integer(forKey: "exportDPI") == 200)
    }

    @Test("Setting fillColor triggers immediate UserDefaults write")
    func didSetFillColor() {
        cleanDefaults()
        let state = SettingsState()
        state.fillColor = .white
        #expect(UserDefaults.standard.string(forKey: "fillColor") == "white")
    }

    @Test("Setting autoVerify triggers immediate UserDefaults write")
    func didSetAutoVerify() {
        cleanDefaults()
        let state = SettingsState()
        state.autoVerify = false
        #expect(UserDefaults.standard.bool(forKey: "autoVerify") == false)
    }

    @Test("Setting pipelineMode writes through to UserDefaults at pipelineMode.v2")
    func didSetPipelineMode() {
        cleanDefaults()
        let state = SettingsState()
        state.pipelineMode = .searchableRedaction
        #expect(UserDefaults.standard.string(forKey: "pipelineMode.v2") == "searchableRedaction")
        #expect(state.pipelineMode == .searchableRedaction)
    }

    // MARK: - AutoApplyDetections (GAP §2.4)

    @Test("autoApplyDetections true persists and reads back")
    func autoApplyDetectionsTrue() {
        cleanDefaults()
        UserDefaults.standard.set(true, forKey: "autoApplyDetections")
        let state = SettingsState()
        #expect(state.autoApplyDetections == true)
    }

    @Test("Missing autoApplyDetections key defaults to false")
    func autoApplyDetectionsMissing() {
        cleanDefaults()
        let state = SettingsState()
        #expect(state.autoApplyDetections == false)
    }

    @Test("Setting autoApplyDetections triggers immediate UserDefaults write")
    func didSetAutoApplyDetections() {
        cleanDefaults()
        let state = SettingsState()
        state.autoApplyDetections = true
        #expect(UserDefaults.standard.bool(forKey: "autoApplyDetections") == true)
        #expect(state.autoApplyDetections == true)
    }

    // MARK: - resetToDefaults

    @Test("resetToDefaults snaps every scalar back to defaults")
    func resetClearsAll() {
        cleanDefaults()
        let state = SettingsState()
        state.exportDPI = 200
        state.fillColor = .white
        state.autoVerify = false
        state.pipelineMode = .searchableRedaction
        state.autoApplyDetections = true
        state.resetToDefaults()
        #expect(state.exportDPI == 300)
        #expect(state.fillColor == .black)
        #expect(state.autoVerify == true)
        #expect(state.pipelineMode == .secureRasterization)
        #expect(state.autoApplyDetections == false)
    }

    @Test("resetToDefaults preserves successfulExportCount (lifetime review-gate metric, CAT-400)")
    func resetPreservesSuccessfulExportCount() {
        cleanDefaults()
        let state = SettingsState()
        state.successfulExportCount = 5
        state.resetToDefaults()
        // CAT-400: the count gates the StoreKit review prompt (fires once as it
        // crosses 2 -> 3). It is a lifetime metric, not a preference, so a
        // Settings reset must not zero it and re-arm the prompt.
        #expect(state.successfulExportCount == 5)
        cleanDefaults()
    }
}
