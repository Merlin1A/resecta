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
    /// `runLayer` contract).
    func run(
        outputDocument: SendablePDFDocument,
        requests: [SearchRecheckRequest],
        observations: [RecheckObservation]? = nil
    ) async throws -> Outcome {
        try Task.checkCancellation()
        let typed = requests.enumerated().filter { !$0.element.record.query.isScan }
        let typedRequests = typed.map(\.element)
        guard !typedRequests.isEmpty else {
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
        return Self.fold(requests: typedRequests, observations: observed, pageCount: pageCount)
    }

    // MARK: - Fold (pure)

    /// Fold sorted per-page observations into the layer outcome. Static and
    /// pure so the status shapes are unit-testable without a document.
    static func fold(
        requests: [SearchRecheckRequest],
        observations: [PageObservation],
        pageCount: Int
    ) -> Outcome {
        let requestCount = requests.count
        var remainingByRequest = [Int](repeating: 0, count: requestCount)
        var remainingPagesByRequest = [[Int]](repeating: [], count: requestCount)
        var perTermByRequest = [[String: Int]](repeating: [:], count: requestCount)
        var textPagesByRequest = [Int](repeating: 0, count: requestCount)
        var ocrPagesByRequest = [Int](repeating: 0, count: requestCount)
        var textPages = 0
        var ocrPages = 0
        // Unchecked pages → reason clauses (§5.2), in page order.
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
                pageWasRead = true
            case .ocrSkippedOversize?:
                uncheckedClauses[page, default: []].append("too large to scan for text")
            case .ocrUnavailable?:
                uncheckedClauses[page, default: []].append("OCR did not run")
            case .unopenable?, nil:
                uncheckedClauses[page, default: []] = uncheckedClauses[page] ?? []
            }
            if observation.regexTimedOut {
                uncheckedClauses[page, default: []].append("the pattern took too long")
            }
            var pageHitCap = false
            var pageRefused = false
            for (requestIndex, count) in observation.counts {
                if count.rejected {
                    // No count for this request on this page: the page is
                    // unchecked for it, never clear.
                    uncheckedByRequest[requestIndex] = true
                    pageRefused = true
                    continue
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
                    if observation.route == .textLayer {
                        textPagesByRequest[requestIndex] += 1
                    } else {
                        ocrPagesByRequest[requestIndex] += 1
                    }
                }
            }
            if pageHitCap {
                uncheckedClauses[page, default: []]
                    .append("the re-check stopped at 1,000 matches on the page")
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
        let routeSentence = Self.routeSentence(textPages: textPages, ocrPages: ocrPages)
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

        if totalRemaining > 0 {
            let m = totalRemaining
            let list = remainingPages.map { String($0 + 1) }.joined(separator: ", ")
            let remainSentence = "\(m) \(m == 1 ? "match remains" : "matches remain") on \(pagePhrase(remainingPages, list: list))"
            let message = "Re-ran \(searches) — \(remainSentence)"
                + (k == 0 ? "" : ", \(uncheckedClause)")
            let detail = joined([Self.detailLead, routeSentence, remainSentence + ".",
                                 k == 0 ? "" : uncheckedClause + "."])
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

        if k > 0 {
            let message = "Re-ran \(searches); \(uncheckedClause)"
            let detail = joined([Self.detailLead, routeSentence, uncheckedClause + "."])
            return Outcome(
                status: .warn(message),
                copyOverride: LayerCopy(short: message, detail: detail),
                pageReferences: uncheckedPages,
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

    /// The route sentence of the detail copy (§5.2). Empty when no page was
    /// read at all — the copy then carries only the unchecked-page clause.
    static func routeSentence(textPages: Int, ocrPages: Int) -> String {
        switch (textPages > 0, ocrPages > 0) {
        case (true, false):
            return "Text was read from the output's text layer."
        case (false, true):
            return "Text was read by OCR from the rendered pages."
        case (true, true):
            return "Text was read from the text layer on \(textPages) \(textPages == 1 ? "page" : "pages") and by OCR from the rendered pages on \(ocrPages)."
        case (false, false):
            return ""
        }
    }
}
