import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// The Detection Sweep's pure fold: the applied scan's re-run minus the
// items the user left unselected (page + category + rect IoU ≥ 0.5, one
// for one), the in/out-of-scope split against the applied scan's
// categories, the PASS / PASS-with-detail / INFO / WARN shapes — never
// ATTENTION — and content-free status messages. Fixture values are the
// threshold suites' public vocabulary.

@Suite("Detection Sweep fold")
struct DetectionSweepFoldTests {

    private typealias Item = RecheckObservation.RemainingItem
    private typealias Count = RecheckObservation.Count

    private func rect(_ x: Double, _ y: Double, _ w: Double = 0.2, _ h: Double = 0.04) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private func item(_ page: Int, _ category: PIICategory?, _ r: CGRect, text: String = "123-45-6789") -> Item {
        Item(pageIndex: page, category: category, normalizedRect: r, matchedText: text)
    }

    private func result(_ page: Int, _ category: PIICategory, _ r: CGRect) -> SearchResult {
        SearchResult(pageIndex: page, normalizedRect: r, matchedText: "123-45-6789", contextSnippet: "",
                     source: .textLayer, term: category.rawValue, piiCategory: category)
    }

    private func applied(
        _ categories: Set<PIICategory>, found: Int = 4, applied: Int = 4, deselected: [SearchResult] = []
    ) -> SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: AppliedSearchQuery(kind: .piiScan(categories: categories), options: SearchOptions()),
                foundCount: found),
            appliedCount: applied, appliedPages: [0], deselected: deselected)
    }

    private var sweep: SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: AppliedSearchQuery(kind: .piiScan(categories: Set(PIICategory.allCases)), options: SearchOptions()),
                foundCount: 0),
            appliedCount: 0, appliedPages: [], origin: .sweep)
    }

    /// One page's observation: per request index, the items the stream yielded.
    private func page(_ index: Int, route: PageSearchCoverage.Route? = .textLayer,
                      _ itemsByRequest: [Int: [Item]]) -> RecheckObservation {
        var counts: [Int: Count] = [:]
        for (request, items) in itemsByRequest {
            var perTerm: [String: Int] = [:]
            for i in items { perTerm[i.category?.rawValue ?? "Custom", default: 0] += 1 }
            counts[request] = Count(remaining: items.count, hitCap: false, perTerm: perTerm, items: items)
        }
        return RecheckObservation(pageIndex: index, route: route, regexTimedOut: false, counts: counts)
    }

    private func message(_ status: VerificationStatus) -> String {
        switch status {
        case .fail(let m), .warn(let m), .info(let m), .attention(let m): m
        case .pass, .skipped: ""
        }
    }

    // MARK: - The subtraction

    @Test("A deselected item removes ONE remaining item on its page and category with IoU ≥ 0.5, never two")
    func subtractionOneForOne() {
        let r = rect(0.1, 0.5)
        let twin = rect(0.1, 0.5)
        let request = applied([.ssn], deselected: [result(0, .ssn, r)])
        let outcome = DetectionSweep.fold(
            requests: [request],
            observations: [page(0, [0: [item(0, .ssn, r), item(0, .ssn, twin)]])],
            pageCount: 1)
        #expect(outcome.status.isInfo, "two remain, one was left unredacted → one is further; got \(outcome.status)")
        #expect(message(outcome.status).contains("2 remain"))
        #expect(message(outcome.status).contains("(1 you left unredacted)"))
        #expect(outcome.pageReferences == [0])
        #expect(outcome.queryLines?.first?.remainingCount == 2)
    }

    @Test("IoU just under the bar does not subtract; a different category does not subtract")
    func subtractionNeedsOverlapAndCategory() {
        let base = rect(0.10, 0.50, 0.20, 0.04)
        // Same height, shifted so the overlap is 0.49 of the union.
        let shifted = CGRect(x: 0.10 + 0.20 * (1 - 0.49) / (1 + 0.49) + 0.0001, y: 0.50, width: 0.20, height: 0.04)
        #expect(DetectionSweep.intersectionOverUnion(base, shifted) < 0.5)
        #expect(DetectionSweep.intersectionOverUnion(base, shifted) > 0.45)
        let underBar = DetectionSweep.fold(
            requests: [applied([.ssn], deselected: [result(0, .ssn, shifted)])],
            observations: [page(0, [0: [item(0, .ssn, base)]])], pageCount: 1)
        #expect(underBar.status.isInfo, "IoU under 0.5 leaves the item further; got \(underBar.status)")
        #expect(!message(underBar.status).contains("left unredacted"))

        let otherCategory = DetectionSweep.fold(
            requests: [applied([.ssn, .phone], deselected: [result(0, .phone, base)])],
            observations: [page(0, [0: [item(0, .ssn, base)]])], pageCount: 1)
        #expect(otherCategory.status.isInfo, "a different category never subtracts; got \(otherCategory.status)")

        let otherPage = DetectionSweep.fold(
            requests: [applied([.ssn], deselected: [result(1, .ssn, base)])],
            observations: [page(0, [0: [item(0, .ssn, base)]]), page(1, [0: []])], pageCount: 2)
        #expect(otherPage.status.isInfo, "a different page never subtracts; got \(otherPage.status)")

        let exact = DetectionSweep.fold(
            requests: [applied([.ssn], deselected: [result(0, .ssn, base)])],
            observations: [page(0, [0: [item(0, .ssn, base)]])], pageCount: 1)
        #expect(exact.status == .pass, "the one remaining item is the one left unredacted; got \(exact.status)")
        #expect(exact.copyOverride?.short == "Re-ran your scan on the output — 1 remains, the 1 you left unredacted.")
        #expect(exact.copyOverride?.detail.isEmpty == false)
        #expect(exact.pageReferences == nil)
    }

    // MARK: - The shapes

    @Test("PASS: nothing further — the applied origin's copy")
    func passNothingFurtherApplied() {
        let outcome = DetectionSweep.fold(
            requests: [applied([.ssn])], observations: [page(0, [0: []]), page(1, [0: []])], pageCount: 2)
        #expect(outcome.status == .pass)
        #expect(outcome.copyOverride?.short == "Re-ran your scan on the output — the detectors reported nothing further.")
        #expect(outcome.copyOverride?.detail == "\(DetectionSweep.detailLeadApplied) Text was read from the output's text layer.")
        #expect(outcome.pageReferences == nil)
        #expect(outcome.reviewTermTexts == nil)
        let line = try? #require(outcome.queryLines?.first)
        #expect(line?.label == "Scan (1 detector)")
        #expect(line?.foundCount == 4)
        #expect(line?.appliedCount == 4)
        #expect(line?.remainingCount == 0)
        #expect(line?.perTerm == nil)
        #expect(line?.route == .textLayer)
    }

    @Test("PASS: nothing further — the sweep origin's copy")
    func passNothingFurtherSweep() {
        let outcome = DetectionSweep.fold(
            requests: [sweep], observations: [page(0, route: .ocr, [0: []])], pageCount: 1)
        #expect(outcome.status == .pass)
        #expect(outcome.copyOverride?.short == "Ran the detectors on the output — nothing further reported.")
        #expect(outcome.copyOverride?.detail == "\(DetectionSweep.detailLeadSweep) Text was read by OCR from the rendered pages.")
        #expect(outcome.queryLines?.first?.label == "Scan (\(PIICategory.allCases.count) detectors)")
        #expect(outcome.queryLines?.first?.route == .ocr)
    }

    @Test("INFO with page chips: the sweep origin reports possible items on their pages")
    func infoSweepPossibleItems() {
        let outcome = DetectionSweep.fold(
            requests: [sweep],
            observations: [
                page(0, [0: []]),
                page(1, [0: [item(1, .phone, rect(0.1, 0.2)), item(1, .email, rect(0.1, 0.3))]]),
                page(4, [0: [item(4, .ssn, rect(0.1, 0.2))]]),
            ], pageCount: 5)
        #expect(outcome.status.isInfo, "got \(outcome.status)")
        #expect(message(outcome.status) == "Ran the detectors on the output — 3 possible items remain on 2 pages: 2, 5. Open Scan to review.")
        #expect(outcome.pageReferences == [1, 4])
        #expect(outcome.reviewTermTexts == nil)
        let line = try? #require(outcome.queryLines?.first)
        #expect(line?.remainingCount == 3)
        #expect(line?.perTerm?.map(\.term) == ["Email", "Phone", "SSN"], "per category, by name")
        #expect(line?.perTerm?.map(\.remaining) == [1, 1, 1])
        #expect(outcome.copyOverride == nil, "INFO uses the generic composition")
    }

    @Test("INFO: an applied scan beside the sweep splits in-scope and out-of-scope; both sub-lines")
    func infoSplitInAndOutOfScope() {
        let left = rect(0.5, 0.5)
        let outcome = DetectionSweep.fold(
            requests: [applied([.ssn, .name], deselected: [result(0, .ssn, left)]), sweep],
            observations: [
                page(0, [0: [item(0, .ssn, left), item(0, .name, rect(0.1, 0.1))],
                         1: [item(0, .ssn, left), item(0, .name, rect(0.1, 0.1)), item(0, .email, rect(0.1, 0.8))]]),
                page(2, [0: [], 1: [item(2, .phone, rect(0.1, 0.1))]]),
            ], pageCount: 3)
        #expect(outcome.status.isInfo, "got \(outcome.status)")
        let m = message(outcome.status)
        #expect(m.hasPrefix("Re-ran your scan on the output — in your scan's categories: 2 remain (1 you left unredacted); outside them: 2 possible items on 2 pages: 1, 3. Open Scan to review."),
                "got \(m)")
        #expect(outcome.pageReferences == [0, 2])
        #expect(outcome.queryLines?.count == 2)
        #expect(outcome.queryLines?[0].remainingCount == 2)
        #expect(outcome.queryLines?[0].perTerm?.map(\.term) == ["Name", "SSN"])
        #expect(outcome.queryLines?[1].remainingCount == 2, "the sweep line counts the out-of-scope items")
        #expect(outcome.queryLines?[1].perTerm?.map(\.term) == ["Email", "Phone"])
        for line in outcome.queryLines ?? [] {
            #expect(!line.unchecked)
        }
    }

    @Test("PASS beside the sweep: everything explained, nothing outside")
    func passWithSweepNothingOutside() {
        let left = rect(0.5, 0.5)
        let outcome = DetectionSweep.fold(
            requests: [applied([.ssn], deselected: [result(0, .ssn, left)]), sweep],
            observations: [page(0, [0: [item(0, .ssn, left)], 1: [item(0, .ssn, left)]])],
            pageCount: 1)
        #expect(outcome.status == .pass, "got \(outcome.status)")
        #expect(outcome.copyOverride?.short == "Re-ran your scan on the output — 1 remains, the 1 you left unredacted; nothing further outside your scan's categories.")
        #expect(outcome.copyOverride?.detail.hasPrefix(DetectionSweep.detailLeadAppliedAndSweep) == true)
        let clean = DetectionSweep.fold(
            requests: [applied([.ssn]), sweep], observations: [page(0, [0: [], 1: []])], pageCount: 1)
        #expect(clean.copyOverride?.short == "Re-ran your scan on the output — the detectors reported nothing further, inside or outside your scan's categories.")
    }

    @Test("WARN could-not-verify on unchecked pages, with the re-check's clause vocabulary")
    func warnUncheckedPages() {
        var timedOut = page(2, route: .textLayer, [0: []])
        timedOut.regexTimedOut = true
        let outcome = DetectionSweep.fold(
            requests: [sweep],
            observations: [
                page(0, [0: [item(0, .ssn, rect(0.1, 0.1))]]),
                page(1, route: .ocrUnavailable, [0: []]),
                timedOut,
                page(3, route: .ocrSkippedOversize, [0: []]),
                page(4, route: .unopenable, [:]),
            ], pageCount: 5)
        #expect(outcome.status.isWarn, "got \(outcome.status)")
        let m = message(outcome.status)
        #expect(m == "Ran the detectors on the output; 4 pages could not be checked: 2 (OCR did not run), 3 (the pattern took too long), 4 (too large to scan for text), 5", "got \(m)")
        #expect(outcome.pageReferences == [0, 1, 2, 3, 4], "the unchecked pages and the pages with possible items")
        #expect(outcome.copyOverride?.detail.contains("1 possible item remains on page 1.") == true)
        #expect(outcome.copyOverride?.detail.contains("4 pages could not be checked") == true)
        #expect(outcome.reviewTermTexts == nil)
    }

    @Test("No scan request at all → the idle INFO, never skipped")
    func idleInfo() {
        let outcome = DetectionSweep.fold(requests: [], observations: [], pageCount: 3)
        #expect(outcome.status.isInfo)
        #expect(message(outcome.status) == DetectionSweep.infoMessage)
        #expect(outcome.queryLines == nil)
        #expect(outcome.pageReferences == nil)
    }

    // MARK: - Invariants

    @Test("Never ATTENTION and never a term text in a status message, over random observations")
    func neverAttentionAndContentFree() {
        var rng = SplitMix64(seed: 20_260_927)
        let categories = PIICategory.allCases
        for _ in 0..<200 {
            let pageCount = Int(rng.next() % 4) + 1
            let hasApplied = rng.next() % 2 == 0
            let hasSweep = !hasApplied || rng.next() % 2 == 0
            var deselected: [SearchResult] = []
            var observations: [RecheckObservation] = []
            for p in 0..<pageCount {
                let routes: [PageSearchCoverage.Route?] = [.textLayer, .ocr, .ocrUnavailable, .unopenable, nil]
                let route = routes[Int(rng.next() % UInt64(routes.count))]
                var byRequest: [Int: [Item]] = [:]
                var index = 0
                for present in [hasApplied, hasSweep] where present {
                    var items: [Item] = []
                    for _ in 0..<Int(rng.next() % 4) {
                        let category = categories[Int(rng.next() % UInt64(categories.count))]
                        let r = rect(Double(rng.next() % 8) / 10, Double(rng.next() % 8) / 10)
                        items.append(item(p, category, r, text: "SECRET-\(rng.next() % 100)"))
                        if rng.next() % 3 == 0 { deselected.append(result(p, category, r)) }
                    }
                    byRequest[index] = items
                    index += 1
                }
                if route == .unopenable { byRequest = [:] }
                observations.append(page(p, route: route, byRequest))
            }
            var requests: [SearchRecheckRequest] = []
            if hasApplied { requests.append(applied([.ssn, .name, .phone], deselected: deselected)) }
            if hasSweep { requests.append(sweep) }
            let outcome = DetectionSweep.fold(requests: requests, observations: observations, pageCount: pageCount)
            #expect(!outcome.status.isAttention)
            #expect(!outcome.status.isFail)
            #expect(outcome.reviewTermTexts == nil)
            let text = message(outcome.status) + (outcome.copyOverride?.short ?? "") + (outcome.copyOverride?.detail ?? "")
            #expect(!text.contains("SECRET-"), "status copy never carries matched text")
            for category in categories {
                #expect(!text.contains(category.rawValue), "status copy never names a category")
            }
        }
    }

    /// Deterministic PRNG (SplitMix64), the corpus mirror's shape.
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
