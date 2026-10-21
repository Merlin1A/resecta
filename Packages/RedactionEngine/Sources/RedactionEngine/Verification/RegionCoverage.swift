import Foundation
import PDFKit

// The coverage check of the Search Re-check layer: every match an applied
// search or scan produces on the ORIGINAL page must be fully covered by the
// redaction boxes applied over it. A box that touches a match but leaves
// part of it uncovered — a box placed off its glyphs by any cause — is a
// shortfall the layer reports as a FAIL. A match no box touches was left
// unselected; whether its text survives in the output is the re-check's
// own question, not this one's. The comparison is geometric, so it reads a
// glyph OCR cannot (a lone digit beside a black box) and is independent of
// the output's rebuilt text layer, which drops the glyphs a box clips.

struct RegionCoverage: Sendable {

    /// One match the page's boxes cover only in part.
    struct Shortfall: Sendable, Equatable {
        let pageIndex: Int
        /// Index into the FULL request list the check ran.
        let requestIndex: Int
        /// The fraction of the match's area under the page's boxes.
        let coveredFraction: CGFloat
    }

    /// A match counts as covered at this fraction of its area: a rounding
    /// slack of two per cent, well under the fill's own safety margin on a
    /// line of ordinary height; a single uncovered glyph of an eleven-glyph
    /// term is nine per cent.
    static let coveredThreshold: CGFloat = 0.98

    /// A match under less than this fraction was not applied (no box
    /// touches it beyond a sliver).
    static let touchedThreshold: CGFloat = 0.02

    /// The sampling grid over a match rect: columns along the line, rows
    /// across it. Coverage by the UNION of the page's boxes, so two boxes
    /// that share one match are read together; a polygon box counts only
    /// its own interior (the rect is its bounding box).
    static let gridColumns = 48
    static let gridRows = 6

    /// Fraction of `match` (normalized page space) under the union of
    /// `regions` on the same page. 0 for a degenerate match.
    static func coveredFraction(of match: CGRect, by regions: [RedactionRegion]) -> CGFloat {
        guard match.width > 0, match.height > 0, !regions.isEmpty else { return 0 }
        var covered = 0
        for row in 0..<gridRows {
            let y = match.minY + match.height * (CGFloat(row) + 0.5) / CGFloat(gridRows)
            for column in 0..<gridColumns {
                let x = match.minX + match.width * (CGFloat(column) + 0.5) / CGFloat(gridColumns)
                let point = CGPoint(x: x, y: y)
                if regions.contains(where: { contains(point, $0) }) { covered += 1 }
            }
        }
        return CGFloat(covered) / CGFloat(gridRows * gridColumns)
    }

    private static func contains(_ point: CGPoint, _ region: RedactionRegion) -> Bool {
        guard region.normalizedRect.contains(point) else { return false }
        guard let vertices = region.vertices, vertices.count >= 3 else { return true }
        return pointInPolygon(point, vertices: vertices)
    }

    /// Re-run every applied request (never the run's sweep) on `source` with
    /// the request's own options and compare each result's rect, clamped to
    /// the page, with the boxes applied on its page. Pages outside a
    /// request's `appliedPages` (when it names any) are not read.
    static func shortfalls(
        source: SendablePDFDocument,
        requests: [SearchRecheckRequest],
        regions: [Int: [RedactionRegion]]
    ) async -> [Shortfall] {
        var found: [Shortfall] = []
        let searcher = DocumentSearcher()
        for (index, request) in requests.enumerated() where request.origin == .applied {
            if Task.isCancelled { break }
            let configuration = request.record.scanConfiguration
            await searcher.setThresholdVector(configuration?.thresholdVector)
            await searcher.setUserTerms(configuration?.userTermsIndex)
            let stream = searcher.search(source, mode: request.record.query.searchMode, progress: { _, _ in })
            for await result in stream {
                if Task.isCancelled { break }
                if !request.appliedPages.isEmpty, !request.appliedPages.contains(result.pageIndex) { continue }
                guard let pageRegions = regions[result.pageIndex], !pageRegions.isEmpty else { continue }
                let fraction = coveredFraction(of: result.normalizedRect.clampedToNormalized(), by: pageRegions)
                if fraction >= touchedThreshold, fraction < coveredThreshold {
                    found.append(Shortfall(pageIndex: result.pageIndex, requestIndex: index, coveredFraction: fraction))
                }
            }
        }
        return found
    }
}
