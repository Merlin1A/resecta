import Foundation
import RedactionEngine

// Cross-page entity linking.
//
// A `CrossPageEntityGroup` bundles every detection across the document whose
// matched text normalizes to the same canonical form within the same PII
// category. The triage sheet's "Grouped" view mode lists one row per group;
// tapping accept/reject toggles every member's `triageSelection` in lock-step
// so the user reasons about the entity rather than each instance.
//
// Clustering uses **normalize-and-exact-match** (locked).
// Fuzzy match was
// considered and rejected: fuzzy match would expose a similarity threshold
// the user has to understand, while normalize-and-exact-match is auditable
// and reproducible. Clustering is **within a single PII category** — the
// same canonical text in two categories does not merge.
//
// The shipping companion to this type is `RedactionState.applyEntityGroup`
// which mirrors `applySearchResults`'s undo-grouping pattern so one
// `undoManager.undo()` reverses an entire group accept atomically.

/// A cluster of detections across multiple pages that share a normalized
/// matched-text value within the same PII category.
///
/// Value type, Sendable so it can be passed from the detached clustering
/// step on `PipelineCoordinator` back to MainActor.
public struct CrossPageEntityGroup: Sendable, Identifiable, Equatable {
    public let id: UUID
    /// PII kind shared by every member of the group. Clustering does not
    /// merge across kinds.
    public let category: RedactionRegion.PIIKind
    /// The normalized text used as the cluster key. Lowercased, trimmed,
    /// whitespace-collapsed, non-alphanumerics stripped.
    public let canonicalText: String
    /// Ascending list of page indices on which at least one member of the
    /// cluster appears. May contain duplicates suppressed via Set on
    /// construction; preserved here as sorted array for stable display.
    public let pages: [Int]
    /// Every `DetectionResult.id` whose normalized text matched
    /// `canonicalText`. Order is determined by the clustering step; tests
    /// treat the value as an unordered membership set.
    public let detectionIDs: [UUID]

    public init(
        id: UUID = UUID(),
        category: RedactionRegion.PIIKind,
        canonicalText: String,
        pages: [Int],
        detectionIDs: [UUID]
    ) {
        self.id = id
        self.category = category
        self.canonicalText = canonicalText
        self.pages = pages
        self.detectionIDs = detectionIDs
    }
}

// MARK: - Normalization

extension CrossPageEntityGroup {

    /// Normalize a matched-text string into the canonical form used as the
    /// clustering key. Specifically:
    /// 1. Lowercase.
    /// 2. Trim leading/trailing whitespace.
    /// 3. Collapse interior whitespace runs to a single space.
    /// 4. Strip non-alphanumeric characters (the single-space separator
    ///    survives this step because the collapse runs first; after the
    ///    strip the residue is alphanumerics joined by single spaces, then
    ///    the spaces are also dropped). The output is alphanumerics only.
    ///
    /// Locked. The normalization is designed
    /// to absorb the common drift the OCR + detector pipeline introduces
    /// (case differences, trailing punctuation, internal multi-space) so
    /// "John Doe", "john doe", "JOHN  DOE!" all map to "johndoe". Out of
    /// scope: stem matching, accent folding beyond NFKC (covered upstream
    /// by `TextNormalizer.normalize`).
    public static func canonicalize(_ raw: String) -> String {
        // Start with NFKC + ligature expansion via the engine's shared
        // normalizer so PDF text-layer ligatures (fi, fl, ffi, ffl, ff)
        // are decomposed identically to the search and bloom-filter paths.
        let nfkc = TextNormalizer.normalize(raw)
        let lowered = nfkc.lowercased()
        // Step 1: trim + collapse whitespace runs to single spaces.
        let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        // Step 2: strip everything that is not alphanumeric. The locked
        // decision treats the result as an alphanumeric-only key — the
        // single-space separator is also dropped because retaining it
        // would split "JohnDoe" and "John Doe" into different clusters
        // (the OCR pipeline occasionally elides the space).
        var result = ""
        result.reserveCapacity(collapsed.count)
        for scalar in collapsed.unicodeScalars
            where CharacterSet.alphanumerics.contains(scalar) {
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

// MARK: - Clustering

extension CrossPageEntityGroup {

    /// Build cross-page entity groups from a flat list of (page, detection)
    /// pairs. Pure function — no IO, no actor state read — so it can run
    /// inside a `Task.detached` if the caller wants to keep MainActor free
    /// on very large documents.
    ///
    /// Cluster key is the pair `(category, canonical)`; entries whose
    /// `matchedText` is nil/empty after canonicalization are skipped (they
    /// have no key to cluster on). Detections whose `Kind` is `.face` or
    /// `.searchMatch` are skipped — only `.pii(kind)` participates so the
    /// "Grouped" view stays inside the auto-detected PII surface the user
    /// is triaging.
    ///
    /// Singleton clusters (detection appears once across the document) are
    /// **omitted**: a one-instance "group" carries no cross-page semantic
    /// value and would clutter the Grouped view. The locked acceptance
    /// criterion describes groups as "instances
    /// across pages" — minimum two members.
    ///
    /// - Parameter pendingTriage: pageIndex → detection-results map, as
    ///   produced by `PipelineCoordinator.runDetectionPipeline()`.
    /// - Returns: clusters with two or more members, sorted by (page
    ///   ascending, canonicalText ascending) for stable display ordering.
    public static func clusters(
        from pendingTriage: [Int: [DetectionResult]]
    ) -> [CrossPageEntityGroup] {
        // Group by (category, canonical).
        struct Key: Hashable {
            let category: RedactionRegion.PIIKind
            let canonical: String
        }
        struct Member {
            let page: Int
            let detectionID: UUID
        }
        var buckets: [Key: [Member]] = [:]

        for (page, results) in pendingTriage {
            for result in results {
                guard case .pii(let kind) = result.kind else { continue }
                guard let raw = result.matchedText, !raw.isEmpty else { continue }
                let canonical = canonicalize(raw)
                guard !canonical.isEmpty else { continue }
                let key = Key(category: kind, canonical: canonical)
                buckets[key, default: []].append(
                    Member(page: page, detectionID: result.id)
                )
            }
        }

        var groups: [CrossPageEntityGroup] = []
        for (key, members) in buckets {
            // Singletons drop out — see doc comment above.
            guard members.count >= 2 else { continue }
            let pages = Array(Set(members.map(\.page))).sorted()
            let detectionIDs = members.map(\.detectionID)
            groups.append(
                CrossPageEntityGroup(
                    category: key.category,
                    canonicalText: key.canonical,
                    pages: pages,
                    detectionIDs: detectionIDs
                )
            )
        }
        // Stable display order: lowest first page asc, then canonicalText
        // asc. Ties are broken by id for total ordering so snapshot tests
        // that hash the list stay deterministic.
        groups.sort { a, b in
            if let aFirst = a.pages.first, let bFirst = b.pages.first,
               aFirst != bFirst {
                return aFirst < bFirst
            }
            if a.canonicalText != b.canonicalText {
                return a.canonicalText < b.canonicalText
            }
            return a.id.uuidString < b.id.uuidString
        }
        return groups
    }
}
