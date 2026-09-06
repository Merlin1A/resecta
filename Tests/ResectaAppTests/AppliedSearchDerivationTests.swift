import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// The run-entry derivation of the Search Re-check requests:
// `PipelineCoordinator.appliedSearches(fromRegions:audit:)` joins the
// PRESENT regions to the match audit and groups the search-origin
// records by their stamped query. Pure and `nonisolated static`, so
// these pins run without a coordinator, a document, or a search.

@Suite("Applied-search derivation (present-region join)", .tags(.search))
@MainActor
struct AppliedSearchDerivationTests {

    // MARK: - Fixtures

    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func query(
        _ kind: AppliedSearchQuery.Kind,
        caseSensitive: Bool = false
    ) -> AppliedSearchQuery {
        var options = SearchOptions()
        options.caseSensitive = caseSensitive
        return AppliedSearchQuery(kind: kind, options: options)
    }

    private func record(
        _ query: AppliedSearchQuery,
        foundCount: Int,
        foundHitCap: Bool = false,
        ocrSkippedPages: Set<Int> = []
    ) -> AppliedSearchRecord {
        AppliedSearchRecord(
            query: query, foundCount: foundCount, foundHitCap: foundHitCap,
            ocrSkippedPages: ocrSkippedPages)
    }

    /// One present region on `page` with a search-origin audit entry
    /// carrying `record` (nil = a `.piiScan` / nudge stamp).
    private func searchRegion(
        page: Int,
        record: AppliedSearchRecord?,
        term: String = "secret",
        appliedAt: Date = baseDate,
        into regions: inout [Int: [RedactionRegion]],
        audit: inout [UUID: MatchAuditSnapshot]
    ) {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.04),
            source: .searchMatch(term: term, rationale: nil))
        regions[page, default: []].append(region)
        audit[region.id] = MatchAuditSnapshot(
            origin: .search, resultID: UUID(), regionID: region.id,
            pageIndex: page, matchedText: term, source: .textLayer,
            piiCategory: nil, piiConfidence: nil, rationale: nil,
            term: term, appliedAt: appliedAt, searchRecord: record)
    }

    private func derive(
        _ regions: [Int: [RedactionRegion]],
        _ audit: [UUID: MatchAuditSnapshot]
    ) -> [SearchRecheckRequest] {
        PipelineCoordinator.appliedSearches(fromRegions: regions, audit: audit)
    }

    // MARK: - Pins

    @Test("Present-region join: only present regions count; appliedCount and appliedPages are exact")
    func presentRegionJoin() {
        var regions: [Int: [RedactionRegion]] = [:]
        var audit: [UUID: MatchAuditSnapshot] = [:]
        let q = query(.text("secret"))
        let rec = record(q, foundCount: 5)
        searchRegion(page: 0, record: rec, into: &regions, audit: &audit)
        searchRegion(page: 0, record: rec, into: &regions, audit: &audit)
        searchRegion(page: 2, record: rec, into: &regions, audit: &audit)
        // A manual region has no audit entry — it never joins.
        regions[1, default: []].append(RedactionRegion.mock())

        let requests = derive(regions, audit)
        #expect(requests.count == 1)
        let request = requests[0]
        #expect(request.record == rec)
        #expect(request.appliedCount == 3)
        #expect(request.appliedPages == [0, 2])
        #expect(request.pageBound == false, "the page bound stays opt-in")
        // Overlap-skipped results never wrote an audit entry: the record's
        // found count (5) exceeds the applied count (3) by construction.
        #expect(request.record.foundCount == 5)
    }

    @Test("A deleted region drops out: an orphaned audit entry means the user removed it")
    func deletedRegionDropsTheRequest() {
        var regions: [Int: [RedactionRegion]] = [:]
        var audit: [UUID: MatchAuditSnapshot] = [:]
        let rec = record(query(.text("secret")), foundCount: 1)
        searchRegion(page: 0, record: rec, into: &regions, audit: &audit)
        // `removeRegion` drops the region but leaves the audit entry.
        regions[0] = []
        #expect(audit.count == 1, "precondition: the audit entry lingers")

        #expect(derive(regions, audit).isEmpty)
    }

    @Test("Two applies of one query merge: appliedCount sums, the later record's foundCount wins")
    func twoAppliesMerge() {
        var regions: [Int: [RedactionRegion]] = [:]
        var audit: [UUID: MatchAuditSnapshot] = [:]
        let q = query(.text("secret"))
        let earlier = record(q, foundCount: 2)
        let later = record(q, foundCount: 7, ocrSkippedPages: [3])
        // Insert the LATER apply first on the lower page so the merge has
        // to pick by `appliedAt`, not by encounter order.
        searchRegion(page: 0, record: later, appliedAt: Self.baseDate.addingTimeInterval(60),
                     into: &regions, audit: &audit)
        searchRegion(page: 1, record: earlier, appliedAt: Self.baseDate,
                     into: &regions, audit: &audit)
        searchRegion(page: 1, record: earlier, appliedAt: Self.baseDate,
                     into: &regions, audit: &audit)

        let requests = derive(regions, audit)
        #expect(requests.count == 1)
        #expect(requests[0].appliedCount == 3)
        #expect(requests[0].appliedPages == [0, 1])
        #expect(requests[0].record == later,
                "the latest apply's found count and coverage facts describe the query")
        #expect(requests[0].pageBoundIsSound == false,
                "the later run skipped a page for OCR, so the bound is unsound")
    }

    @Test("A multi-term query is one request carrying the whole term set")
    func multiTermGroupsAsOne() {
        var regions: [Int: [RedactionRegion]] = [:]
        var audit: [UUID: MatchAuditSnapshot] = [:]
        let q = query(.multiTerm(["alpha", "beta", "gamma"]))
        let rec = record(q, foundCount: 4)
        // Each applied result carries its own row's term; the query is the set.
        searchRegion(page: 0, record: rec, term: "alpha", into: &regions, audit: &audit)
        searchRegion(page: 0, record: rec, term: "beta", into: &regions, audit: &audit)
        searchRegion(page: 1, record: rec, term: "beta", into: &regions, audit: &audit)

        let requests = derive(regions, audit)
        #expect(requests.count == 1)
        #expect(requests[0].record.query.kind == .multiTerm(["alpha", "beta", "gamma"]))
        // The engine re-runs the WHOLE query (page-level conjunction is only
        // meaningful over the set), with the options as the user ran them.
        if case .multiTerm(let terms, let options) = requests[0].record.query.searchMode {
            #expect(terms == ["alpha", "beta", "gamma"])
            #expect(options == q.options)
        } else {
            Issue.record("expected a multi-term search mode")
        }
        #expect(requests[0].appliedCount == 3)
        #expect(requests[0].appliedPages == [0, 1])
    }

    @Test("Exclusions: scan-origin records, nil-record search snapshots, and manual regions never join")
    func exclusions() {
        var regions: [Int: [RedactionRegion]] = [:]
        var audit: [UUID: MatchAuditSnapshot] = [:]
        // `.piiScan` session / nudge: search origin, no record.
        searchRegion(page: 0, record: nil, term: "PII Scan", into: &regions, audit: &audit)
        // Scan origin: the builder stamps nil by construction.
        let detection = DetectionResult.mock(kind: .pii(.ssn), matchedText: "123-45-6789")
        let scanRegion = RedactionRegion(
            id: UUID(), normalizedRect: detection.normalizedRect,
            source: .detectedPII(kind: .ssn, rationale: nil))
        regions[0, default: []].append(scanRegion)
        let scanSnapshot = MatchAuditSnapshot(
            detection: detection, pageIndex: 0, regionID: scanRegion.id, appliedAt: Self.baseDate)
        #expect(scanSnapshot.searchRecord == nil, "the scan builder never carries a record")
        audit[scanRegion.id] = scanSnapshot
        // Manual: no audit entry at all.
        regions[1, default: []].append(RedactionRegion.mock())

        #expect(derive(regions, audit).isEmpty)
    }

    @Test("Distinct options are distinct queries; requests come back in first-seen page order")
    func identityAndOrder() {
        var regions: [Int: [RedactionRegion]] = [:]
        var audit: [UUID: MatchAuditSnapshot] = [:]
        let plain = record(query(.text("Delia")), foundCount: 3)
        let caseSensitive = record(query(.text("Delia"), caseSensitive: true), foundCount: 1)
        let pattern = record(query(.regex("\\d{3}-\\d{2}-\\d{4}")), foundCount: 2)
        searchRegion(page: 2, record: plain, into: &regions, audit: &audit)
        searchRegion(page: 0, record: pattern, into: &regions, audit: &audit)
        searchRegion(page: 1, record: caseSensitive, into: &regions, audit: &audit)
        searchRegion(page: 1, record: plain, into: &regions, audit: &audit)

        let requests = derive(regions, audit)
        #expect(requests.count == 3, "same text with different options is a different search")
        #expect(requests.map(\.record) == [pattern, caseSensitive, plain])
        #expect(requests.map(\.appliedPages) == [[0], [1], [1, 2]])
        #expect(requests.map(\.appliedCount) == [1, 1, 2])
        // Two derivations over the same state are equal (the verify-only
        // `?? collectAppliedSearches()` fallback relies on it).
        #expect(derive(regions, audit) == requests)
    }

    @Test("Empty inputs derive no requests")
    func emptyInputs() {
        #expect(derive([:], [:]).isEmpty)
        var regions: [Int: [RedactionRegion]] = [:]
        regions[0] = [RedactionRegion.mock()]
        #expect(derive(regions, [:]).isEmpty)
    }
}

// MARK: - Export surfaces stay dark to the record

@Suite("Applied-search record stays out of the match export", .tags(.search))
@MainActor
struct AppliedSearchRecordExportTests {

    @Test("MatchExportService rows are identical with and without a stamped record")
    func exportIgnoresSearchRecord() {
        let regionID = UUID()
        let resultID = UUID()
        let appliedAt = Date(timeIntervalSince1970: 1_700_000_000)
        func snapshot(_ record: AppliedSearchRecord?) -> MatchAuditSnapshot {
            MatchAuditSnapshot(
                origin: .search, resultID: resultID, regionID: regionID, pageIndex: 0,
                matchedText: "secret", source: .textLayer, piiCategory: nil,
                piiConfidence: nil, rationale: nil, term: "secret",
                appliedAt: appliedAt, searchRecord: record)
        }
        let record = AppliedSearchRecord(
            query: AppliedSearchQuery(kind: .text("secret"), options: SearchOptions()),
            foundCount: 4, foundHitCap: true, ocrSkippedPages: [2])
        let stamped = snapshot(record)
        let bare = snapshot(nil)
        #expect(stamped != bare, "precondition: the two snapshots differ only by the record")

        let withRecord = MatchExportService.makeRecords(liveResults: [], applied: [stamped])
        let without = MatchExportService.makeRecords(liveResults: [], applied: [bare])
        #expect(withRecord == without)
        #expect(withRecord.count == 1)
        // Nothing in the emitted row carries the query text beyond the
        // pre-existing `term` column the v4 artifact always had.
        let encoded = try? JSONEncoder().encode(withRecord)
        let json = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!json.contains("foundCount") && !json.contains("searchRecord") && !json.contains("ocrSkippedPages"))
    }
}
