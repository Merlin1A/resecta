import Foundation
import PDFKit

// The Search Re-check layer (`VerificationLayer.searchRecheck`).
//
// Re-runs every applied search on the redacted output through
// `DocumentSearcher` itself — the text layer on pages that carry one, the
// searcher's own OCR path on image-only pages — and reports per query how
// many matches were found, how many the user applied, and how many remain
// in the text the app can read. Pages run in a bounded task group of width
// `VerificationEngine.ocrParallelism` (Layer 2's shape): each page becomes a
// one-page sub-document with ONE searcher, so the page's OCR is rendered
// once and cached across every request. Completion order never reaches a
// message — page lists are sorted before the fold.
//
// Honesty: a page the searcher could not read (OCR did not run, oversize,
// unopenable, regex timeout, the per-page result cap) is listed, never
// counted as clear. Query texts ride only the display-only fields
// (`reviewTermTexts`, `queryLines`); every status message is content-free.
// Nothing in this file logs.

struct SearchRecheck: Sendable {

    /// The idle message: no typed search was applied (or every region an
    /// applied search produced was deleted). Reported as `.info` — never
    /// `.skipped`, which the aggregate would degrade to WARN.
    static let infoMessage = "No searches were applied — the search re-check did not run."

    /// Lead sentence of the layer's own detail copy.
    static let detailLead = "Search Re-check re-ran each applied search on the output through the search engine."

    /// Copy the layer supplies for PASS / ATTENTION / WARN, replacing the
    /// engine's generic composition (the Layer-7 precedent).
    struct Copy: Sendable, Equatable {
        let short: String
        let detail: String
    }

    /// What `runLayer` folds into the `LayerResult`.
    struct Outcome: Sendable {
        let status: VerificationStatus
        let copyOverride: Copy?
        /// ATTENTION: pages with remaining matches. WARN: pages that could
        /// not be checked. Nil otherwise. 0-based.
        let pageReferences: [Int]?
        /// Display-only: `displayText` of every request with a remaining
        /// match, in request order. Nil unless ATTENTION.
        let reviewTermTexts: [String]?
        /// Display-only per-query lines. Nil on INFO.
        let queryLines: [SearchRecheckQueryLine]?
    }

    /// One page's observation, folded after the group completes.
    struct PageObservation: Sendable, Equatable {
        struct Count: Sendable, Equatable {
            var remaining: Int
            var hitCap: Bool
            var perTerm: [String: Int]
        }
        let pageIndex: Int
        /// The worst route the searcher reported for the page; nil when no
        /// request read it (every request's page bound excluded it, or the
        /// search finished without visiting the page).
        var route: PageSearchCoverage.Route?
        var regexTimedOut: Bool
        /// Keyed by request index.
        var counts: [Int: Count]
    }

    // MARK: - Run

    func run(
        outputDocument: SendablePDFDocument,
        requests: [SearchRecheckRequest],
        perPageModes: [PipelineMode]
    ) async throws -> Outcome {
        try Task.checkCancellation()
        guard !requests.isEmpty else {
            return Outcome(
                status: .info(Self.infoMessage), copyOverride: nil,
                pageReferences: nil, reviewTermTexts: nil, queryLines: nil)
        }

        let doc = outputDocument.document
        let pageCount = doc.pageCount
        // Per request: the pages it runs on (nil = every page).
        let boundPages: [Set<Int>?] = requests.map { $0.effectivePageBound ? $0.appliedPages : nil }

        var observations: [PageObservation] = []
        observations.reserveCapacity(pageCount)

        var pageIndex = 0
        while pageIndex < pageCount {
            try Task.checkCancellation()
            let chunkEnd = min(pageIndex + VerificationEngine.ocrParallelism, pageCount)

            // Phase 1 — sequential extraction on this task: PDFKit reads on the
            // shared document stay single-threaded (Layer 2's contract). Each
            // page's bytes become that page's own document inside the group.
            var work: [PageWork] = []
            for i in pageIndex..<chunkEnd {
                try Task.checkCancellation()
                let applicable = requests.indices.filter { boundPages[$0]?.contains(i) ?? true }
                guard !applicable.isEmpty else { continue }
                work.append(PageWork(
                    index: i,
                    data: doc.page(at: i)?.dataRepresentation,
                    requestIndices: applicable))
            }

            // Phase 2 — one searcher per page, bounded by the chunk width.
            let chunk = try await withThrowingTaskGroup(of: PageObservation.self) { group in
                for item in work {
                    group.addTask {
                        try Task.checkCancellation()
                        return await Self.observePage(item, requests: requests)
                    }
                }
                var out: [PageObservation] = []
                for try await observation in group {
                    out.append(observation)
                }
                return out
            }
            observations.append(contentsOf: chunk)
            pageIndex = chunkEnd
        }

        try Task.checkCancellation()
        return Self.fold(
            requests: requests,
            observations: observations.sorted { $0.pageIndex < $1.pageIndex },
            pageCount: pageCount)
    }

    private struct PageWork: Sendable {
        let index: Int
        let data: Data?
        let requestIndices: [Int]
    }

    /// Route + timeout collector for one page's searcher. The sinks fire
    /// from the actor; the box is locked so the values are read after the
    /// stream finishes.
    private final class CoverageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var worst: PageSearchCoverage.Route?
        private var timedOut = false

        private static func rank(_ route: PageSearchCoverage.Route?) -> Int {
            switch route {
            case nil: -1
            case .textLayer?: 0
            case .ocr?: 1
            case .ocrSkippedOversize?: 2
            case .ocrUnavailable?: 3
            case .unopenable?: 4
            }
        }

        func record(_ route: PageSearchCoverage.Route) {
            lock.lock(); defer { lock.unlock() }
            if Self.rank(route) > Self.rank(worst) { worst = route }
        }

        func recordTimeout() {
            lock.lock(); defer { lock.unlock() }
            timedOut = true
        }

        var snapshot: (route: PageSearchCoverage.Route?, timedOut: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (worst, timedOut)
        }
    }

    /// Run every applicable request on one page through its own searcher.
    private static func observePage(
        _ work: PageWork, requests: [SearchRecheckRequest]
    ) async -> PageObservation {
        var observation = PageObservation(
            pageIndex: work.index, route: nil, regexTimedOut: false, counts: [:])
        guard let data = work.data,
              let pageDocument = PDFDocument(data: data),
              pageDocument.pageCount >= 1 else {
            observation.route = .unopenable
            return observation
        }

        let searcher = DocumentSearcher()
        let box = CoverageBox()
        await searcher.setPageCoverageSink { coverage in box.record(coverage.route) }
        await searcher.setRegexTimeoutSink { _ in box.recordTimeout() }
        let wrapped = SendablePDFDocument(pageDocument)

        for requestIndex in work.requestIndices {
            if Task.isCancelled { break }
            let query = requests[requestIndex].record.query
            // The output may have no text layer at all; the searcher's own
            // OCR path is the route there, so OCR is forced on a copy of the
            // user's options. Every other option is the user's.
            var options = query.options
            options.includeOCR = true
            let mode = AppliedSearchQuery(kind: query.kind, options: options).searchMode

            var remaining = 0
            var perTerm: [String: Int] = [:]
            let stream = searcher.search(wrapped, mode: mode, progress: { _, _ in })
            for await result in stream {
                if Task.isCancelled { break }
                remaining += 1
                perTerm[result.term, default: 0] += 1
            }
            observation.counts[requestIndex] = PageObservation.Count(
                remaining: remaining,
                hitCap: remaining >= DocumentSearcher.maxResults,
                perTerm: perTerm)
        }

        let coverage = box.snapshot
        observation.route = coverage.route
        observation.regexTimedOut = coverage.timedOut
        return observation
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
            for (requestIndex, count) in observation.counts {
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
                perTerm: perTerm)
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
                copyOverride: Copy(short: message, detail: detail),
                pageReferences: remainingPages,
                reviewTermTexts: reviewTerms,
                queryLines: queryLines)
        }

        if k > 0 {
            let message = "Re-ran \(searches); \(uncheckedClause)"
            let detail = joined([Self.detailLead, routeSentence, uncheckedClause + "."])
            return Outcome(
                status: .warn(message),
                copyOverride: Copy(short: message, detail: detail),
                pageReferences: uncheckedPages,
                reviewTermTexts: nil,
                queryLines: queryLines)
        }

        let short = "Re-ran \(searches) on the output — no remaining matches in the text the app can read."
        let detail = joined([Self.detailLead, routeSentence])
        return Outcome(
            status: .pass,
            copyOverride: Copy(short: short, detail: detail),
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
