import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The per-page runner the Search Re-check and the Detection Sweep share:
// one page loop, one `DocumentSearcher` per page, every request's
// configuration installed before its stream, one observation per page
// covering every request whatever its origin. Every value here is public
// fixture vocabulary (the threshold suites' synthetic SSN).

@Suite("Output re-check runner (the shared per-page loop)")
struct OutputRecheckTests {

    private func output(_ pages: [String]) throws -> SendablePDFDocument {
        let doc = try #require(PDFDocument(data: TestFixtures.textPagesPDF(pages)))
        return SendablePDFDocument(doc)
    }

    private func scanRequest(
        _ categories: Set<PIICategory>, ssnCutoff: Double?, origin: SearchRecheckRequest.Origin = .applied
    ) -> SearchRecheckRequest {
        let vector = ssnCutoff.map { PresetThresholdVector(thresholdsByWireName: ["ssn": $0]) }
        return SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: AppliedSearchQuery(kind: .piiScan(categories: categories), options: SearchOptions()),
                foundCount: 1,
                scanConfiguration: ScanRunConfiguration(thresholdVector: vector)),
            appliedCount: origin == .applied ? 1 : 0, appliedPages: origin == .applied ? [0] : [],
            origin: origin)
    }

    @Test("One observation per page, in page order, with a count for every request")
    func oneObservationPerPageCoveringEveryRequest() async throws {
        let doc = try output(["first page Delia", "second page", "third page Delia"])
        let requests = [
            TestFixtures.textRequest("Delia"),
            scanRequest([.ssn], ssnCutoff: nil),
            scanRequest(Set(PIICategory.allCases), ssnCutoff: nil, origin: .sweep),
        ]
        let observations = try await OutputRecheck().observe(outputDocument: doc, requests: requests)
        #expect(observations.map(\.pageIndex) == [0, 1, 2])
        for observation in observations {
            #expect(Set(observation.counts.keys) == [0, 1, 2],
                    "page \(observation.pageIndex): every request is counted from the one loop")
            #expect(observation.route == .textLayer)
        }
        #expect(observations[0].counts[0]?.remaining == 1)
        #expect(observations[1].counts[0]?.remaining == 0)
        #expect(observations[2].counts[0]?.remaining == 1)
        #expect(observations[0].counts[0]?.items.isEmpty == true,
                "a typed request records counts only")
    }

    @Test("The request's threshold vector is installed before its stream: a stricter cutoff yields fewer items on the same page")
    func perRequestConfigurationIsInstalled() async throws {
        let doc = try output(["Patient record SSN 123-45-6789 on file"])
        let requests = [
            scanRequest([.ssn], ssnCutoff: 0.50),
            scanRequest([.ssn], ssnCutoff: 0.99),
            scanRequest([.ssn], ssnCutoff: nil),
        ]
        let observations = try await OutputRecheck().observe(outputDocument: doc, requests: requests)
        let page = try #require(observations.first)
        let balanced = try #require(page.counts[0])
        let conservative = try #require(page.counts[1])
        let ungated = try #require(page.counts[2])
        #expect(balanced.remaining >= 1, "the SSN survives a 0.50 cutoff")
        #expect(conservative.remaining == 0, "the SSN is gated out at 0.99")
        #expect(ungated.remaining >= balanced.remaining)
        #expect(balanced.remaining < ungated.remaining || balanced.remaining == ungated.remaining)
        // The scan stream's items carry the category and the page rect for the fold.
        let item = try #require(balanced.items.first)
        #expect(item.category == .ssn)
        #expect(item.pageIndex == 0)
        #expect(item.normalizedRect.width > 0 && item.normalizedRect.height > 0)
        #expect(balanced.perTerm[PIICategory.ssn.rawValue] == balanced.remaining,
                "a scan stream's term is the category name")
    }

    @Test("The request's user terms are installed before its stream: an always-flag term is an item of that request only")
    func perRequestUserTermsAreInstalled() async throws {
        let doc = try output(["The ACME contract number is on file"])
        let flagged = SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: AppliedSearchQuery(kind: .piiScan(categories: [.ssn]), options: SearchOptions()),
                foundCount: 1,
                scanConfiguration: ScanRunConfiguration(
                    thresholdVector: nil,
                    alwaysFlag: [UserTerm(pattern: "ACME", isRegex: false)])),
            appliedCount: 1, appliedPages: [0])
        let plain = scanRequest([.ssn], ssnCutoff: nil)
        let observations = try await OutputRecheck().observe(outputDocument: doc, requests: [flagged, plain])
        let page = try #require(observations.first)
        #expect((page.counts[0]?.remaining ?? 0) >= 1, "the always-flag term is read on the output")
        #expect(page.counts[1]?.remaining == 0, "the request without the term reads nothing")
        #expect(page.counts[0]?.items.first?.category == nil, "an always-flag hit has no detector category")
    }

    @Test("The category gate: a scan re-run reads the structured families only; a name on the page is never an item")
    func categoryGateInTheRunner() async throws {
        let doc = try output(["Patient John Smith SSN 123-45-6789 on file"])
        let observations = try await OutputRecheck().observe(
            outputDocument: doc, requests: [scanRequest([.ssn, .name], ssnCutoff: nil), scanRequest([.name], ssnCutoff: nil, origin: .sweep)])
        let page = try #require(observations.first)
        let both = try #require(page.counts[0])
        #expect(both.items.allSatisfy { $0.category != .name }, "names are not swept")
        #expect(both.items.contains { $0.category == .ssn }, "the SSN is")
        #expect(page.counts[1]?.remaining == 0, "a names-only sweep request reads nothing")
    }

    @Test("Observations keyed by the whole request list re-key to a subset in the subset's order")
    func restrictionRekeys() {
        let full = RecheckObservation(
            pageIndex: 3, route: .ocr, regexTimedOut: true,
            counts: [
                0: RecheckObservation.Count(remaining: 1, hitCap: false, perTerm: ["a": 1]),
                1: RecheckObservation.Count(remaining: 2, hitCap: true, perTerm: ["b": 2]),
                2: RecheckObservation.Count(remaining: 3, hitCap: false, perTerm: ["c": 3]),
            ])
        let subset = full.restricted(to: [2, 0])
        #expect(subset.pageIndex == 3)
        #expect(subset.route == .ocr)
        #expect(subset.regexTimedOut)
        #expect(subset.counts[0]?.remaining == 3)
        #expect(subset.counts[1]?.remaining == 1)
        #expect(subset.counts[2] == nil)
    }

    @Test("Every page is observed; a page the sub-document cannot open carries no count, never a clear")
    func everyPageObservedAndUnopenableCarriesNoCount() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.brokenSecondPagePDF(term: "Delia")))
        let observations = try await OutputRecheck().observe(
            outputDocument: SendablePDFDocument(doc),
            requests: [TestFixtures.textRequest("Delia"), scanRequest([.ssn], ssnCutoff: nil, origin: .sweep)])
        #expect(observations.count == 3, "one observation per page the document reports")
        #expect(observations.map(\.pageIndex) == [0, 1, 2])
        for observation in observations {
            if observation.route == .unopenable {
                #expect(observation.counts.isEmpty, "an unopenable page counts nothing for any request")
            } else {
                #expect(Set(observation.counts.keys) == [0, 1], "a readable page counts every request")
            }
        }
        // The two real term pages are read (the page walk survives the broken kid).
        let readWithTerm = observations.filter { ($0.counts[0]?.remaining ?? 0) > 0 }.count
        #expect(readWithTerm == 2)
    }
}
