import Foundation
import PDFKit

// The per-page runner the Search Re-check and the Detection Sweep share.
//
// Every request — a typed search, an applied Scan, the run's sweep — is
// re-run on the redacted output through `DocumentSearcher` itself: the
// text layer on pages that carry one, the searcher's own OCR path on
// image-only pages. Pages run in a bounded task group of width
// `VerificationEngine.ocrParallelism` (Layer 2's shape): each page becomes
// a one-page sub-document with ONE searcher, so the page's OCR is rendered
// once and cached across every request, and each request's own
// configuration (a Scan's preset thresholds and user terms) is installed
// on that searcher before its stream. One observation per page covers
// every request; the folds (`SearchRecheck.fold`, `DetectionSweep.fold`)
// read them by request index. Completion order never reaches a message —
// the observations are sorted before they are returned.
//
// Honesty: a page the searcher could not read (OCR did not run, oversize,
// unopenable, a typed or custom regex term's timeout, the per-page result
// cap, a pattern the regex safety gate refused) is recorded as such, never
// counted as clear. A
// Scan's remaining items keep their page, category and rect for the
// sweep's subtraction; nothing here logs.

/// One page's observation, folded after the group completes.
struct RecheckObservation: Sendable, Equatable {
    /// One item a Scan request still reads on the output: where it is and
    /// what category read it. In memory for the fold only.
    struct RemainingItem: Sendable, Hashable {
        let pageIndex: Int
        /// Nil for an always-flag user term (no detector category).
        let category: PIICategory?
        let normalizedRect: CGRect
        let matchedText: String
    }

    struct Count: Sendable, Equatable {
        var remaining: Int
        var hitCap: Bool
        var perTerm: [String: Int]
        /// The searcher refused the request's pattern before reading the
        /// page; `remaining` is not a measurement.
        var rejected: Bool = false
        /// The request's own pattern — a typed regex, or a custom regex term
        /// of a Scan — ran out of time on the page; the page was not read
        /// in full for THIS request. Another request's timeout is not this
        /// request's.
        var timedOut: Bool = false
        /// A Scan request's remaining items (empty for a typed request).
        var items: [RemainingItem] = []
    }

    let pageIndex: Int
    /// The worst route the searcher reported for the page; nil when no
    /// request read it (the search finished without visiting the page).
    var route: PageSearchCoverage.Route?
    /// The page view: some request's pattern ran out of time here. The
    /// folds read the per-request `Count.timedOut`, never this.
    var regexTimedOut: Bool
    /// Keyed by request index.
    var counts: [Int: Count]
    /// The page's text layer was searched. With `route` `.ocr` the page was
    /// read on both legs: a text layer over image content (the hybrid route).
    var textLayerRead: Bool = false

    /// The same observation keyed by a subset of the requests, in the
    /// subset's order: `indices[k]` becomes key `k`; the page view follows
    /// the subset.
    func restricted(to indices: [Int]) -> RecheckObservation {
        var subset: [Int: Count] = [:]
        for (k, original) in indices.enumerated() {
            if let count = counts[original] { subset[k] = count }
        }
        return RecheckObservation(
            pageIndex: pageIndex, route: route,
            regexTimedOut: subset.values.contains(where: \.timedOut), counts: subset,
            textLayerRead: textLayerRead)
    }
}

struct OutputRecheck: Sendable {

    /// Per-call override of the searcher's per-page regex budget
    /// (`DocumentSearcher.regexTimeoutOverride`), handed to every page's
    /// searcher. Production leaves it nil; a test sets it to make a regex
    /// term run out of time on a page without waiting the budget out.
    var regexTimeoutOverride: Duration? = nil

    /// Re-run every request on every page of `outputDocument`; one
    /// observation per page, in page order, counts keyed by request index.
    func observe(
        outputDocument: SendablePDFDocument,
        requests: [SearchRecheckRequest]
    ) async throws -> [RecheckObservation] {
        try Task.checkCancellation()
        let doc = outputDocument.document
        let pageCount = doc.pageCount
        let requestIndices = Array(requests.indices)

        var observations: [RecheckObservation] = []
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
                work.append(PageWork(
                    index: i,
                    data: doc.page(at: i)?.dataRepresentation,
                    requestIndices: requestIndices))
            }

            // Phase 2 — one searcher per page, bounded by the chunk width.
            let chunk = try await withThrowingTaskGroup(of: RecheckObservation.self) { group in
                for item in work {
                    group.addTask {
                        try Task.checkCancellation()
                        return await Self.observePage(
                            item, requests: requests, regexTimeoutOverride: regexTimeoutOverride)
                    }
                }
                var out: [RecheckObservation] = []
                for try await observation in group {
                    out.append(observation)
                }
                return out
            }
            observations.append(contentsOf: chunk)
            pageIndex = chunkEnd
        }

        try Task.checkCancellation()
        return observations.sorted { $0.pageIndex < $1.pageIndex }
    }

    private struct PageWork: Sendable {
        let index: Int
        let data: Data?
        let requestIndices: [Int]
    }

    /// Route collector for one page's searcher. The sink fires from the
    /// actor; the box is locked so the value is read after the stream
    /// finishes.
    private final class CoverageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var worst: PageSearchCoverage.Route?
        private var sawTextLayer = false

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
            if route == .textLayer { sawTextLayer = true }
        }

        var textLayerSeen: Bool {
            lock.lock(); defer { lock.unlock() }
            return sawTextLayer
        }

        var snapshot: PageSearchCoverage.Route? {
            lock.lock(); defer { lock.unlock() }
            return worst
        }
    }

    /// Set once by one of the searcher's sinks during one request's stream
    /// (the rejection sink; the two timeout sinks).
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.lock(); fired = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    /// Run every request on one page through its own searcher.
    private static func observePage(
        _ work: PageWork, requests: [SearchRecheckRequest], regexTimeoutOverride: Duration?
    ) async -> RecheckObservation {
        var observation = RecheckObservation(
            pageIndex: work.index, route: nil, regexTimedOut: false, counts: [:])
        guard let data = work.data,
              let pageDocument = PDFDocument(data: data),
              pageDocument.pageCount >= 1 else {
            observation.route = .unopenable
            return observation
        }

        // The page's text-layer status as the import reads it, so a page
        // whose rebuilt layer is only a header is re-run through OCR, not
        // trusted for its body (the one-page document's page is index 0).
        let status: [Int: TextLayerStatus] = pageDocument.page(at: 0).map { [0: TextLayerDetector.detectTextLayer($0)] } ?? [:]
        let searcher = DocumentSearcher(regexTimeoutOverride: regexTimeoutOverride, textLayerStatusByPage: status)
        let box = CoverageBox()
        await searcher.setPageCoverageSink { coverage in box.record(coverage.route) }
        let wrapped = SendablePDFDocument(pageDocument)

        for requestIndex in work.requestIndices {
            if Task.isCancelled { break }
            let request = requests[requestIndex]
            let query = request.record.query
            // The output may have no text layer at all; the searcher's own
            // OCR path is the route there, so OCR is forced on a copy of the
            // user's options. Every other option is the user's.
            var options = query.options
            options.includeOCR = true
            // A scan re-runs through the category gate: the structured
            // families only (`DetectionSweep.gatedCategories`).
            var kind = query.kind
            if case .piiScan(let categories) = kind {
                kind = .piiScan(categories: categories.intersection(DetectionSweep.gatedCategories))
            }
            let mode = AppliedSearchQuery(kind: kind, options: options).searchMode
            // A Scan re-runs with the thresholds and user terms it ran with
            // (nil for a typed search — the searcher's own default). The
            // setters are actor calls that land before the stream starts.
            let configuration = request.record.scanConfiguration
            await searcher.setThresholdVector(configuration?.thresholdVector)
            await searcher.setUserTerms(configuration?.userTermsIndex)

            var remaining = 0
            var perTerm: [String: Int] = [:]
            var items: [RecheckObservation.RemainingItem] = []
            // A pattern the safety gate refuses finishes the stream empty;
            // the sink is what tells that apart from a page with no match.
            let rejection = OnceFlag()
            await searcher.setRegexRejectionSink { _ in rejection.set() }
            // A pattern that runs out of time — the typed regex, or a custom
            // regex term of a Scan running out its share of the page budget
            // — reports through one of two sinks; both land on THIS request's
            // flag, installed fresh per request so no timeout crosses over.
            let timeout = OnceFlag()
            await searcher.setRegexTimeoutSink { _ in timeout.set() }
            await searcher.setUserTermsTimeoutSink { _, _ in timeout.set() }
            let stream = searcher.search(wrapped, mode: mode, progress: { _, _ in })
            for await result in stream {
                if Task.isCancelled { break }
                remaining += 1
                perTerm[result.term, default: 0] += 1
                if query.isScan {
                    items.append(RecheckObservation.RemainingItem(
                        pageIndex: work.index,
                        category: result.piiCategory,
                        normalizedRect: result.normalizedRect,
                        matchedText: result.matchedText))
                }
            }
            observation.counts[requestIndex] = RecheckObservation.Count(
                remaining: remaining,
                hitCap: remaining >= DocumentSearcher.maxResults,
                perTerm: perTerm,
                rejected: rejection.value,
                timedOut: timeout.value,
                items: items)
        }

        observation.route = box.snapshot
        observation.textLayerRead = box.textLayerSeen
        observation.regexTimedOut = observation.counts.values.contains(where: \.timedOut)
        return observation
    }
}
