import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// A run that did not finish, or a list of results that is short, never
// reads as Passed: an output with no pages ends the run; a scheduled check
// with no result ends it; an empty list of checks is skipped, not passed;
// a cancelled pass throws instead of handing back part of a page; and a
// page the re-checks have no observation or no count for is a page not
// checked. One table; its length is pinned so an empty table fails.

@Suite("A run that did not finish never reads as passed")
struct UnfinishedRunTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let body: @Sendable () async throws -> Void
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "an output with no pages ends the run with an error, never a report", body: { try await noPageOutputThrows() }),
        Case(name: "a scheduled check that stored no result ends the run, and the report is built in two places only",
             body: { try await missingResultThrows() }),
        Case(name: "an empty list of checks reads skipped, not passed", body: { try await emptyListIsSkipped() }),
        Case(name: "a cancelled shared pass throws instead of reading as nothing requested", body: { try await cancelledPassThrows() }),
        Case(name: "a cancelled page throws instead of returning a part observation", body: { try await cancelledPageThrows() }),
        Case(name: "a cancelled coverage re-run throws instead of returning an outcome", body: { try await cancelledCoverageThrows() }),
        Case(name: "the Search Re-check reads a page with no observation as not checked", body: { try await recheckMissingPage() }),
        Case(name: "the Search Re-check reads a page read without a request's count as not checked, and a remaining match still leads",
             body: { try await recheckMissingCount() }),
        Case(name: "the Detection Sweep reads a page with no observation as not checked", body: { try await sweepMissingPage() }),
        Case(name: "the Detection Sweep reads a page read without a request's count as not checked", body: { try await sweepMissingCount() }),
    ]

    @Test("The table holds exactly ten cases")
    func tableLength() {
        #expect(Self.cases.count == 10)
    }

    @Test("Each case", arguments: cases)
    func eachCase(_ c: Case) async throws {
        try await c.body()
    }

    // MARK: - Helpers

    /// A row folded beside rows that all passed must not read Passed.
    static func expectNotPassedBesidePasses(_ row: LayerResult) {
        let report = [LayerResult.mock(status: .pass), LayerResult.mock(status: .pass), row]
        #expect(VerificationEngine().aggregateStatus(report) != .pass, "\(row.status)")
    }

    static func isVerificationError(_ error: any Error, layerIndex expected: Int? = nil) -> Bool {
        guard case PipelineError.verificationError(.engineCrash(let index)) = error else { return false }
        return expected.map { $0 == index } ?? true
    }

    static func output(_ pages: [String]) throws -> SendablePDFDocument {
        SendablePDFDocument(try #require(PDFDocument(data: TestFixtures.textPagesPDF(pages))))
    }

    static func scanRequest() -> SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: AppliedSearchQuery(kind: .piiScan(categories: [.ssn]), options: SearchOptions()),
                foundCount: 1),
            appliedCount: 1, appliedPages: [0])
    }

    static func count(_ remaining: Int = 0, term: String = "Delia") -> RecheckObservation.Count {
        RecheckObservation.Count(
            remaining: remaining, hitCap: false, perTerm: remaining > 0 ? [term: remaining] : [:])
    }

    static func read(_ page: Int, _ counts: [Int: RecheckObservation.Count]) -> RecheckObservation {
        RecheckObservation(pageIndex: page, route: .textLayer, regexTimedOut: false, counts: counts,
                           textLayerRead: true)
    }

    /// One post-sequential check through the engine's internal overload,
    /// with the shared pass handed in as `observations`.
    static func postRow(
        _ layer: VerificationLayer, _ doc: SendablePDFDocument,
        requests: [SearchRecheckRequest], observations: [RecheckObservation]
    ) async -> LayerResult {
        let n = doc.document.pageCount
        return await VerificationEngine().runLayer(
            layer, outputDocument: doc, sourcePageCount: n, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction, filterDigests: Array(repeating: nil, count: n),
            perPageModes: Array(repeating: .searchableRedaction, count: n),
            appliedSearches: requests, manualRegionsWithoutText: 0,
            batch: PostSequentialBatch(observations: observations, seconds: 0),
            sourceDocument: doc)
    }

    /// Run `body` in a task that is already cancelled when it starts.
    static func inCancelledTask<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        let task = Task { () async throws -> T in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await body()
        }
        do { return .success(try await task.value) } catch { return .failure(error) }
    }

    static func expectCancellation<T>(_ result: Result<T, any Error>, _ what: String) {
        switch result {
        case .success(let value): Issue.record("\(what) returned \(value) after cancellation")
        case .failure(let error): #expect(error is CancellationError, "\(what) threw \(error)")
        }
    }

    // MARK: - Cases

    static func noPageOutputThrows() async throws {
        do {
            let report = try await VerificationOrchestrator().run(
                outputDocument: SendablePDFDocument(PDFDocument()), sourcePageCount: 0, regions: [:],
                sensitiveTerms: [], pipelineMode: .secureRasterization, filterDigests: [], perPageModes: [],
                perPageFallbackReasons: [], appliedSearches: [], provisionLayerDocuments: { _ in nil },
                events: { _ in })
            Issue.record("an output with no pages gave a report: \(report.overallStatus)")
        } catch {
            #expect(isVerificationError(error), "threw \(error)")
        }
    }

    static func missingResultThrows() async throws {
        let layers: [VerificationLayer] = [.textExtraction, .ocrCheck, .binaryStringSearch]
        do {
            let report = try VerificationOrchestrator().assembleReport(
                layers: layers,
                resultsByLayer: [.textExtraction: .mock(status: .pass), .binaryStringSearch: .mock(status: .pass)],
                durationSeconds: 0, perPageModes: [.secureRasterization], perPageFallbackReasons: [nil])
            Issue.record("a short list of results gave a report of \(report.layers.count) rows")
        } catch {
            #expect(isVerificationError(error, layerIndex: 1), "threw \(error)")
        }
        // The pin: the orchestrator's file builds a report in exactly two
        // places (the page-count gate and the assembly) and never folds the
        // stored results through compactMap.
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RedactionEngine/Verification/VerificationOrchestrator.swift")
        let code = try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(code.count > 100, "the orchestrator's source was not found")
        #expect(code.filter { $0.contains("VerificationReport(") }.count == 2)
        #expect(!code.contains { $0.contains("compactMap") && $0.contains("resultsByLayer") })
    }

    static func emptyListIsSkipped() async throws {
        let status = VerificationEngine().aggregateStatus([])
        #expect(status == .skipped, "got \(status)")
        #expect(status != .pass)
    }

    static func cancelledPassThrows() async throws {
        let doc = try output(["Delia R. Hartwell"])
        let result = await inCancelledTask {
            try await VerificationOrchestrator.observeOutput(doc, requests: [TestFixtures.textRequest("Delia")])
                .map { $0.observations.count }
        }
        expectCancellation(result, "the shared pass")
    }

    static func cancelledPageThrows() async throws {
        let doc = try output(["Delia R. Hartwell"])
        let data = try #require(doc.document.page(at: 0)?.dataRepresentation)
        let requests = [TestFixtures.textRequest("Delia")]
        let result = await inCancelledTask {
            try await OutputRecheck.observePage(
                OutputRecheck.PageWork(index: 0, data: data, requestIndices: [0]),
                requests: requests, regexTimeoutOverride: nil).pageIndex
        }
        expectCancellation(result, "the page")
    }

    static func cancelledCoverageThrows() async throws {
        let doc = try output(["Delia R. Hartwell"])
        let box = RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.05, width: 0.4, height: 0.06), source: .manual)
        let result = await inCancelledTask {
            try await RegionCoverage.check(
                source: doc, requests: [TestFixtures.textRequest("Delia")], regions: [0: [box]]).comparedMatches
        }
        expectCancellation(result, "the coverage re-run")
    }

    static func recheckMissingPage() async throws {
        let doc = try output(["first page", "second page"])
        let row = await postRow(.searchRecheck, doc, requests: [TestFixtures.textRequest("Delia")],
                                observations: [read(0, [0: count()])])
        #expect(row.status.isWarn, "got \(row.status)")
        #expect(TestFixtures.message(of: row.status) == "Re-ran 1 search; 1 page could not be checked: 2; \(SearchRecheck.coverageNoSearchMatchClause)")
        #expect(row.couldNotVerify)
        #expect(row.pageReferences == [1])
        expectNotPassedBesidePasses(row)
    }

    static func recheckMissingCount() async throws {
        let doc = try output(["first page", "second page"])
        let row = await postRow(.searchRecheck, doc, requests: [TestFixtures.textRequest("Delia")],
                                observations: [read(0, [0: count()]), read(1, [:])])
        #expect(row.status.isWarn, "got \(row.status)")
        #expect(TestFixtures.message(of: row.status) == "Re-ran 1 search; 1 page could not be checked: 2; \(SearchRecheck.coverageNoSearchMatchClause)")
        #expect(row.couldNotVerify)
        #expect(row.pageReferences == [1])
        expectNotPassedBesidePasses(row)

        // A count the page does hold is kept: a match that remains there
        // still leads, as the fold orders it.
        let two = [TestFixtures.textRequest("Delia"), TestFixtures.textRequest("Hartwell")]
        let found = await postRow(.searchRecheck, doc, requests: two,
                                  observations: [read(0, [0: count(), 1: count()]),
                                                 read(1, [1: count(1, term: "Hartwell")])])
        #expect(found.status == .attention(""), "got \(found.status)")
        #expect(TestFixtures.message(of: found.status)?.hasPrefix("Re-ran 2 searches — 1 match remains on page 2") == true,
                "\(found.status)")
        #expect(found.pageReferences == [1])
        expectNotPassedBesidePasses(found)
    }

    static func sweepMissingPage() async throws {
        let doc = try output(["first page", "second page"])
        let row = await postRow(.detectionSweep, doc, requests: [scanRequest()],
                                observations: [read(0, [0: count()])])
        #expect(row.status.isWarn, "got \(row.status)")
        #expect(TestFixtures.message(of: row.status)?.contains("could not be checked: 2") == true, "\(row.status)")
        #expect(row.couldNotVerify)
        #expect(row.pageReferences == [1])
        expectNotPassedBesidePasses(row)
    }

    static func sweepMissingCount() async throws {
        let doc = try output(["first page", "second page"])
        let row = await postRow(.detectionSweep, doc, requests: [scanRequest()],
                                observations: [read(0, [0: count()]), read(1, [:])])
        #expect(row.status.isWarn, "got \(row.status)")
        #expect(TestFixtures.message(of: row.status)?.contains("could not be checked: 2") == true, "\(row.status)")
        #expect(row.couldNotVerify)
        #expect(row.pageReferences == [1])
        expectNotPassedBesidePasses(row)
    }
}
