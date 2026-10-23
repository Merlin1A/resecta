import Foundation

/// The kinds of match the app stages from a search or a scan, and the
/// recognition level it records with them. A namespace for the two types the
/// app's region metadata names: no value of `DetectionResult` itself is made.
public struct DetectionResult: Sendable {

    public enum Kind: Sendable, Equatable, Hashable {
        case pii(PIIKind)
        case searchMatch(term: String)
    }

    public enum RecognitionLevel: String, Sendable {
        case fast
        case accurate
    }

    /// PIIKind values matching RedactionRegion.PIIKind for consistency.
    public typealias PIIKind = RedactionRegion.PIIKind
}
