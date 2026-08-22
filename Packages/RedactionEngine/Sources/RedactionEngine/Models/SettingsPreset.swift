import Foundation

// Plan A8 — three preset threshold vectors. User-selectable in SettingsView.
// Phase 1: selection stored via didSet+UserDefaults, but inert — Stage 6
// calibrated scoring consumes the vector in Phase 3.

public enum SettingsPreset: String, Sendable, CaseIterable, Codable, Hashable {
    case conservative
    case balanced
    case aggressive
}
