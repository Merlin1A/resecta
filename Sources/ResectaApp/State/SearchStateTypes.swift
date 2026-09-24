import Foundation

// The search sheet's wire-value vocabulary — the mode selector and the
// three result filters `SearchState` exposes and `SavedSearchStore`
// persists. Beside the session state class rather than inside its file:
// frozen `Codable` enums with no dependency on the class.

/// UI selector for search mode (simpler than SearchMode enum for picker).
/// `Codable` conformance is consumed by `SavedSearchStore`.
/// rawValues are stable wire identifiers (persistence + launch-arg
/// mapping), deliberately decoupled from the user-facing strings so a
/// display rename can never invalidate persisted data. Wire values are
/// frozen; display strings live in `displayName` only.
enum SearchModeType: String, CaseIterable, Sendable, Codable {
    case text = "text"
    case regex = "regex"
    case multiTerm = "multiTerm"
    case piiScan = "scan"

    /// User-facing name. Display-only — never persisted, never compared
    /// against stored data.
    var displayName: String {
        switch self {
        case .text: "Text"
        case .regex: "Regex"
        case .multiTerm: "Multi-term"
        case .piiScan: "Scan"
        }
    }

    /// Which of the sheet's two peer interfaces this mode belongs to.
    /// The scan mode IS the Scan interface's machinery; text / regex /
    /// multi-term are the Search interface's second-level modes. The
    /// interface is a pure derivation — mode carries interface
    /// identity, so persistence, launch args, and saved-search recall
    /// need no second field.
    var interface: SearchInterface {
        self == .piiScan ? .scan : .search
    }
}

/// The sheet's top-level interface pair: one chassis, two peer
/// interfaces — Scan (detector-driven) and Search (literal matching).
/// Display-only UI selector — never persisted (the mode's wire value
/// carries interface identity).
enum SearchInterface: Equatable, Sendable {
    case scan
    case search

    /// Per-interface navigation titles.
    var displayName: String {
        switch self {
        case .scan: "Scan"
        case .search: "Search"
        }
    }
}

/// Source type filter for search results.
/// `Codable` conformance is consumed by `SavedSearchStore`.
/// Case renames are migration events.
enum SourceFilter: String, CaseIterable, Sendable, Codable {
    case all = "All"
    case textOnly = "Text"
    case ocrOnly = "OCR"
}

/// Post-scan filter that hides applied or unapplied results.
/// `Codable` conformance is consumed by `SavedSearchStore`.
/// Case renames are migration events.
enum AppliedFilter: String, CaseIterable, Sendable, Codable {
    case all = "All"
    case applied = "Applied"
    case unapplied = "Unapplied"
}

/// Sort order for search results.
/// `Codable` conformance is consumed by `SavedSearchStore`.
/// Case renames are migration events.
enum ResultSortOrder: String, CaseIterable, Sendable, Codable {
    case discoveryOrder = "Default"
    case confidenceDescending = "Confidence"
    case pageAscending = "Page"
}
