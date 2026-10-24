import Foundation
import PDFKit

// The Search Re-check layer (`VerificationLayer.searchRecheck`).
//
// Re-runs every applied typed search on the redacted output through
// `DocumentSearcher` itself — the text layer on pages that carry one, the
// searcher's own OCR path on image-only pages — and reports per query how
// many matches were found, how many the user applied, and how many remain
// in the text the app can read. The page loop is `OutputRecheck`, shared
// with the Detection Sweep: one searcher per page, the page's OCR rendered
// once and cached across every request, the observations sorted before
// the fold.
//
// Honesty: a page the searcher could not read (OCR did not run, oversize,
// unopenable, regex timeout, the per-page result cap, a pattern the regex
// safety gate refused) is listed, never counted as clear. Query texts ride only the display-only fields
// (`reviewTermTexts`, `queryLines`); every status message is content-free.
// Nothing in this file logs.

struct SearchRecheck: Sendable {

    /// The idle message: no typed search was applied (or every region an
    /// applied search produced was deleted). Reported as `.info` — never
    /// `.skipped`, which the aggregate would degrade to WARN.
    static let infoMessage = "No searches were applied — the search re-check did not run."

    /// Lead sentence of the layer's own detail copy.
    static let detailLead = "Search Re-check re-ran each applied search on the output through the search engine."

    /// What `runLayer` folds into the `LayerResult`.
    struct Outcome: Sendable {
        let status: VerificationStatus
        let copyOverride: LayerCopy?
        /// ATTENTION: pages with remaining matches. WARN: pages that could
        /// not be checked. Nil otherwise. 0-based.
        let pageReferences: [Int]?
        /// Display-only: `displayText` of every request with a remaining
        /// match, in request order. Nil unless ATTENTION.
        let reviewTermTexts: [String]?
        /// Display-only per-query lines. Nil on INFO.
        let queryLines: [SearchRecheckQueryLine]?
    }

    /// One page's observation — the shared runner's record.
    typealias PageObservation = RecheckObservation

    // MARK: - Run

    /// Fold the typed requests among `requests`. `observations` are the
    /// shared runner's, keyed by index into the FULL request list; nil runs
    /// the page loop here for the typed requests alone (the public
    /// `runLayer` contract). With `sourceDocument`, every applied request
    /// (typed or scan) is also re-run on the ORIGINAL pages and each match
    /// compared with the boxes applied over it (`RegionCoverage`): a box
    /// that leaves part of its match uncovered fails the layer — a box
    /// moved, resized or placed by another path. The re-run is the same
    /// searcher that placed the boxes, so an error in its own placement is
    /// outside this check. Without a readable source — none given, or a
    /// copy that stayed locked — the coverage check does not run, and the
    /// layer says so whenever a request was applied: never a PASS by
    /// silence.
    func run(
        outputDocument: SendablePDFDocument,
        requests: [SearchRecheckRequest],
        observations: [RecheckObservation]? = nil,
        sourceDocument: SendablePDFDocument? = nil,
        regions: [Int: [RedactionRegion]] = [:]
    ) async throws -> Outcome {
        try Task.checkCancellation()
        // The coverage check needs the ORIGINAL pages readable. No source,
        // or a copy that stayed locked (a 128-bit password document's bytes
        // re-emit encrypted), means it did not run — reported below whenever
        // a request was applied, never folded into a PASS.
        let coverageSource = sourceDocument.flatMap { $0.document.isLocked ? nil : $0 }
        let coverageRan = coverageSource != nil
        let appliedAny = requests.contains { $0.origin == .applied }
        var shortfalls: [Shortfall] = []
        // The original pages the searcher could not read for a request whose
        // boxes they carry: reported, never counted as covered.
        var unreadPages: [Int] = []
        var comparedMatches = 0
        if let coverageSource {
            let coverage = await RegionCoverage.check(
                source: coverageSource, requests: requests, regions: regions)
            shortfalls = coverage.shortfalls.map {
                Shortfall(page: $0.pageIndex, displayText: requests[$0.requestIndex].record.query.displayText)
            }
            unreadPages = coverage.unreadPages
            comparedMatches = coverage.comparedMatches
            try Task.checkCancellation()
        }
        let typed = requests.enumerated().filter { !$0.element.record.query.isScan }
        let typedRequests = typed.map(\.element)
        guard !typedRequests.isEmpty else {
            if !shortfalls.isEmpty {
                return Self.shortfallOutcome(shortfalls, queryLines: nil)
            }
            if appliedAny, !coverageRan {
                return Self.coverageNotRunOutcome()
            }
            if !unreadPages.isEmpty {
                return Self.coverageNotRunOutcome(unreadPages: unreadPages)
            }
            // A scan was applied and the coverage check ran clean: the
            // layer's one check ran, so the outcome is a PASS that says
            // what was compared — never the idle note, which would say the
            // re-check did not run. A scan whose matches the re-run cannot
            // read on the original compared nothing: could not verify.
            if appliedAny {
                return comparedMatches > 0
                    ? Self.scanCoveredOutcome(comparedMatches: comparedMatches)
                    : Self.coverageNotRunOutcome(noMatchFound: true)
            }
            return Outcome(
                status: .info(Self.infoMessage), copyOverride: nil,
                pageReferences: nil, reviewTermTexts: nil, queryLines: nil)
        }
        let pageCount = outputDocument.document.pageCount
        let observed: [RecheckObservation]
        if let observations {
            let indices = typed.map(\.offset)
            observed = observations.map { $0.restricted(to: indices) }
        } else {
            observed = try await OutputRecheck().observe(
                outputDocument: outputDocument, requests: typedRequests)
        }
        try Task.checkCancellation()
        return Self.fold(requests: typedRequests, observations: observed, pageCount: pageCount,
                         shortfalls: shortfalls, coverageRan: coverageRan, coverageUnreadPages: unreadPages)
    }

    /// One partly covered match, as the fold reports it: its 0-based page
    /// and the display text of the request that produced it.
    struct Shortfall: Sendable, Equatable {
        let page: Int
        let displayText: String
    }

    /// The coverage FAIL: the only FAIL this layer reports. Content-free
    /// message; the request texts ride `reviewTermTexts`.
    static func shortfallOutcome(_ shortfalls: [Shortfall], queryLines: [SearchRecheckQueryLine]?) -> Outcome {
        let pages = Array(Set(shortfalls.map(\.page))).sorted()
        let m = shortfalls.count
        let list = pages.map { String($0 + 1) }.joined(separator: ", ")
        let message = "\(m) \(m == 1 ? "match is" : "matches are") only partly covered by \(m == 1 ? "its" : "their") redaction \(m == 1 ? "box" : "boxes") on \(pagePhrase(pages, list: list))"
        let detail = "\(Self.detailLead) \(Self.coverageLead) \(message)."
        var seen = Set<String>()
        let terms = shortfalls.map(\.displayText).filter { seen.insert($0).inserted }
        return Outcome(
            status: .fail(message),
            copyOverride: LayerCopy(short: message, detail: detail),
            pageReferences: pages,
            reviewTermTexts: terms,
            queryLines: queryLines)
    }

    /// The coverage sentence of the detail copy.
    static let coverageLead = "Each applied search and scan was also re-run on the original page by the same search engine that placed its boxes, and every match compared with the boxes applied over it; a box that leaves part of its match uncovered — moved, resized or placed by another path — is reported here. An error in that engine's own placement is outside this check."

    /// The coverage check's own could-not-verify clause: the original pages
    /// were not readable (no source copy, or one that stayed locked), so
    /// no match was compared with its boxes. Content-free.
    static let coverageNotRunClause = "the original pages could not be read, so the coverage check did not run"

    /// The detail sentence behind that clause.
    static let coverageNotRunDetail = "The original pages could not be read, so the coverage check — each applied search and scan re-run on the original page and compared with its boxes — did not run."

    /// The per-page clause: original pages the coverage check could not
    /// read for a request whose boxes they carry (a render over the OCR
    /// caps, OCR that did not run, a page it could not open, a pattern that
    /// ran out of time or was refused). Content-free; 0-based pages in.
    static func coverageUnreadClause(_ pages: [Int]) -> String {
        let n = pages.count
        let list = pages.map { String($0 + 1) }.joined(separator: ", ")
        return n == 1
            ? "the coverage check could not read original page \(list)"
            : "the coverage check could not read \(n) original pages: \(list)"
    }

    /// The detail sentence behind that clause.
    static func coverageUnreadDetail(_ pages: [Int]) -> String {
        let clause = Self.coverageUnreadClause(pages)
        return "\(clause.prefix(1).uppercased())\(clause.dropFirst()) (a page too large to scan for text, one it could not open, or a pattern that ran out of time or was not accepted), so no match there was compared with its boxes."
    }

    /// PASS for a run with applied scans only whose coverage check ran and
    /// found every match covered: there is no typed search to re-run on the
    /// output, and the one check the layer had ran. Content-free.
    static func scanCoveredOutcome(comparedMatches n: Int) -> Outcome {
        let short = "No typed searches to re-run; the applied scan's \(n == 1 ? "1 match was" : "\(n) matches were") compared with \(n == 1 ? "its box" : "their boxes") on the original pages — \(n == 1 ? "it is" : "all are") covered."
        let detail = "\(Self.detailLead) \(Self.coverageLead) \(short)"
        return Outcome(
            status: .pass,
            copyOverride: LayerCopy(short: short, detail: detail),
            pageReferences: nil,
            reviewTermTexts: nil,
            queryLines: nil)
    }

    /// The clause for a scan whose matches the re-run did not read on the
    /// original pages: nothing was compared, so nothing is known.
    static let coverageNoMatchClause = "the re-run found none of the applied scan's matches on the original pages, so the coverage check compared nothing"

    /// WARN for a run with applied scans only whose coverage check could
    /// not run — there is no typed search to re-run on the output, and the
    /// one check the layer had was not possible — or ran but could not read
    /// a page it had boxes on (`unreadPages`, 0-based), or ran and found no
    /// match to compare (`noMatchFound`). A WARN, so the aggregate reads
    /// could-not-verify; never the idle INFO.
    static func coverageNotRunOutcome(unreadPages: [Int] = [], noMatchFound: Bool = false) -> Outcome {
        let message: String
        let detail: String
        if noMatchFound {
            message = Self.coverageNoMatchClause.prefix(1).uppercased() + Self.coverageNoMatchClause.dropFirst()
            detail = "\(Self.detailLead) \(Self.coverageLead) \(message)."
        } else if unreadPages.isEmpty {
            message = "The original pages could not be read, so the coverage check did not run"
            detail = Self.coverageNotRunDetail
        } else {
            let clause = Self.coverageUnreadClause(unreadPages)
            message = clause.prefix(1).uppercased() + clause.dropFirst()
            detail = "\(Self.detailLead) \(Self.coverageLead) \(Self.coverageUnreadDetail(unreadPages))"
        }
        return Outcome(
            status: .warn(message),
            copyOverride: LayerCopy(short: message, detail: detail),
            pageReferences: unreadPages.isEmpty ? nil : unreadPages,
            reviewTermTexts: nil,
            queryLines: nil)
    }

    // MARK: - Fold (pure)

    /// Fold sorted per-page observations into the layer outcome. Static and
    /// pure so the status shapes are unit-testable without a document.
    static func fold(
        requests: [SearchRecheckRequest],
        observations: [PageObservation],
        pageCount: Int,
        shortfalls: [Shortfall] = [],
        coverageRan: Bool = true,
        coverageUnreadPages: [Int] = []
    ) -> Outcome {
        let requestCount = requests.count
        var remainingByRequest = [Int](repeating: 0, count: requestCount)
        var remainingPagesByRequest = [[Int]](repeating: [], count: requestCount)
        var perTermByRequest = [[String: Int]](repeating: [:], count: requestCount)
        var textPagesByRequest = [Int](repeating: 0, count: requestCount)
        var ocrPagesByRequest = [Int](repeating: 0, count: requestCount)
        var textPages = 0
        var ocrPages = 0
        // Pages read on both legs (counted in `textPages` and `ocrPages`).
        var bothPages = 0
        // Unchecked pages → reason clauses, in page order.
        var uncheckedClauses: [Int: [String]] = [:]
        // Requests the searcher refused to re-run on at least one page.
        var uncheckedByRequest = [Bool](repeating: false, count: requestCount)

        for observation in observations {
            let page = observation.pageIndex
            var pageWasRead = false
            switch observation.route {
            case .textLayer?:
                textPages += 1
                pageWasRead = true
            case .ocr?:
                ocrPages += 1
                if observation.textLayerRead {
                    textPages += 1
                    bothPages += 1
                }
                pageWasRead = true
            case .ocrSkippedOversize?:
                uncheckedClauses[page, default: []].append("too large to scan for text")
            case .ocrUnavailable?:
                uncheckedClauses[page, default: []].append("OCR did not run")
            case .unopenable?, nil:
                uncheckedClauses[page, default: []] = uncheckedClauses[page] ?? []
            }
            var pageHitCap = false
            var pageRefused = false
            var pageTimedOut = false
            for (requestIndex, count) in observation.counts {
                if count.rejected {
                    // No count for this request on this page: the page is
                    // unchecked for it, never clear.
                    uncheckedByRequest[requestIndex] = true
                    pageRefused = true
                    continue
                }
                // The request's own pattern ran out of time on the page:
                // unchecked for it; what it read before is still counted.
                if count.timedOut {
                    uncheckedByRequest[requestIndex] = true
                    pageTimedOut = true
                }
                remainingByRequest[requestIndex] += count.remaining
                if count.remaining > 0 {
                    remainingPagesByRequest[requestIndex].append(page)
                }
                for (term, n) in count.perTerm {
                    perTermByRequest[requestIndex][term, default: 0] += n
                }
                if count.hitCap { pageHitCap = true }
                if pageWasRead {
                    if observation.textLayerRead || observation.route == .textLayer {
                        textPagesByRequest[requestIndex] += 1
                    }
                    if observation.route == .ocr {
                        ocrPagesByRequest[requestIndex] += 1
                    }
                }
            }
            if pageHitCap {
                uncheckedClauses[page, default: []]
                    .append("the re-check stopped at 1,000 matches on the page")
            }
            if pageTimedOut {
                uncheckedClauses[page, default: []].append("the pattern took too long")
            }
            if pageRefused {
                uncheckedClauses[page, default: []].append("the pattern was not accepted")
            }
        }

        let totalRemaining = remainingByRequest.reduce(0, +)
        let remainingPages = Array(Set(remainingPagesByRequest.joined())).sorted()
        let uncheckedPages = uncheckedClauses.keys.sorted()

        let n = requestCount
        let searches = n == 1 ? "1 search" : "\(n) searches"
        let routeSentence = Self.routeSentence(textPages: textPages, ocrPages: ocrPages, bothPages: bothPages)
        let uncheckedList = uncheckedPages.map { page -> String in
            let clauses = uncheckedClauses[page] ?? []
            let number = String(page + 1)
            return clauses.isEmpty ? number : "\(number) (\(clauses.joined(separator: ", ")))"
        }.joined(separator: ", ")
        let k = uncheckedPages.count
        let uncheckedClause = k == 0
            ? ""
            : "\(k) \(k == 1 ? "page" : "pages") could not be checked: \(uncheckedList)"

        func joined(_ parts: [String]) -> String {
            parts.filter { !$0.isEmpty }.joined(separator: " ")
        }

        let queryLines: [SearchRecheckQueryLine] = requests.enumerated().map { index, request in
            let query = request.record.query
            let perTerm: [SearchRecheckQueryLine.PerTerm]?
            if case .multiTerm(let terms) = query.kind {
                perTerm = terms.map { term in
                    SearchRecheckQueryLine.PerTerm(
                        term: term, found: nil, applied: nil,
                        remaining: perTermByRequest[index][term] ?? 0)
                }
            } else {
                perTerm = nil
            }
            return SearchRecheckQueryLine(
                label: query.displayLabel,
                foundCount: request.record.foundCount,
                foundHitCap: request.record.foundHitCap,
                appliedCount: request.appliedCount,
                remainingCount: remainingByRequest[index],
                route: Self.route(textPages: textPagesByRequest[index],
                                  ocrPages: ocrPagesByRequest[index]),
                optionBadges: query.optionBadges,
                perTerm: perTerm,
                unchecked: uncheckedByRequest[index])
        }

        // A partly covered match outranks every other outcome: the box the
        // user applied does not cover what it was applied to.
        if !shortfalls.isEmpty {
            return shortfallOutcome(shortfalls, queryLines: queryLines)
        }

        if totalRemaining > 0 {
            let m = totalRemaining
            let list = remainingPages.map { String($0 + 1) }.joined(separator: ", ")
            let remainSentence = "\(m) \(m == 1 ? "match remains" : "matches remain") on \(pagePhrase(remainingPages, list: list))"
            let message = "Re-ran \(searches) — \(remainSentence)"
                + (k == 0 ? "" : ", \(uncheckedClause)")
                + (coverageRan ? "" : "; \(Self.coverageNotRunClause)")
                + (coverageUnreadPages.isEmpty ? "" : "; \(Self.coverageUnreadClause(coverageUnreadPages))")
            let detail = joined([Self.detailLead, routeSentence, remainSentence + ".",
                                 k == 0 ? "" : uncheckedClause + ".",
                                 coverageRan ? "" : Self.coverageNotRunDetail,
                                 coverageUnreadPages.isEmpty ? "" : Self.coverageUnreadDetail(coverageUnreadPages)])
            let reviewTerms = requests.enumerated()
                .filter { remainingByRequest[$0.offset] > 0 }
                .map { $0.element.record.query.displayText }
            return Outcome(
                status: .attention(message),
                copyOverride: LayerCopy(short: message, detail: detail),
                pageReferences: remainingPages,
                reviewTermTexts: reviewTerms,
                queryLines: queryLines)
        }

        // The could-not-verify WARN: pages the re-run could not check, the
        // coverage check that could not run or could not read a page it had
        // boxes on, or any of these together — each named.
        if k > 0 || !coverageRan || !coverageUnreadPages.isEmpty {
            let clauses = [uncheckedClause, coverageRan ? "" : Self.coverageNotRunClause,
                           coverageUnreadPages.isEmpty ? "" : Self.coverageUnreadClause(coverageUnreadPages)]
                .filter { !$0.isEmpty }.joined(separator: "; ")
            let message = "Re-ran \(searches); \(clauses)"
            let detail = joined([Self.detailLead, routeSentence,
                                 k == 0 ? "" : uncheckedClause + ".",
                                 coverageRan ? "" : Self.coverageNotRunDetail,
                                 coverageUnreadPages.isEmpty ? "" : Self.coverageUnreadDetail(coverageUnreadPages)])
            let pages = Array(Set(uncheckedPages + coverageUnreadPages)).sorted()
            return Outcome(
                status: .warn(message),
                copyOverride: LayerCopy(short: message, detail: detail),
                pageReferences: pages.isEmpty ? nil : pages,
                reviewTermTexts: nil,
                queryLines: queryLines)
        }

        let short = "Re-ran \(searches) on the output — no remaining matches in the text the app can read."
        let detail = joined([Self.detailLead, routeSentence])
        return Outcome(
            status: .pass,
            copyOverride: LayerCopy(short: short, detail: detail),
            pageReferences: nil,
            reviewTermTexts: nil,
            queryLines: queryLines)
    }

    /// The per-request route for a query line.
    static func route(textPages: Int, ocrPages: Int) -> SearchRecheckQueryLine.Route {
        switch (textPages > 0, ocrPages > 0) {
        case (true, false): .textLayer
        case (false, true): .ocr
        default: .mixed(textPages: textPages, ocrPages: ocrPages)
        }
    }

    /// The route sentence of the detail copy. Empty when no page was
    /// read at all — the copy then carries only the unchecked-page clause.
    /// `bothPages` of the pages were read on both legs and are counted in
    /// `textPages` and `ocrPages` alike.
    static func routeSentence(textPages: Int, ocrPages: Int, bothPages: Int = 0) -> String {
        switch (textPages > 0, ocrPages > 0) {
        case (true, false):
            return "Text was read from the output's text layer."
        case (false, true):
            return "Text was read by OCR from the rendered pages."
        case (true, true) where bothPages == textPages && bothPages == ocrPages:
            return "Text was read from the output's text layer and by OCR from the rendered pages."
        case (true, true):
            return "Text was read from the text layer on \(textPages) \(textPages == 1 ? "page" : "pages") and by OCR from the rendered pages on \(ocrPages)."
        case (false, false):
            return ""
        }
    }
}
