import Testing
import Foundation
@testable import RedactionEngine

// The three exemption fields a record may carry (the exemption, its
// citation and a free-text note) are user-authored text about the match:
// under the non-sensitive option they are blanked in both serializations,
// the same way the matched text and the term are reduced.

@Suite("MatchAuditExporter: the exemption fields under the non-sensitive option")
struct MatchAuditExporterSensitiveFieldsTests {

    private static let exemption = "(b)(6)"
    private static let citation = "5 U.S.C. 552"
    private static let note = "a note about this match"

    private func record() -> MatchAuditRecord {
        MatchAuditRecord(
            id: UUID(), pageIndex: 0, matchedText: "Acme Corp",
            source: "textLayer", piiCategory: "Name", piiConfidence: 0.9,
            term: "PII Scan", ruleID: "name.nltagger",
            finalScore: 0.9, appliedThreshold: 0.7,
            rationaleSummary: "regex(name.nltagger)",
            isSelected: true, wasApplied: true,
            suppressedByOverlap: false,
            foiaExemption: Self.exemption, foiaCitation: Self.citation,
            foiaNote: Self.note, ruleVersion: "1.0", gazetteerManifestVersion: "1")
    }

    private func metadata() -> ExportMetadata {
        ExportMetadata(
            schemaVersion: 4, exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.0.0 (42)", presetName: "Standard", perCategoryOverrides: [:],
            documentName: "sample.pdf", totalMatches: 1, appliedMatches: 1)
    }

    private func csvDataRow(includeSensitive: Bool) throws -> [String: String] {
        let text = String(decoding: MatchAuditExporter.csv(
            [record()], metadata: metadata(), includeSensitive: includeSensitive), as: UTF8.self)
        let rows = text.split(separator: "\r\n").filter { !$0.hasPrefix("#") }
        let header = try #require(rows.first).split(separator: ",", omittingEmptySubsequences: false)
        let fields = try #require(rows.dropFirst().first).split(separator: ",", omittingEmptySubsequences: false)
        try #require(header.count == fields.count)
        return Dictionary(uniqueKeysWithValues: zip(header.map(String.init), fields.map(String.init)))
    }

    private func jsonRecord(includeSensitive: Bool) throws -> [String: Any] {
        let data = try MatchAuditExporter.json(
            [record()], metadata: metadata(), includeSensitive: includeSensitive)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(object["records"] as? [[String: Any]])
        return try #require(records.first)
    }

    @Test("CSV: the three exemption fields are blank under the non-sensitive option and pass through otherwise")
    func csvBlanksTheExemptionFields() throws {
        let redacted = try csvDataRow(includeSensitive: false)
        for column in ["foiaExemption", "foiaCitation", "foiaNote"] {
            #expect(redacted[column] == "", "\(column) is blank; got \(redacted[column] ?? "<missing>")")
        }
        let raw = try csvDataRow(includeSensitive: true)
        #expect(raw["foiaExemption"] == Self.exemption)
        #expect(raw["foiaCitation"] == Self.citation)
        #expect(raw["foiaNote"] == Self.note)
    }

    @Test("JSON: the three exemption fields are absent under the non-sensitive option and present otherwise")
    func jsonBlanksTheExemptionFields() throws {
        let redacted = try jsonRecord(includeSensitive: false)
        for key in ["foiaExemption", "foiaCitation", "foiaNote"] {
            #expect(redacted[key] == nil, "\(key) is absent; got \(String(describing: redacted[key]))")
        }
        let raw = try jsonRecord(includeSensitive: true)
        #expect(raw["foiaExemption"] as? String == Self.exemption)
        #expect(raw["foiaCitation"] as? String == Self.citation)
        #expect(raw["foiaNote"] as? String == Self.note)
    }
}
