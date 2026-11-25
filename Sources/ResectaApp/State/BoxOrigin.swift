import RedactionEngine

/// What made a box. Read from the region's source and its metadata; never stored.
///
/// The source decides first, and is read through one exhaustive switch, so a
/// new source fails to compile until it has an origin. The metadata is read
/// only for a search-match box: a category there means a Scan result. A Scan
/// result with no category (a pattern the user set to always flag) is known by
/// its rationale's signal, which travels on the region itself.
///
/// A box's origin never changes when it is moved, resized or put back by Undo:
/// the source is a `let`, a move or a resize does not write the metadata, and
/// the Undo of a delete puts the box's own metadata back.
///
/// `nonisolated`: the app target defaults to the main actor, and this is a pure value.
nonisolated enum BoxOrigin: Equatable, Sendable {
    /// Drawn, duplicated, or Mark Whole Page.
    case drawn
    /// A typed Search result.
    case search(term: String)
    /// A Scan result (nil: a pattern the user always flags), or a stored detected PII source.
    case scan(kind: RedactionRegion.PIIKind?)
    /// A stored detected face source.
    case face

    static func of(_ region: RedactionRegion, metadata: RegionMetadata?) -> BoxOrigin {
        switch region.source {
        case .manual:
            return .drawn
        case .detectedPII(let kind, _):
            return .scan(kind: kind)
        case .detectedFace:
            return .face
        case .searchMatch(let term, let rationale):
            if case .pii(let kind)? = metadata?.piiKind { return .scan(kind: kind) }
            if rationale?.signals.contains(where: { if case .userAlwaysFlag = $0 { true } else { false } }) == true {
                return .scan(kind: nil)
            }
            return .search(term: term)
        }
    }
}
