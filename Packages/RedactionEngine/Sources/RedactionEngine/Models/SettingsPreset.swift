import Foundation

// Plan A8 — three preset threshold vectors. User-selectable in SettingsView.
// Phase 1: selection stored via didSet+UserDefaults, but inert — Stage 6
// calibrated scoring consumes the vector in Phase 3.

public enum SettingsPreset: String, Sendable, CaseIterable, Codable, Hashable {
    case conservative
    case balanced
    case aggressive

    public var displayName: String {
        switch self {
        case .conservative: "Conservative"
        case .balanced:     "Balanced"
        case .aggressive:   "Aggressive"
        }
    }

    /// Mechanism-description copy (ARCHITECTURE.md §1.3) — no outcome-promise.
    public var description: String {
        switch self {
        case .conservative:
            "Favors fewer flags; matches require stronger context."
        case .balanced:
            "Default; tuned for a mix of structural and contextual evidence."
        case .aggressive:
            "Surfaces more candidates; more items for review."
        }
    }
}
