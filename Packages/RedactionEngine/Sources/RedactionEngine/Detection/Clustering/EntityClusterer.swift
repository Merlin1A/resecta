import Foundation

// Plan §5 / A5 — entity clustering on name detections. Compound blocking
// on (surname, first-initial); pairwise similarity compared with
// JaroWinkler.combinedSimilarity; union if ≥ 0.70. Clusters size ≥ 15
// without a disambiguating first-initial get flagged — the UI surfaces
// them inline so the user verifies context before applying.
//
// Runs once per document after all pages yield (document-level Stage 5).

public struct EntityClusterer: Sendable {

    public init() {}

    public struct ClusterInput: Sendable {
        public let detectionID: UUID
        /// NFKC-lowered surname, or nil if the detected name is a single token.
        public let surname: String
        /// First letter of the given name if present.
        public let firstInitial: Character?
        /// The full matched text as it appears in the page (for similarity
        /// metrics). Case-preserving.
        public let fullText: String

        public init(detectionID: UUID, surname: String, firstInitial: Character?, fullText: String) {
            self.detectionID = detectionID
            self.surname = surname
            self.firstInitial = firstInitial
            self.fullText = fullText
        }
    }

    public struct ClusterReport: Sendable {
        public let clusters: [[UUID]]
        public let bareSurnameFlags: Set<UUID>

        public init(clusters: [[UUID]], bareSurnameFlags: Set<UUID>) {
            self.clusters = clusters
            self.bareSurnameFlags = bareSurnameFlags
        }
    }

    /// A5 threshold — intra-cluster minimum repair similarity.
    public static let similarityThreshold: Double = 0.70
    /// A5 threshold — bare-surname cluster disambiguation threshold.
    public static let ambiguousSurnameClusterSize: Int = 15

    public func cluster(names: [ClusterInput]) -> ClusterReport {
        guard names.count > 1 else {
            return ClusterReport(clusters: names.map { [$0.detectionID] }, bareSurnameFlags: [])
        }

        var unionFind = UnionFind(count: names.count)

        // Compound blocking — within each (surname, firstInitial) pair, try
        // to union all members. Across blocks with nil firstInitial, try
        // pairs within same surname.
        var bySurname: [String: [Int]] = [:]
        for (i, input) in names.enumerated() {
            bySurname[input.surname, default: []].append(i)
        }

        for (_, indices) in bySurname {
            // Within the same surname, always try to union.
            // Use combinedSimilarity on fullText to avoid false unions across
            // distinct given names when both lack initials.
            for i in 0..<indices.count {
                for j in (i + 1)..<indices.count {
                    let a = names[indices[i]]
                    let b = names[indices[j]]
                    let sim = JaroWinkler.combinedSimilarity(a.fullText, b.fullText)
                    // If both share a first-initial, lean in: either initial
                    // match OR sim ≥ threshold joins them.
                    let initialsMatch = a.firstInitial != nil &&
                        a.firstInitial?.lowercased() == b.firstInitial?.lowercased()
                    if initialsMatch || sim >= Self.similarityThreshold {
                        unionFind.union(indices[i], indices[j])
                    }
                }
            }
        }

        let groups = unionFind.groups()
        var clusters: [[UUID]] = []
        var flagged: Set<UUID> = []

        for group in groups {
            let ids = group.map { names[$0].detectionID }
            clusters.append(ids)

            // A5 flag: ≥ 15 entries, all with nil firstInitial.
            if group.count >= Self.ambiguousSurnameClusterSize {
                let allBare = group.allSatisfy { names[$0].firstInitial == nil }
                if allBare {
                    flagged.formUnion(ids)
                }
            }
        }

        return ClusterReport(clusters: clusters, bareSurnameFlags: flagged)
    }

    /// Helper to build a `ClusterInput` from a raw detected name string.
    /// Returns nil if the string is empty. NFKC-lowered surname; firstInitial
    /// inferred from the first token when the name has ≥ 2 tokens.
    public static func clusterInput(for detectionID: UUID, rawName: String) -> ClusterInput? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = TextNormalizer.normalize(trimmed)
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        let surname: String
        let firstInitial: Character?
        if tokens.count == 1 {
            surname = tokens[0].lowercased()
            firstInitial = nil
        } else {
            // Simple heuristic: last token = surname; first token's initial
            // letter = firstInitial.
            surname = (tokens.last ?? "").lowercased()
            firstInitial = tokens.first?.first?.lowercased().first
        }
        return ClusterInput(
            detectionID: detectionID,
            surname: surname,
            firstInitial: firstInitial,
            fullText: trimmed
        )
    }
}
