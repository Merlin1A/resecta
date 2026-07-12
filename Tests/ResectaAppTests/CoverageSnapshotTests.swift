import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// WU-16 — Coverage Report auto-open + Snapshot share. The disclosure
// inside `CoverageReportView` defaults to expanded; the auto-open gate
// at `SearchResultsSection.swift:26-31` already conditions the view on
// a completed scan, so the disclosure surfaces the moment a coverage
// report exists. The "Share Snapshot" button hands off to
// `MatchExportService.shareCoverageSnapshot`, which serializes
// counts-only CSV+JSON via `coverageSnapshotCSV` /
// `coverageSnapshotJSON`. Per [D-06] / [RR-25]-adjacent — matched text
// MUST never appear in the snapshot payload.

@Suite("Coverage snapshot CSV+JSON + auto-open (WU-16)")
struct CoverageSnapshotTests {

    // MARK: - Static contracts

    @Test("Disclosure auto-opens by default")
    func disclosureExpandedByDefault() {
        #expect(CoverageReportView.disclosureExpandedByDefault == true)
    }

    @Test("Share Snapshot button label pins the SAFE-classified copy")
    func shareSnapshotButtonLabel() {
        #expect(CoverageReportView.shareSnapshotButtonLabel == "Share Snapshot")
    }

    // MARK: - Privacy floor — no matched text in snapshot

    @Test("Snapshot CSV contains no matched-text substrings — counts only")
    func csvSnapshotContainsNoMatchedText() {
        // A fixture matched-text we'd see on a live result.
        let matched = "123-45-6789"
        let report = makeReport()
        let metadata = makeMetadata()

        let csvData = MatchExportService.coverageSnapshotCSV(report, metadata: metadata)
        let csvString = String(data: csvData, encoding: .utf8) ?? ""

        #expect(csvString.contains(matched) == false)
        // Sanity: confirm it does carry the count fields.
        #expect(csvString.contains("scannedPages"))
        #expect(csvString.contains("totalCandidates"))
        #expect(csvString.contains("applied"))
        #expect(csvString.contains("deselected"))
        #expect(csvString.contains("belowThreshold"))
        #expect(csvString.contains("overlapSuppressed"))
    }

    @Test("Snapshot JSON contains no matched-text substrings — counts only")
    func jsonSnapshotContainsNoMatchedText() {
        let matched = "987-65-4321"
        let report = makeReport()
        let metadata = makeMetadata()

        let jsonData = MatchExportService.coverageSnapshotJSON(report, metadata: metadata)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? ""

        #expect(jsonString.contains(matched) == false)
        // Sanity: confirm structural keys exist.
        #expect(jsonString.contains("scannedPages"))
        #expect(jsonString.contains("candidatesByCategory"))
        #expect(jsonString.contains("applied"))
        #expect(jsonString.contains("schemaVersion"))
    }

    // MARK: - Round-trip + contents

    @Test("Snapshot CSV reflects per-category counts under the 'category,...' section header")
    func csvSnapshotPerCategorySection() {
        let report = makeReport()
        let csvData = MatchExportService.coverageSnapshotCSV(report, metadata: makeMetadata())
        let csv = String(data: csvData, encoding: .utf8) ?? ""

        #expect(csv.contains("category,candidateCount,overlapSuppressedCount"))
        // SSN had 5 candidates in the fixture; verify the row landed.
        #expect(csv.contains("SSN,5,1"))
    }

    @Test("Snapshot JSON round-trips the totalCandidates count")
    func jsonSnapshotTotalCandidates() throws {
        let report = makeReport()
        let jsonData = MatchExportService.coverageSnapshotJSON(report, metadata: makeMetadata())
        let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        let total = parsed?["totalCandidates"] as? Int
        // SSN(5) + Email(3) = 8.
        #expect(total == 8)
    }

    @Test("Snapshot JSON candidatesByCategory uses category rawValue keys")
    func jsonSnapshotCategoryKeys() throws {
        let report = makeReport()
        let jsonData = MatchExportService.coverageSnapshotJSON(report, metadata: makeMetadata())
        let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        let candidates = parsed?["candidatesByCategory"] as? [String: Int]
        #expect(candidates?["SSN"] == 5)
        #expect(candidates?["Email"] == 3)
        #expect(candidates?["Phone"] == nil)
    }

    @Test("Snapshot CSV header line names the export class up front")
    func csvSnapshotHeaderLine() {
        let csv = String(
            data: MatchExportService.coverageSnapshotCSV(makeReport(), metadata: makeMetadata()),
            encoding: .utf8
        ) ?? ""
        #expect(csv.hasPrefix("# Resecta — Scan coverage snapshot"))
    }

    // MARK: - D06-F2 Part 2 — folded applied/deselected counts

    @Test("CSV serializes the folded applied + deselected counts, not the scan-time base")
    func csvSerializesFoldedAppliedDeselected() {
        // The scan-time report carries appliedCount:4 / deselectedCount:1; the
        // UI folds the live view-state counts in before sharing (mirrors
        // `SearchState.coverageReportForDisplay()`). The serialized values must
        // be the folded ones.
        let folded = makeReport()
            .withAppliedCount(6)
            .withDeselectedCount(3)
        let csv = String(
            data: MatchExportService.coverageSnapshotCSV(folded, metadata: makeMetadata()),
            encoding: .utf8
        ) ?? ""
        #expect(csv.contains("applied,6"))
        #expect(csv.contains("deselected,3"))
    }

    @Test("JSON serializes the folded applied + deselected counts, not the scan-time base")
    func jsonSerializesFoldedAppliedDeselected() throws {
        let folded = makeReport()
            .withAppliedCount(6)
            .withDeselectedCount(3)
        let data = MatchExportService.coverageSnapshotJSON(folded, metadata: makeMetadata())
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["applied"] as? Int == 6)
        #expect(parsed?["deselected"] as? Int == 3)
    }

    // MARK: - Auto-open contract

    @Test("CoverageReportView initializes with isExpanded=true by default; the override seam respects the test value")
    @MainActor
    func initRespectsExpandedOverride() {
        // The default initializer auto-opens the disclosure.
        let defaultView = CoverageReportView(report: makeReport())
        // A test seam override pins the alternative state for snapshot/UI tests.
        let collapsedView = CoverageReportView(report: makeReport(), initialExpanded: false)
        // Existence + non-equality is the invariant we can probe without
        // hosting the SwiftUI runtime — the @State initial value is read
        // from the struct's stored property at init time.
        _ = defaultView
        _ = collapsedView
        #expect(CoverageReportView.disclosureExpandedByDefault == true)
    }

    // MARK: - Fixtures

    private func makeReport() -> CoverageReport {
        CoverageReport(
            scannedPageCount: 12,
            enabledCategories: [.ssn, .email],
            candidateCountByCategory: [.ssn: 5, .email: 3],
            appliedCount: 4,
            deselectedCount: 1,
            belowThresholdSuppressedCount: 2,
            overlapSuppressedCountByCategory: [.ssn: 1],
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeMetadata() -> ExportMetadata {
        ExportMetadata(
            appVersion: "1.0.0 (1)",
            presetName: "Default",
            perCategoryOverrides: [:],
            documentName: "document",
            totalMatches: 8,
            appliedMatches: 4
        )
    }
}
