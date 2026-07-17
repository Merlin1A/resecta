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

    // MARK: - App-wide scalars

    var exportDPI: Int = 300 {
        didSet { guard !isInitializing else { return }
                UserDefaults.standard.set(exportDPI, forKey: "exportDPI") }
    }
    var fillColor: FillColor = .black {
        didSet { guard !isInitializing else { return }
                UserDefaults.standard.set(fillColor.rawValue, forKey: "fillColor") }
    }
    var autoVerify: Bool = true {
        didSet { guard !isInitializing else { return }
                UserDefaults.standard.set(autoVerify, forKey: "autoVerify") }
    }

    /// Count of successful exports. Used to trigger the App Store review
    /// prompt on the 3rd successful export. UserDefaults with didSet
    /// (the property-wrapper alternative is banned inside @Observable).
    var successfulExportCount: Int = 0 {
        didSet { guard !isInitializing else { return }
                UserDefaults.standard.set(successfulExportCount, forKey: "successfulExportCount") }
    }

    /// App-wide pipeline preference read at scan kickoff and export.
    /// `.secureRasterization` is the default fallback.
    var pipelineMode: PipelineMode = .secureRasterization {
        didSet { guard !isInitializing else { return }
                UserDefaults.standard.set(pipelineMode.rawValue, forKey: "pipelineMode.v2") }
    }

    /// When true, detection results are auto-applied as regions.
    /// When false, detection results are staged for triage review.
    /// Defaults to false so users see the triage sheet by default.
    var autoApplyDetections: Bool = false {
        didSet { guard !isInitializing else { return }
                UserDefaults.standard.set(autoApplyDetections, forKey: "autoApplyDetections") }
    }

    /// When true, the rectangle-draw tool snaps the in-progress
    /// rectangle's edges to nearby OCR text-block edges within
    /// `snapTolerance = 8 / zoomScale` overlay-space points. Default on;
    /// opt-out toggle in Settings. Mechanism-description language: the
    /// assist is designed to align edges
    /// to OCR text-block boundaries; alignment is best-effort.
    var snapToTextEnabled: Bool = true {
        didSet { guard !isInitializing else { return }
                UserDefaults.standard.set(snapToTextEnabled, forKey: "snapToTextEnabled") }
    }

    /// Opt-in paranoid-mode toggle.
    /// Off by default. When on, the app applies three behavior overrides
    /// (numbered #1/#2/#4 at their call sites — #3 was retired, numbering
    /// kept for cross-reference stability): pipeline mode is forced to
    /// `.secureRasterization`; `autoVerify` is forced to `true` (UI toggle
    /// disabled while paranoid is on); and Live Photo / Portrait depth
    /// auxiliary-metadata keys are removed from imported images via
    /// `LivePhotoAuxStripper`. Mechanism-description language: the bundle
    /// is designed to reduce the surface area of optional side channels;
    /// behavior is best-effort.
    var paranoidMode: Bool = false {
        didSet { guard !isInitializing else { return }
                UserDefaults.standard.set(paranoidMode, forKey: "paranoidMode") }
    }

    /// Appearance preference. Drives SwiftUI .preferredColorScheme at the
    /// WindowGroup root. Default is .system so first-launch users see the
    /// OS-level setting honored. Persists via the file-header pattern.
    var appearancePreference: AppearancePreference = .system {
        didSet { guard !isInitializing else { return }
                UserDefaults.standard.set(appearancePreference.rawValue, forKey: "appearancePreference.v1") }
    }

    // MARK: - Search recents preference

    /// When true, text and regex query strings are recorded to
    /// UserDefaults after each search. Default OFF (private by default):
    /// recents then stay in-memory for the session only. Turning this
    /// off stops on-device recording; existing history is cleared by the
    /// Settings UI write path.
    /// didSet persistence pattern (the property-wrapper alternative
    /// is banned inside @Observable).
    var saveRecentSearches: Bool = false {
        didSet { guard !isInitializing else { return }
                UserDefaults.standard.set(saveRecentSearches, forKey: "search.recents.enabled.v1") }
    }

    // MARK: - Detection preset + threshold vector

    /// User-selected detection preset. Drives `activeThresholdVector` at
    /// every scan kickoff; the picker SELECTS one of the calibrated
    /// vectors, it never edits threshold values.
    var detectionPreset: SettingsPreset = .balanced {
        didSet { guard !isInitializing else { return }
                UserDefaults.standard.set(detectionPreset.rawValue, forKey: "detectionPreset.v1") }
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
    init() {
        let raw = UserDefaults.standard.object(forKey: "exportDPI") as? Int ?? 300
        self.exportDPI = [150, 200, 300].contains(raw) ? raw : 300
        self.fillColor = FillColor(rawValue:
            UserDefaults.standard.string(forKey: "fillColor") ?? "black") ?? .black
        self.autoVerify = UserDefaults.standard.object(forKey: "autoVerify") as? Bool ?? true
        self.successfulExportCount = UserDefaults.standard.object(forKey: "successfulExportCount") as? Int ?? 0
        let storedMode = UserDefaults.standard.string(forKey: "pipelineMode.v2")
        self.pipelineMode = storedMode
            .flatMap(PipelineMode.init(rawValue:)) ?? .secureRasterization
        self.autoApplyDetections = UserDefaults.standard.object(forKey: "autoApplyDetections") as? Bool ?? false
        self.snapToTextEnabled = UserDefaults.standard.object(forKey: "snapToTextEnabled") as? Bool ?? true
        self.paranoidMode = UserDefaults.standard.object(forKey: "paranoidMode") as? Bool ?? false
        let storedAppearance = UserDefaults.standard.string(forKey: "appearancePreference.v1")
        self.appearancePreference = storedAppearance
            .flatMap(AppearancePreference.init(rawValue:)) ?? .system
        let storedPreset = UserDefaults.standard.string(forKey: "detectionPreset.v1")
        self.detectionPreset = storedPreset
            .flatMap(SettingsPreset.init(rawValue:)) ?? .balanced
        // Absent key → false (default-off, private by default). Keep in
        // lockstep with `SearchState.recordRecentQuery`'s gate.
        self.saveRecentSearches = UserDefaults.standard.object(forKey: "search.recents.enabled.v1") as? Bool ?? false
        isInitializing = false
    }

    /// Restore all settings to factory defaults.
    func resetToDefaults() {
        exportDPI = 300
        fillColor = .black
        autoVerify = true
        // successfulExportCount is intentionally NOT reset here. It is a
        // lifetime metric that gates the StoreKit review prompt (fires once as the
        // count crosses 2 -> 3), not a user preference. Resetting it re-arms the
        // prompt after 3 more exports; a Settings "reset to defaults" should not
        // re-trigger the review request (Apple's OS-side rate limit bounds the
        // exposure, but the disclosure dialog does not mention re-arming).
        pipelineMode = .secureRasterization
        autoApplyDetections = false
        snapToTextEnabled = true
        paranoidMode = false
        appearancePreference = .system
        detectionPreset = .balanced
        // Factory default is OFF (private by default). Reset restores
        // the preference only; explicit history clearing stays with the
        // dedicated Clear Search History affordance.
        saveRecentSearches = false
    }
}

// MARK: - Preset picker display strings

/// App-side display copy for the ENGINE's existing `SettingsPreset`
/// (do not introduce a parallel preset type). "Aggressive" reads as
/// "Sensitive" in the UI — the engine term is a developer word.
/// Mechanism-description copy per CLAUDE.md hard rules.
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
