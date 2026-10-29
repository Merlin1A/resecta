import Foundation

// The occurrence rule of the coverage check. A search match that runs onto
// a second line is one occurrence: the searcher returns one result per line
// it touches, each with its own rect and one shared occurrence id. Once a
// box the search placed for the occurrence's term touches any of its line
// pieces, the occurrence was applied, and every piece must be covered: a
// piece left bare is a shortfall, never a match left unselected. An
// occurrence no such box touches is left to the per-page rule
// (`pageShortfalls`) piece by piece, as before. Occurrence ids are minted
// per search run, so the pairing reads only the ids of the re-run itself.

extension RegionCoverage {

    /// One re-run line piece and the page it sits on.
    struct PlacedPiece {
        let page: Int
        let match: PageMatch
    }

    /// The shortfalls of the applied occurrences among `pieces` (every
    /// re-run piece that carries an occurrence id, in the order the
    /// searcher returned them, across pages), and the occurrences this rule
    /// settled: an applied one, judged here whether covered or not, whose
    /// pieces the per-page rule then does not judge again. One shortfall
    /// per partly covered occurrence: on the page of its first piece below
    /// `coveredThreshold`, with the area-weighted fraction of the whole
    /// occurrence under the boxes.
    static func occurrenceShortfalls(
        pieces: [PlacedPiece], regions: [Int: [RedactionRegion]]
    ) -> (shortfalls: [Shortfall], settled: Set<UUID>) {
        var order: [UUID] = []
        var byOccurrence: [UUID: [PlacedPiece]] = [:]
        for piece in pieces {
            guard let occurrence = piece.match.occurrence else { continue }
            if byOccurrence[occurrence] == nil { order.append(occurrence) }
            byOccurrence[occurrence, default: []].append(piece)
        }
        var found: [Shortfall] = []
        var settled = Set<UUID>()
        for occurrence in order {
            let members = byOccurrence[occurrence] ?? []
            let applied = members.contains { piece in
                (regions[piece.page] ?? []).contains { box in
                    placed(box, forTerm: piece.match.term)
                        && coveredFraction(of: piece.match.rect, by: [box]) >= touchedThreshold
                }
            }
            guard applied else { continue }
            settled.insert(occurrence)
            let fractions = members.map { coveredFraction(of: $0.match.rect, by: regions[$0.page] ?? []) }
            guard let bare = fractions.firstIndex(where: { $0 < coveredThreshold }) else { continue }
            let areas = members.map { $0.match.rect.width * $0.match.rect.height }
            let total = areas.reduce(0, +)
            let weighted = total > 0 ? zip(fractions, areas).reduce(0) { $0 + $1.0 * $1.1 } / total : 0
            found.append(Shortfall(
                pageIndex: members[bare].page, requestIndex: members[bare].match.requestIndex,
                coveredFraction: weighted))
        }
        return (found, settled)
    }
}
