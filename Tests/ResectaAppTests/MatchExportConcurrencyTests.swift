import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// CAT-242: the test below drives the PRODUCTION
// `MatchExportService.writeTriageExport` (CSV/JSON serialization + two atomic
// file writes inside a Task.detached(.utility)) on a 5,000-record audit, rather
// than re-wrapping the serializers in a test-owned detached task. It confirms
// the off-main write path produces real files on disk — without invoking
// UIKit's UIActivityViewController.

@Suite("MatchExportService concurrency", .tags(.search))
struct MatchExportConcurrencyTests {

    @Test("writeTriageExport writes real CSV/JSON files off-main; CSV carries a line per record")
    @MainActor
    func largeExportSerializesOffMain() async throws {  // throws — Pkg C made json() throws
        let records = (0..<5000).map { i in
            MatchAuditRecord(
                id: UUID(),
                pageIndex: i % 100,
                matchedText: "match-\(i)",
                source: "text",
                piiCategory: "SSN",
                piiConfidence: 0.9,
                term: "match-\(i)",
                ruleID: "ssn.regex",
                finalScore: 0.9,
                appliedThreshold: 0.5,
                rationaleSummary: "",
                isSelected: false,
                wasApplied: i.isMultiple(of: 2)
            )
        }
        let metadata = ExportMetadata(
            schemaVersion: 4,
            appVersion: "test",
            presetName: "Balanced",
            perCategoryOverrides: [:],
            documentName: "document",
            totalMatches: records.count,
            appliedMatches: records.filter { $0.wasApplied }.count
        )

        // Real writable temp directory; a fresh ToastQueueManager is required by
        // the signature (only touched on the failure path, which this success
        // case never reaches).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("matchexport-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await MatchExportService.writeTriageExport(
            records: records, metadata: metadata, includeSensitive: false,
            documentName: "document", into: dir, toastManager: ToastQueueManager()
        )
        // CAT-242: exercise the production Task.detached + atomic-write path. If
        // the off-main dispatch or the file write regresses, the result is nil
        // or the files are absent/short.
        let urls = try #require(result, "writeTriageExport must produce output files")
        #expect(FileManager.default.fileExists(atPath: urls.csv.path), "CSV export file must exist on disk")
        #expect(FileManager.default.fileExists(atPath: urls.json.path), "JSON export file must exist on disk")

        // CAT-253: line-count + 100k-byte floors. The old `> 5000` byte floor was
        // trivial (a degenerate one-char-per-record serializer would clear it).
        // A line per record (header + 5000 rows) flags an empty/collapsed CSV;
        // 100k bytes flags a row-collapse that still emits newlines.
        let csvData = try Data(contentsOf: urls.csv)
        // Split on isNewline, not the "\n" Character: the exporter uses CRLF and
        // "\r\n" is a single Swift grapheme that does not equal "\n".
        let lineCount = String(decoding: csvData, as: UTF8.self)
            .split(whereSeparator: \.isNewline).count
        #expect(lineCount > 5000, "CSV must carry a line per record (got \(lineCount) lines)")
        #expect(csvData.count > 100_000, "5000-record CSV must exceed 100k bytes (got \(csvData.count))")
    }
}
