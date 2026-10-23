import Foundation
import SwiftUI
import RedactionEngine

// UserDefaults with didSet — NOT @AppStorage inside @Observable.
//
// Post-pivot shape: profile-scoped state (preset / per-category overrides
// / saved regexes / user terms / FOIA exemption / ZIP overrides) is gone.
// Saved regexes and custom terms live on their own app-wide @Observable
// stores (`SavedRegexStore`, `UserTermsStore`); `SettingsState` now
// carries only the plain scalar prefs the rest of the app reads at scan
// kickoff and export.

/// User appearance preference. Persisted in UserDefaults via SettingsState.
/// Mapped to SwiftUI's preferredColorScheme at the root of WindowGroup.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// Maps to the value SwiftUI consumes. `nil` means "no override".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// User-facing label. Mechanism-description (no outcome language).
    var displayLabel: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

/// User preferences persisted via UserDefaults.
@Observable
class SettingsState {
    /// Guards didSet during init to avoid redundant UserDefaults writes.
    private var isInitializing = true

    /// Stored values of settings that no longer exist, removed on load.
    static let retiredDefaultsKeys = ["snapToTextEnabled", "successfulExportCount"]

    /// The store every preference reads from and writes to. Production uses
    /// `.standard`; a test passes its own suite so parallel suites never
    /// share keys.
    private let defaults: UserDefaults

    // MARK: - App-wide scalars

    var exportDPI: Int = 300 {
        didSet { guard !isInitializing else { return }
                defaults.set(exportDPI, forKey: "exportDPI") }
    }
    var fillColor: FillColor = .black {
        didSet { guard !isInitializing else { return }
                defaults.set(fillColor.rawValue, forKey: "fillColor") }
    }
    var autoVerify: Bool = true {
        didSet { guard !isInitializing else { return }
                defaults.set(autoVerify, forKey: "autoVerify") }
    }

    /// App-wide pipeline preference read at scan kickoff and export.
    /// `.secureRasterization` is the default fallback.
    var pipelineMode: PipelineMode = .secureRasterization {
        didSet { guard !isInitializing else { return }
                defaults.set(pipelineMode.rawValue, forKey: "pipelineMode.v2") }
    }

    /// Opt-in paranoid-mode toggle.
    /// Off by default. When on, the app applies two behavior overrides
    /// (numbered #1/#2 at their call sites): pipeline mode is forced to
    /// `.secureRasterization`; `autoVerify` is forced to `true` (UI toggle
    /// disabled while paranoid is on). Mechanism-description language: the
    /// bundle is designed to reduce the surface area of optional side
    /// channels; behavior is best-effort.
    var paranoidMode: Bool = false {
        didSet { guard !isInitializing else { return }
                defaults.set(paranoidMode, forKey: "paranoidMode") }
    }

    /// Appearance preference. Drives SwiftUI .preferredColorScheme at the
    /// WindowGroup root. Default is .system so first-launch users see the
    /// OS-level setting honored. Persists via the file-header pattern.
    var appearancePreference: AppearancePreference = .system {
        didSet { guard !isInitializing else { return }
                defaults.set(appearancePreference.rawValue, forKey: "appearancePreference.v1") }
    }

    // MARK: - Detection preset + threshold vector

    /// User-selected detection preset. Drives `activeThresholdVector` at
    /// every scan kickoff; the picker SELECTS one of the calibrated
    /// vectors, it never edits threshold values.
    var detectionPreset: SettingsPreset = .balanced {
        didSet { guard !isInitializing else { return }
                defaults.set(detectionPreset.rawValue, forKey: "detectionPreset.v1") }
    }

    /// Engine preset bundle, parsed once per app lifetime (the bundled
    /// JSON is immutable at runtime). `loadFromEngineBundle()` is
    /// non-throwing; the calibrated file ships, so production
    /// builds never reach the built-in fallback — pinned by
    /// `SettingsStateDetectionPresetTests.engineBundleCarriesAllPresets`.
    private static let engineThresholdBundle = PresetThresholdBundle.loadFromEngineBundle()

    /// Threshold vector for the user-selected preset. Replaces the
    /// former `static let defaultThresholdVector` (always `.balanced`)
    /// at all three call sites: PipelineCoordinator scan kickoff,
    /// SearchAndRedactSheet+Trigger, ReverseRationalePopover.
    var activeThresholdVector: PresetThresholdVector {
        Self.thresholdVector(for: detectionPreset)
    }

    /// Preset → vector lookup, kept static + parameterized so tests can
    /// assert vector identity per preset without an instance.
    static func thresholdVector(for preset: SettingsPreset) -> PresetThresholdVector {
        engineThresholdBundle.presets[preset]
            ?? PresetThresholdBundle.builtInDefaults.presets[preset]
            ?? PresetThresholdVector(thresholdsByWireName: [:])
    }

    // MARK: - Init

    /// DPI clamped to [150, 200, 300] with 300 default.
    /// Invalid stored values fall through to defaults safely.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.object(forKey: "exportDPI") as? Int ?? 300
        self.exportDPI = [150, 200, 300].contains(raw) ? raw : 300
        self.fillColor = FillColor(rawValue:
            defaults.string(forKey: "fillColor") ?? "black") ?? .black
        self.autoVerify = defaults.object(forKey: "autoVerify") as? Bool ?? true
        let storedMode = defaults.string(forKey: "pipelineMode.v2")
        self.pipelineMode = storedMode
            .flatMap(PipelineMode.init(rawValue:)) ?? .secureRasterization
        // One-time cleanup of retired preferences, removed rather than
        // hydrated: the auto-apply setting, and the per-category accept
        // and reject counts that only the removed detection review
        // recorded. Upgraded installs still hold them, and the preference
        // store goes into device backups. Idempotent removeObject-on-init
        // (nothing writes these keys anymore), mirroring
        // `SavedSearchStore.legacyDefaultsKey`.
        defaults.removeObject(forKey: "perCategoryPriors.v1")
        defaults.removeObject(forKey: "autoApplyDetections")
        // The snap-to-text preference and the export counter that timed the
        // old rating prompt are retired too; their stored values go the
        // same way.
        for key in Self.retiredDefaultsKeys { defaults.removeObject(forKey: key) }
        self.paranoidMode = defaults.object(forKey: "paranoidMode") as? Bool ?? false
        let storedAppearance = defaults.string(forKey: "appearancePreference.v1")
        self.appearancePreference = storedAppearance
            .flatMap(AppearancePreference.init(rawValue:)) ?? .system
        let storedPreset = defaults.string(forKey: "detectionPreset.v1")
        self.detectionPreset = storedPreset
            .flatMap(SettingsPreset.init(rawValue:)) ?? .balanced
        isInitializing = false
    }

    /// Restore all settings to factory defaults.
    func resetToDefaults() {
        exportDPI = 300
        fillColor = .black
        autoVerify = true
        pipelineMode = .secureRasterization
        paranoidMode = false
        appearancePreference = .system
        detectionPreset = .balanced
        // The search sheet's last-used filter shape (the Source filter,
        // the OCR confidence floor and the sort) — `SearchState`'s key.
        defaults.removeObject(forKey: "search.lastFilter.v1")
    }
}

// MARK: - Preset picker display strings

/// App-side display copy for the ENGINE's existing `SettingsPreset`
/// (do not introduce a parallel preset type). "Aggressive" reads as
/// "Sensitive" in the UI — the engine term is a developer word.
/// Mechanism-description copy, not outcome language.
extension SettingsPreset {
    var displayLabel: String {
        switch self {
        case .conservative: return "Conservative"
        case .balanced:     return "Balanced"
        case .aggressive:   return "Sensitive"
        }
    }
    var mechanismDescription: String {
        switch self {
        case .conservative:
            return "Requires stronger contextual evidence before flagging an item"
        case .balanced:
            return "Uses the calibrated default evidence threshold for each item type"
        case .aggressive:
            return "Flags items with weaker evidence; designed to surface more candidates for review"
        }
    }
}
