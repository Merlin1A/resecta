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
// unopenable, regex timeout, the per-page result cap, a pattern the regex
// safety gate refused) is recorded as such, never counted as clear. A
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
        /// A Scan request's remaining items (empty for a typed request).
        var items: [RemainingItem] = []
    }

    let pageIndex: Int
    /// The worst route the searcher reported for the page; nil when no
    /// request read it (the search finished without visiting the page).
    var route: PageSearchCoverage.Route?
    var regexTimedOut: Bool
    /// Keyed by request index.
    var counts: [Int: Count]

    /// The same observation keyed by a subset of the requests, in the
    /// subset's order: `indices[k]` becomes key `k`.
    func restricted(to indices: [Int]) -> RecheckObservation {
        var subset: [Int: Count] = [:]
        for (k, original) in indices.enumerated() {
            if let count = counts[original] { subset[k] = count }
        }
        return RecheckObservation(
            pageIndex: pageIndex, route: route, regexTimedOut: regexTimedOut, counts: subset)
    }
}

struct OutputRecheck: Sendable {

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
                        return await Self.observePage(item, requests: requests)
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

    /// Set once by the searcher's rejection sink for one request.
    private final class RejectionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.lock(); fired = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    /// Run every request on one page through its own searcher.
    private static func observePage(
        _ work: PageWork, requests: [SearchRecheckRequest]
    ) async -> RecheckObservation {
        var observation = RecheckObservation(
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
            let rejection = RejectionFlag()
            await searcher.setRegexRejectionSink { _ in rejection.set() }
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
                items: items)
        }

        let coverage = box.snapshot
        observation.route = coverage.route
        observation.regexTimedOut = coverage.timedOut
        return observation
    }
}
