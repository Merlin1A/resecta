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
// A match that wraps onto a second line is one occurrence, judged whole:
// once a search's box touches one of its line pieces, a piece left bare is
// a shortfall, not a match left unselected (`RegionCoverage+Occurrences`).

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

    /// One re-run match on a page: the request it came from, its rect,
    /// and the term the searcher reported for it (a typed search's term, a
    /// scan's category name) — the term an applied box records — and the
    /// occurrence it is a line piece of, for a match that wraps.
    struct PageMatch {
        let requestIndex: Int
        let rect: CGRect
        var term: String = ""
        var occurrence: UUID? = nil
    }

    /// Whether `region` is a box a search or scan placed for a match of
    /// `term` (a re-run match's term: a typed search's term, a scan's
    /// category name): a search box records its term, a detected item its
    /// kind. A manual or face box was placed by no search.
    static func placed(_ region: RedactionRegion, forTerm term: String) -> Bool {
        switch region.source {
        case .searchMatch(let placed, _):
            return placed.lowercased() == term.lowercased()
        case .detectedPII(let kind, _):
            return PIICategory(rawValue: term)?.piiKind == kind
        case .manual, .detectedFace:
            return false
        }
    }

    /// Whether `match` can speak for `region` in the two excuses below: a
    /// box a search or scan placed speaks only through a match of the term
    /// or category it records, so another category's match lying under it
    /// never makes it a neighbour's box or keeps it from reading as
    /// drifted; a manual or face box records no term and any match it
    /// covers speaks for it.
    static func vouches(_ match: PageMatch, for region: RedactionRegion) -> Bool {
        isSearchPlaced(region) ? placed(region, forTerm: match.term) : true
    }

    /// The shortfalls on one page, from every applied request's matches
    /// there and the boxes on the page. A match the boxes cover at least
    /// `coveredThreshold` is covered. A match touched between the two
    /// thresholds is a shortfall — unless every box touching it covers
    /// another match on the page at `coveredThreshold` that `vouches` for it
    /// (a neighbour's box grazing a match left unselected is not a box
    /// placed for it). A match no box touches was left unselected — unless
    /// the page also carries a search-placed box that touches no match of
    /// its own term or category (`vouches`): a box
    /// placed for a match and drifted clear of it; each such box pairs with
    /// one untouched match OF THE TERM IT RECORDS, in request then page
    /// order, as a shortfall — a box placed for one term never vouches for
    /// another term's match left unselected. The `settled` line pieces of
    /// occurrences the occurrence rule judged are not judged again, but
    /// still count as the matches a box touches or covers.
    static func pageShortfalls(
        page: Int, matches: [PageMatch], boxes: [RedactionRegion], settled: [PageMatch] = []
    ) -> [Shortfall] {
        guard !boxes.isEmpty, !matches.isEmpty else { return [] }
        var found: [Shortfall] = []
        var untouched: [(Int, PageMatch, CGFloat)] = []
        let all = matches + settled
        let touches: [[Bool]] = all.map { match in boxes.map { coveredFraction(of: match.rect, by: [$0]) >= touchedThreshold } }
        let covers: [[Bool]] = all.map { match in boxes.map { coveredFraction(of: match.rect, by: [$0]) >= coveredThreshold } }
        for (m, match) in matches.enumerated() {
            let fraction = coveredFraction(of: match.rect, by: boxes)
            if fraction >= coveredThreshold { continue }
            if fraction >= touchedThreshold {
                let touching = boxes.indices.filter { touches[m][$0] }
                let onlyNeighbours = touching.allSatisfy { b in
                    all.indices.contains { $0 != m && covers[$0][b] && vouches(all[$0], for: boxes[b]) }
                }
                if !onlyNeighbours {
                    found.append(Shortfall(pageIndex: page, requestIndex: match.requestIndex, coveredFraction: fraction))
                }
            } else {
                untouched.append((m, match, fraction))
            }
        }
        let driftedBoxes = boxes.indices.filter { b in
            isSearchPlaced(boxes[b]) && !all.indices.contains { touches[$0][b] && vouches(all[$0], for: boxes[b]) }
        }
        var ordered = untouched.sorted {
            ($0.1.requestIndex, $0.1.rect.minY, $0.1.rect.minX) < ($1.1.requestIndex, $1.1.rect.minY, $1.1.rect.minX)
        }
        for b in driftedBoxes {
            guard let pick = ordered.firstIndex(where: { placed(boxes[b], forTerm: $0.1.term) }) else { continue }
            let (_, match, fraction) = ordered.remove(at: pick)
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
        /// OCR that did not run, a scanned page left unread with OCR off, a
        /// text page whose counted picture is left unread with OCR off, a
        /// page it could not open, a pattern that ran out of time on it, or
        /// a pattern the safety gate refused.
        let unreadPages: [Int]
        /// How many re-run matches on pages with boxes were compared.
        let comparedMatches: Int
    }

    /// Re-run every applied request (never the run's sweep) on `source` with
    /// the request's own options and compare each result's rect, clamped to
    /// the page, with the boxes applied on its page. Pages outside a
    /// request's `appliedPages` (when it names any) are not read. A page the
    /// searcher could not read is reported in `unreadPages`, never passed
    /// by silence: the searcher's own coverage and timeout sinks say which
    /// pages it read and why it could not read one, and a re-run that
    /// reached the searcher's result cap leaves the page it stopped on and
    /// every later page unread. A cancellation throws:
    /// a re-run cut short is never an outcome.
    static func check(
        source: SendablePDFDocument,
        requests: [SearchRecheckRequest],
        regions: [Int: [RedactionRegion]]
    ) async throws -> Outcome {
        var unread = Set<Int>()
        // The pages' text-layer status as the search read it, so a page is
        // re-run the way the search that placed its boxes ran: a scanned or
        // header-only page through OCR, not through its sparse text layer,
        // and a page whose text layer the search cannot read (garbled, or
        // with no geometry: `unreadableForSearch`) as `.sparse` too, as the
        // search routes it, not through the layer that holds none of its
        // words.
        var status: [Int: TextLayerStatus] = [:]
        for index in 0..<source.document.pageCount {
            if let page = source.document.page(at: index) {
                let detected = TextLayerDetector.detectTextLayer(page)
                status[index] = detected == .rich && TextLayerDetector.unreadableForSearch(page) ? .sparse : detected
            }
        }
        let searcher = DocumentSearcher(textLayerStatusByPage: status)
        let pagesWithRegions = Set(regions.filter { !$0.value.isEmpty }.keys)
        var matchesByPage: [Int: [PageMatch]] = [:]
        // Every line piece of a wrapping occurrence, across pages: a piece
        // off the pages compared still counts when another piece of its
        // occurrence is compared, so the occurrence is judged whole.
        var pieces: [PlacedPiece] = []
        for (index, request) in requests.enumerated() where request.origin == .applied {
            try Task.checkCancellation()
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
            // A scanned page (`.sparse`/`.none`) re-run with OCR off is read
            // by nothing and reports only through this sink: unread. So does
            // a text page carrying a picture the image census counts: its
            // text layer is read, but the picture, which may hold words the
            // layer does not, is read by nothing (`hybridOCRLeg`).
            await searcher.setScannedRegionNotAnalyzedSink { page in reads.notAnalysed(page) }
            await searcher.setRegexTimeoutSink { page in reads.timedOut(page) }
            await searcher.setUserTermsTimeoutSink { page, _ in reads.timedOut(page) }
            await searcher.setRegexRejectionSink { _ in reads.refused() }
            let stream = searcher.search(source, mode: request.record.query.searchMode, progress: { _, _ in })
            var strays: [PlacedPiece] = []
            var comparedOccurrences = Set<UUID>()
            // Every match the re-run yields counts toward the searcher's
            // cap, boxed or not, on any page, once however many lines it
            // runs over (the searcher counts matches, `emitCapped`); the
            // last page one came from is where a capped re-run stopped.
            var yielded = Set<UUID>()
            var lastPage = 0
            for await result in stream {
                try Task.checkCancellation()
                yielded.insert(DocumentSearcher.occurrenceKey(result))
                lastPage = max(lastPage, result.pageIndex)
                // A match with no box has nothing to measure a box's cover
                // against; the Search Re-check counts it as remaining.
                guard result.hasBox else { continue }
                let match = PageMatch(
                    requestIndex: index, rect: result.normalizedRect.clampedToNormalized(),
                    term: result.term, occurrence: result.occurrenceID)
                let onAppliedPage = request.appliedPages.isEmpty || request.appliedPages.contains(result.pageIndex)
                guard onAppliedPage, !(regions[result.pageIndex] ?? []).isEmpty else {
                    if result.occurrenceID != nil { strays.append(PlacedPiece(page: result.pageIndex, match: match)) }
                    continue
                }
                matchesByPage[result.pageIndex, default: []].append(match)
                if let occurrence = result.occurrenceID {
                    comparedOccurrences.insert(occurrence)
                    pieces.append(PlacedPiece(page: result.pageIndex, match: match))
                }
            }
            pieces.append(contentsOf: strays.filter { $0.match.occurrence.map(comparedOccurrences.contains) ?? false })
            await searcher.setPageCoverageSink(nil)
            await searcher.setScannedRegionNotAnalyzedSink(nil)
            await searcher.setRegexTimeoutSink(nil)
            await searcher.setUserTermsTimeoutSink(nil)
            await searcher.setRegexRejectionSink(nil)
            unread.formUnion(reads.unreadPages(among: candidates))
            // A re-run that reached the cap stopped part-way: the page it
            // stopped on and every page after it were not read whole, and a
            // page never reached reports nothing to the sinks. The searcher
            // walks pages in order, so the pages before were read.
            if yielded.count >= DocumentSearcher.maxResults {
                unread.formUnion(candidates.filter { $0 >= lastPage })
            }
        }
        let occurrences = occurrenceShortfalls(pieces: pieces, regions: regions)
        var found = occurrences.shortfalls
        for page in matchesByPage.keys.sorted() {
            let onPage = matchesByPage[page] ?? []
            let isSettled = { (match: PageMatch) in match.occurrence.map(occurrences.settled.contains) ?? false }
            found.append(contentsOf: pageShortfalls(
                page: page, matches: onPage.filter { !isSettled($0) }, boxes: regions[page] ?? [],
                settled: onPage.filter(isSettled)))
        }
        let compared = matchesByPage.values.reduce(0) { $0 + $1.count }
        return Outcome(shortfalls: found, unreadPages: unread.sorted(), comparedMatches: compared)
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

        func notAnalysed(_ page: Int) {
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
