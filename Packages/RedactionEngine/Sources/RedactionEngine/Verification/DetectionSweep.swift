import Foundation
import CoreGraphics
import PDFKit

// The Detection Sweep layer (`VerificationLayer.detectionSweep`).
//
// Re-runs the applied Scan on the redacted output through the detectors
// (the same `DocumentSearcher` mode the user ran, with the thresholds and
// user terms of that run), subtracts the items the user left unselected
// at apply, and — through the run's synthesized sweep request — runs every
// detector for anything further outside the scan's categories. The page
// loop is `OutputRecheck`, shared with the Search Re-check so the two rows
// read one OCR pass per page.
//
// The category gate (ruled on the sweep-residual measurement over the
// corpus): the structured families only — names and addresses are not
// swept, by either origin.
// On fully-applied output the detectors re-read names at a rate no user
// could act on (three quarters of the residual), while the structured
// families sit at a median of zero. The row's detail says so.
//
// Tier: PASS when nothing further remains (a detail sentence when the
// remaining items are exactly the ones left unredacted), INFO with page
// chips when something further remains, WARN could-not-verify for pages
// the searcher could not read. Never ATTENTION — that tier stays reserved
// for text matching an APPLIED region. Every status message is content-free
// (no matched text, no category name); category names ride only the
// display-only `queryLines`. Nothing in this file logs.

struct DetectionSweep: Sendable {

    /// The idle message: no scan was applied and no sweep was requested
    /// (a verify-only resume of an older session). Reported as `.info` —
    /// never `.skipped`, which the aggregate would degrade to WARN.
    static let infoMessage = "No scan was applied — the detection sweep did not run."

    /// Lead sentences of the layer's own detail copy, by what ran.
    static let detailLeadApplied = "Detection Sweep re-ran your scan on the output through the detectors."
    static let detailLeadAppliedAndSweep = "Detection Sweep re-ran your scan on the output through the detectors and ran every detector for items outside its categories."
    static let detailLeadSweep = "Detection Sweep ran every detector on the output."

    /// The categories the sweep and the scan re-run read on the output: the
    /// structured families. Names and addresses are not swept.
    static let gatedCategories: Set<PIICategory> =
        Set(PIICategory.allCases).subtracting([.name, .address])

    /// Whether a remaining item counts: an always-flag hit (no category)
    /// does; a detector hit counts by its category's gate.
    static func isSwept(_ category: PIICategory?) -> Bool {
        category.map { gatedCategories.contains($0) } ?? true
    }

    /// The detail sentence that says what the gate leaves out.
    static let gateSentence = "Names and addresses are not swept."

    /// A deselected item subtracts one remaining item on the same page and
    /// category: the one that reads the same text, else one whose rect
    /// overlaps it by at least this intersection over union (the text pairs
    /// an OCR-read item whose box drifted; the overlap pairs one whose text
    /// OCR misread).
    static let subtractionOverlap: CGFloat = 0.5

    /// What `runLayer` folds into the `LayerResult`.
    struct Outcome: Sendable {
        let status: VerificationStatus
        let copyOverride: LayerCopy?
        /// INFO: pages with something further. WARN: pages that could not
        /// be checked, plus those. Nil otherwise. 0-based.
        let pageReferences: [Int]?
        /// Always nil: the sweep never names text at the masthead.
        let reviewTermTexts: [String]?
        /// Display-only per-request lines. Nil on the idle INFO.
        let queryLines: [SearchRecheckQueryLine]?
    }

    // MARK: - Run

    /// Fold the scan requests among `requests` (the applied scans and the
    /// sweep). `observations` are the shared runner's, keyed by index into
    /// the FULL request list; nil runs the page loop here for the scan
    /// requests alone (the public `runLayer` contract).
    func run(
        outputDocument: SendablePDFDocument,
        requests: [SearchRecheckRequest],
        observations: [RecheckObservation]?
    ) async throws -> Outcome {
        try Task.checkCancellation()
        let scans = requests.enumerated().filter { $0.element.record.query.isScan }
        let scanRequests = scans.map(\.element)
        guard !scanRequests.isEmpty else { return Self.idle }
        let pageCount = outputDocument.document.pageCount
        let observed: [RecheckObservation]
        if let observations {
            let indices = scans.map(\.offset)
            observed = observations.map { $0.restricted(to: indices) }
        } else {
            observed = try await OutputRecheck().observe(
                outputDocument: outputDocument, requests: scanRequests)
        }
        try Task.checkCancellation()
        return Self.fold(requests: scanRequests, observations: observed, pageCount: pageCount)
    }

    private static let idle = Outcome(
        status: .info(infoMessage), copyOverride: nil,
        pageReferences: nil, reviewTermTexts: nil, queryLines: nil)

    // MARK: - Fold (pure)

    /// Fold sorted per-page observations into the layer outcome. Static and
    /// pure so the status shapes are unit-testable without a document.
    /// `requests` are the scan requests only; observations are keyed by
    /// their indices.
    static func fold(
        requests: [SearchRecheckRequest],
        observations: [RecheckObservation],
        pageCount: Int
    ) -> Outcome {
        guard !requests.isEmpty else { return idle }
        let requestCount = requests.count
        var rawRemainingByRequest = [Int](repeating: 0, count: requestCount)
        var itemsByRequest = [[RecheckObservation.RemainingItem]](repeating: [], count: requestCount)
        var textPagesByRequest = [Int](repeating: 0, count: requestCount)
        var ocrPagesByRequest = [Int](repeating: 0, count: requestCount)
        var textPages = 0
        var ocrPages = 0
        // Unchecked pages → reason clauses (the re-check's vocabulary), in page order.
        var uncheckedClauses: [Int: [String]] = [:]
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
            for (requestIndex, count) in observation.counts where requestIndex < requestCount {
                if count.rejected {
                    uncheckedByRequest[requestIndex] = true
                    pageRefused = true
                    continue
                }
                // The gate: only swept categories count (the runner already
                // reads only those; a caller-built observation is filtered
                // the same way).
                let swept = count.items.filter { isSwept($0.category) }
                rawRemainingByRequest[requestIndex] += count.items.isEmpty ? count.remaining : swept.count
                itemsByRequest[requestIndex].append(contentsOf: swept)
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

        // The subtraction: each item the user left unselected consumes ONE
        // remaining item of its own request on the same page and category —
        // by text first, by overlap second (`subtractDeselected`). Never two.
        var subtractedByRequest = [Int](repeating: 0, count: requestCount)
        var furtherByRequest = [[RecheckObservation.RemainingItem]](repeating: [], count: requestCount)
        for index in requests.indices {
            let subtraction = requests[index].origin == .applied
                ? subtractDeselected(requests[index].deselected, from: itemsByRequest[index])
                : (remaining: itemsByRequest[index], consumed: 0)
            subtractedByRequest[index] = subtraction.consumed
            furtherByRequest[index] = subtraction.remaining
        }

        // The scope split: an applied scan's categories are "yours"; the
        // sweep reports what it reads outside them. Without an applied scan
        // everything the sweep reads is a possible item. A custom-term hit
        // (no category) belongs to an applied scan only when that scan
        // carried a term that reads the hit's text — a remaining item keeps
        // its text, not its pattern — so a term added after the apply is a
        // possible item, not the scan's.
        let appliedIndices = requests.indices.filter { requests[$0].origin == .applied }
        let sweepIndices = requests.indices.filter { requests[$0].origin == .sweep }
        let hasApplied = !appliedIndices.isEmpty
        let hasSweep = !sweepIndices.isEmpty
        var appliedCategories = Set<PIICategory>()
        for index in appliedIndices {
            if case .piiScan(let categories) = requests[index].record.query.kind {
                appliedCategories.formUnion(categories)
            }
        }
        let rawRemaining = appliedIndices.reduce(0) { $0 + rawRemainingByRequest[$1] }
        let subtracted = appliedIndices.reduce(0) { $0 + subtractedByRequest[$1] }
        let furtherApplied = appliedIndices.flatMap { furtherByRequest[$0] }
        let carriedTerms = UserTermMatcher.compile(
            alwaysFlag: appliedIndices.flatMap { requests[$0].record.scanConfiguration?.alwaysFlag ?? [] },
            neverFlag: [])
        var outOfScopeByRequest = [[RecheckObservation.RemainingItem]](repeating: [], count: requestCount)
        for index in sweepIndices {
            outOfScopeByRequest[index] = furtherByRequest[index].filter { item in
                guard hasApplied else { return true }
                guard let category = item.category else {
                    return carriedTerms.matchesAlwaysFlag(item.matchedText) == nil
                }
                return !appliedCategories.contains(category)
            }
        }
        let outOfScope = sweepIndices.flatMap { outOfScopeByRequest[$0] }
        let further = furtherApplied.count
        let possible = outOfScope.count
        let furtherPages = Array(Set((furtherApplied + outOfScope).map(\.pageIndex))).sorted()
        let uncheckedPages = uncheckedClauses.keys.sorted()

        // Copy pieces.
        func joined(_ parts: [String]) -> String {
            parts.filter { !$0.isEmpty }.joined(separator: " ")
        }
        let lead = hasApplied ? "Re-ran your scan on the output" : "Ran the detectors on the output"
        let leadSentence: String
        switch (hasApplied, hasSweep) {
        case (true, true): leadSentence = detailLeadAppliedAndSweep
        case (true, false): leadSentence = detailLeadApplied
        default: leadSentence = detailLeadSweep
        }
        let routeSentence = joined([SearchRecheck.routeSentence(textPages: textPages, ocrPages: ocrPages), gateSentence])
        let furtherPageList = furtherPages.map { String($0 + 1) }.joined(separator: ", ")
        let onPages = "on \(pagePhrase(furtherPages, list: furtherPageList))"
        func remainWord(_ n: Int) -> String { n == 1 ? "remains" : "remain" }
        func itemWord(_ n: Int) -> String { n == 1 ? "possible item" : "possible items" }
        let leftClause = subtracted > 0 ? " (\(subtracted) you left unredacted)" : ""
        let uncheckedList = uncheckedPages.map { page -> String in
            let clauses = uncheckedClauses[page] ?? []
            let number = String(page + 1)
            return clauses.isEmpty ? number : "\(number) (\(clauses.joined(separator: ", ")))"
        }.joined(separator: ", ")
        let k = uncheckedPages.count
        let uncheckedClause = k == 0
            ? ""
            : "\(k) \(k == 1 ? "page" : "pages") could not be checked: \(uncheckedList)"
        // The "further" body: what remains beyond the items left unredacted.
        let hasFurther = further > 0 || possible > 0
        let furtherBody: String
        switch (hasApplied, hasSweep) {
        case (true, true):
            let inScope = rawRemaining == 0
                ? "nothing further"
                : "\(rawRemaining) \(remainWord(rawRemaining))\(leftClause)"
            let outScope = possible == 0 ? "nothing further" : "\(possible) \(itemWord(possible))"
            furtherBody = "in your scan's categories: \(inScope); outside them: \(outScope) \(onPages)"
        case (true, false):
            furtherBody = "\(rawRemaining) \(remainWord(rawRemaining)) \(onPages)\(leftClause)"
        default:
            furtherBody = "\(possible) \(itemWord(possible)) \(remainWord(possible)) \(onPages)"
        }
        let furtherSentence = hasFurther
            ? furtherBody.prefix(1).uppercased() + furtherBody.dropFirst() + "."
            : ""

        // Display-only per-request lines: an applied scan's line counts what
        // it read (the subtraction is said in the status); the sweep's line
        // counts what it read outside the applied categories, or everything
        // when no scan was applied. Per-category sub-lines name only the
        // categories that read something, by name.
        let queryLines: [SearchRecheckQueryLine] = requests.enumerated().map { index, request in
            let counted: [RecheckObservation.RemainingItem]
            let remaining: Int
            if request.origin == .sweep && hasApplied {
                counted = outOfScopeByRequest[index]
                remaining = counted.count
            } else {
                counted = itemsByRequest[index]
                remaining = rawRemainingByRequest[index]
            }
            var perCategory: [String: Int] = [:]
            for item in counted {
                perCategory[item.category?.rawValue ?? "Custom", default: 0] += 1
            }
            let perTerm = perCategory.keys.sorted().map { name in
                SearchRecheckQueryLine.PerTerm(
                    term: name, found: nil, applied: nil, remaining: perCategory[name] ?? 0)
            }
            return SearchRecheckQueryLine(
                label: request.record.query.displayLabel,
                foundCount: request.record.foundCount,
                foundHitCap: request.record.foundHitCap,
                appliedCount: request.appliedCount,
                remainingCount: remaining,
                route: SearchRecheck.route(textPages: textPagesByRequest[index],
                                           ocrPages: ocrPagesByRequest[index]),
                optionBadges: [],
                perTerm: perTerm.isEmpty ? nil : perTerm,
                unchecked: uncheckedByRequest[index])
        }

        // A page the check could not read outranks every note (the
        // could-not-verify precedence): the WARN carries the further items
        // in its detail and its page chips.
        if k > 0 {
            let message = "\(lead); \(uncheckedClause)"
            let detail = joined([leadSentence, routeSentence, furtherSentence, uncheckedClause + "."])
            return Outcome(
                status: .warn(message),
                copyOverride: LayerCopy(short: message, detail: detail),
                pageReferences: Array(Set(uncheckedPages + furtherPages)).sorted(),
                reviewTermTexts: nil,
                queryLines: queryLines)
        }

        if hasFurther {
            let message = "\(lead) — \(furtherBody). Open Scan to review."
            let detail = joined([leadSentence, routeSentence, furtherSentence])
            return Outcome(
                status: .info(message),
                copyOverride: LayerCopy(short: message, detail: detail),
                pageReferences: furtherPages,
                reviewTermTexts: nil,
                queryLines: queryLines)
        }

        // Nothing further: PASS, with the subtraction said when it explains
        // everything that remains.
        let short: String
        let explained = subtracted > 0
            ? "\(rawRemaining) \(remainWord(rawRemaining)), the \(subtracted) you left unredacted"
            : ""
        switch (hasApplied, hasSweep) {
        case (true, true):
            short = subtracted > 0
                ? "\(lead) — \(explained); nothing further outside your scan's categories."
                : "\(lead) — the detectors reported nothing further, inside or outside your scan's categories."
        case (true, false):
            short = subtracted > 0
                ? "\(lead) — \(explained)."
                : "\(lead) — the detectors reported nothing further."
        default:
            short = "\(lead) — nothing further reported."
        }
        let detail = joined([leadSentence, routeSentence,
                             explained.isEmpty ? "" : explained.prefix(1).uppercased() + explained.dropFirst() + "."])
        return Outcome(
            status: .pass,
            copyOverride: LayerCopy(short: short, detail: detail),
            pageReferences: nil,
            reviewTermTexts: nil,
            queryLines: queryLines)
    }

    /// The text key the subtraction pairs on first: search-normalized
    /// (ligatures expanded, compatibility forms folded, case-folded), with
    /// runs of whitespace collapsed to one space.
    static func pairingText(_ text: String) -> String {
        TextNormalizer.normalizeForSearch(text, caseSensitive: false)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Pair each deselected item with ONE remaining item of the same page
    /// and category: the one that reads the same text (the best overlap
    /// among those, whatever the overlap), else the best rect overlap at or
    /// above `subtractionOverlap`. Returns what remains and how many paired.
    static func subtractDeselected(
        _ deselected: [SearchResult], from items: [RecheckObservation.RemainingItem]
    ) -> (remaining: [RecheckObservation.RemainingItem], consumed: Int) {
        var pool = items
        var consumed = 0
        for left in deselected {
            let leftText = pairingText(left.matchedText)
            var best: (position: Int, byText: Bool, overlap: CGFloat)?
            for (position, item) in pool.enumerated()
            where item.pageIndex == left.pageIndex && item.category == left.piiCategory {
                let overlap = intersectionOverUnion(item.normalizedRect, left.normalizedRect)
                let byText = pairingText(item.matchedText) == leftText
                guard byText || overlap >= subtractionOverlap else { continue }
                if let current = best,
                   !((byText && !current.byText) || (byText == current.byText && overlap > current.overlap)) {
                    continue
                }
                best = (position, byText, overlap)
            }
            if let best {
                pool.remove(at: best.position)
                consumed += 1
            }
        }
        return (pool, consumed)
    }

    /// Intersection over union of two normalized rects; 0 when either is
    /// empty or they do not meet.
    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let inter = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - inter
        guard union > 0 else { return 0 }
        return inter / union
    }
}
