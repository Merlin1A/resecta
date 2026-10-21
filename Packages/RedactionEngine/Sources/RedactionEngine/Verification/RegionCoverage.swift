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

    /// The sampling grid over a match rect: columns along the run of the
    /// text, rows across it — the longer side of the rect is the run, so a
    /// match set vertically is sampled along its glyphs too. Coverage by the
    /// UNION of the page's boxes, so two boxes that share one match are read
    /// together.
    static let gridColumns = 48
    static let gridRows = 6

    /// Fraction of `match` (normalized page space) under the union of
    /// `regions` on the same page. 0 for a degenerate match.
    static func coveredFraction(of match: CGRect, by regions: [RedactionRegion]) -> CGFloat {
        guard match.width > 0, match.height > 0, !regions.isEmpty else { return 0 }
        let vertical = match.height > match.width
        let along = gridColumns
        let across = gridRows
        var covered = 0
        for a in 0..<across {
            let acrossOffset = (CGFloat(a) + 0.5) / CGFloat(across)
            for b in 0..<along {
                let alongOffset = (CGFloat(b) + 0.5) / CGFloat(along)
                let point = vertical
                    ? CGPoint(x: match.minX + match.width * acrossOffset, y: match.minY + match.height * alongOffset)
                    : CGPoint(x: match.minX + match.width * alongOffset, y: match.minY + match.height * acrossOffset)
                if regions.contains(where: { contains(point, $0) }) { covered += 1 }
            }
        }
        return CGFloat(covered) / CGFloat(gridRows * gridColumns)
    }

    /// A box the search placed (a typed search's match or a scan's item);
    /// a manual box or a face box is the user's own placement.
    static func isSearchPlaced(_ region: RedactionRegion) -> Bool {
        switch region.source {
        case .searchMatch, .detectedPII: true
        case .manual, .detectedFace: false
        }
    }

    /// One re-run match on a page: the request it came from and its rect.
    struct PageMatch {
        let requestIndex: Int
        let rect: CGRect
    }

    /// The shortfalls on one page, from every applied request's matches
    /// there and the boxes on the page. A match the boxes cover at least
    /// `coveredThreshold` is covered. A match touched between the two
    /// thresholds is a shortfall — unless every box touching it covers
    /// another match on the page at `coveredThreshold` (a neighbour's box
    /// grazing a match left unselected is not a box placed for it). A match
    /// no box touches was left unselected — unless the page also carries a
    /// search-placed box that touches none of the page's matches: a box
    /// placed for a match and drifted clear of it; each such box pairs with
    /// one untouched match, in request then page order, as a shortfall.
    static func pageShortfalls(
        page: Int, matches: [PageMatch], boxes: [RedactionRegion]
    ) -> [Shortfall] {
        guard !boxes.isEmpty, !matches.isEmpty else { return [] }
        var found: [Shortfall] = []
        var untouched: [(Int, PageMatch, CGFloat)] = []
        let touches: [[Bool]] = matches.map { match in boxes.map { coveredFraction(of: match.rect, by: [$0]) >= touchedThreshold } }
        let covers: [[Bool]] = matches.map { match in boxes.map { coveredFraction(of: match.rect, by: [$0]) >= coveredThreshold } }
        for (m, match) in matches.enumerated() {
            let fraction = coveredFraction(of: match.rect, by: boxes)
            if fraction >= coveredThreshold { continue }
            if fraction >= touchedThreshold {
                let touching = boxes.indices.filter { touches[m][$0] }
                let onlyNeighbours = touching.allSatisfy { b in
                    matches.indices.contains { $0 != m && covers[$0][b] }
                }
                if !onlyNeighbours {
                    found.append(Shortfall(pageIndex: page, requestIndex: match.requestIndex, coveredFraction: fraction))
                }
            } else {
                untouched.append((m, match, fraction))
            }
        }
        let driftedBoxes = boxes.indices.filter { b in
            isSearchPlaced(boxes[b]) && !matches.indices.contains { touches[$0][b] }
        }
        let ordered = untouched.sorted {
            ($0.1.requestIndex, $0.1.rect.minY, $0.1.rect.minX) < ($1.1.requestIndex, $1.1.rect.minY, $1.1.rect.minX)
        }
        for (_, match, fraction) in ordered.prefix(driftedBoxes.count) {
            found.append(Shortfall(pageIndex: page, requestIndex: match.requestIndex, coveredFraction: fraction))
        }
        return found
    }

    private static func contains(_ point: CGPoint, _ region: RedactionRegion) -> Bool {
        region.normalizedRect.contains(point)
    }

    /// What the re-run found: the partly covered matches, and the pages the
    /// searcher could not read for a request whose boxes they carry — an
    /// unread page is never a page with no match.
    struct Outcome: Sendable, Equatable {
        let shortfalls: [Shortfall]
        /// 0-based, sorted, deduplicated: a page with boxes (within the
        /// request's `appliedPages` when it names any) that the searcher
        /// reported it could not read — a render over the OCR pixel caps,
        /// OCR that did not run, a page it could not open, a pattern that
        /// ran out of time on it, or a pattern the safety gate refused.
        let unreadPages: [Int]
    }

    /// Re-run every applied request (never the run's sweep) on `source` with
    /// the request's own options and compare each result's rect, clamped to
    /// the page, with the boxes applied on its page. Pages outside a
    /// request's `appliedPages` (when it names any) are not read. A page the
    /// searcher could not read is reported in `unreadPages`, never passed
    /// by silence: the searcher's own coverage and timeout sinks say which
    /// pages it read and why it could not read one.
    static func check(
        source: SendablePDFDocument,
        requests: [SearchRecheckRequest],
        regions: [Int: [RedactionRegion]]
    ) async -> Outcome {
        var unread = Set<Int>()
        // The pages' text-layer status as the import and the search read
        // it, so a scanned or header-only page is re-run through OCR the
        // way the search that placed its boxes ran, not through its sparse
        // text layer.
        var status: [Int: TextLayerStatus] = [:]
        for index in 0..<source.document.pageCount {
            if let page = source.document.page(at: index) {
                status[index] = TextLayerDetector.detectTextLayer(page)
            }
        }
        let searcher = DocumentSearcher(textLayerStatusByPage: status)
        let pagesWithRegions = Set(regions.filter { !$0.value.isEmpty }.keys)
        var matchesByPage: [Int: [PageMatch]] = [:]
        for (index, request) in requests.enumerated() where request.origin == .applied {
            if Task.isCancelled { break }
            let configuration = request.record.scanConfiguration
            await searcher.setThresholdVector(configuration?.thresholdVector)
            await searcher.setUserTerms(configuration?.userTermsIndex)
            // The pages this request's boxes sit on: where an unread page
            // means a match may be uncovered.
            let candidates = request.appliedPages.isEmpty
                ? pagesWithRegions : pagesWithRegions.intersection(request.appliedPages)
            // The searcher reports per page how it read the page or why it
            // could not; a timeout or a refused pattern reports through its
            // own sink. Installed fresh per request so nothing crosses over.
            let reads = PageReadLog()
            await searcher.setPageCoverageSink { coverage in reads.record(coverage) }
            await searcher.setRegexTimeoutSink { page in reads.timedOut(page) }
            await searcher.setUserTermsTimeoutSink { page, _ in reads.timedOut(page) }
            await searcher.setRegexRejectionSink { _ in reads.refused() }
            let stream = searcher.search(source, mode: request.record.query.searchMode, progress: { _, _ in })
            for await result in stream {
                if Task.isCancelled { break }
                if !request.appliedPages.isEmpty, !request.appliedPages.contains(result.pageIndex) { continue }
                guard let pageRegions = regions[result.pageIndex], !pageRegions.isEmpty else { continue }
                matchesByPage[result.pageIndex, default: []].append(
                    PageMatch(requestIndex: index, rect: result.normalizedRect.clampedToNormalized()))
            }
            await searcher.setPageCoverageSink(nil)
            await searcher.setRegexTimeoutSink(nil)
            await searcher.setUserTermsTimeoutSink(nil)
            await searcher.setRegexRejectionSink(nil)
            unread.formUnion(reads.unreadPages(among: candidates))
        }
        var found: [Shortfall] = []
        for page in matchesByPage.keys.sorted() {
            found.append(contentsOf: pageShortfalls(page: page, matches: matchesByPage[page] ?? [], boxes: regions[page] ?? []))
        }
        return Outcome(shortfalls: found, unreadPages: unread.sorted())
    }

    /// The per-request record of what the searcher said about each page.
    /// A page may report more than once (the multi-term OCR path runs per
    /// term); one unread report makes the page unread.
    private final class PageReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var unread = Set<Int>()
        private var patternRefused = false

        func record(_ coverage: PageSearchCoverage) {
            switch coverage.route {
            case .textLayer, .ocr:
                break
            case .ocrSkippedOversize, .ocrUnavailable, .unopenable:
                lock.lock(); unread.insert(coverage.pageIndex); lock.unlock()
            }
        }

        func timedOut(_ page: Int) {
            lock.lock(); unread.insert(page); lock.unlock()
        }

        func refused() {
            lock.lock(); patternRefused = true; lock.unlock()
        }

        /// The candidate pages the request could not be re-run on: every
        /// one when the pattern was refused, else those reported unread.
        func unreadPages(among candidates: Set<Int>) -> Set<Int> {
            lock.lock(); defer { lock.unlock() }
            return patternRefused ? candidates : unread.intersection(candidates)
        }
    }
}
