import Foundation

/// The five families the learned context scorer covers, typed. The raw
/// values are the asset wire names — `PresetThresholdVector.wireName(for:)`,
/// the `context-scorer.json` family keys, the preset vectors' keys — so the
/// JSON assets and their keys are unchanged. The lists that had to agree
/// by string (`ContextFeatureContract.scoredFamilies`,
/// `ContextPosteriorFloor.flooredFamilies`, the wire-name mapping) now meet
/// in one type; a string reaches a list only through `init?(wire:)`.
enum ScoredFamily: String, CaseIterable, Sendable {
    case account
    case phone
    case mrn
    case ein
    case itin

    /// The family for a category, through the one wire-name mapping; nil
    /// for every non-scored category.
    init?(category: PIICategory) {
        guard let wire = PresetThresholdVector.wireName(for: category) else { return nil }
        self.init(rawValue: wire)
    }

    /// The family for a wire name; nil for a non-scored wire (the empty
    /// string included).
    init?(wire: String) {
        self.init(rawValue: wire)
    }
}
