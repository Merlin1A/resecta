import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// W-B (e) — CustomTermsTemplateLoader round-trip + dedup coverage.
// Round-trip uses a temp-bundle pattern (FileManager temp dir + Bundle(path:))
// so the test is independent of the app target's bundled
// `Resources/CustomTermsTemplates/license_plate_us_50_state_starter.json`.
// Dedup coverage exercises the (toImport, skipped) partition against an
// existing alwaysFlag list.

@Suite("CustomTermsTemplateLoader (W-B)")
struct CustomTermsTemplateLoaderTests {

    // MARK: - Round-trip

    @Test("Round-trip: temp-bundle JSON decodes to CustomTermsTemplate")
    func roundTripTempBundle() throws {
        let bundleURL = try makeTempBundle(payload: """
        {
          "template_id": "lp_us_50_state_starter_test",
          "template_name": "LP Starter (test)",
          "template_version": 1,
          "description": "Test fixture mirroring the shipped LP starter shape.",
          "entries": [
            {"label": "AK plate", "polarity": "positive", "regex": "^[A-Z0-9 -]{4,8}$", "scope": "any-doctype"},
            {"label": "AL plate", "polarity": "positive", "regex": "^[A-Z0-9 -]{4,8}$", "scope": "any-doctype"}
          ]
        }
        """)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let bundle = try #require(Bundle(url: bundleURL))
        let template = try CustomTermsTemplateLoader.licensePlate50StateStarter(bundle: bundle)

        #expect(template.templateID == "lp_us_50_state_starter_test")
        #expect(template.templateName == "LP Starter (test)")
        #expect(template.templateVersion == 1)
        #expect(template.entries.count == 2)
        #expect(template.entries[0].label == "AK plate")
        #expect(template.entries[0].regex == "^[A-Z0-9 -]{4,8}$")
        #expect(template.entries[0].polarity == "positive")
        #expect(template.entries[0].scope == "any-doctype")
    }

    @Test("Loader throws resourceMissing when JSON absent")
    func resourceMissingThrows() throws {
        let bundleURL = try makeEmptyTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let bundle = try #require(Bundle(url: bundleURL))
        #expect(throws: CustomTermsTemplateLoader.LoaderError.self) {
            _ = try CustomTermsTemplateLoader.licensePlate50StateStarter(bundle: bundle)
        }
    }

    // MARK: - userTerms conversion

    @Test("userTerms maps every entry to a regex-typed UserTerm")
    func userTermsConversion() {
        let template = CustomTermsTemplate(
            templateID: "t",
            templateName: "T",
            templateVersion: 1,
            description: "",
            entries: [
                .init(label: "AK plate", polarity: "positive", regex: "^[A-Z0-9 -]{4,8}$", scope: "any-doctype"),
                .init(label: "CA plate", polarity: "positive", regex: "^[0-9][A-Z]{3}[0-9]{3}$", scope: "any-doctype"),
            ]
        )

        let terms = CustomTermsTemplateLoader.userTerms(from: template)
        #expect(terms.count == 2)
        #expect(terms.allSatisfy { $0.isRegex })
        #expect(terms[0].pattern == "^[A-Z0-9 -]{4,8}$")
        #expect(terms[1].pattern == "^[0-9][A-Z]{3}[0-9]{3}$")
    }

    // MARK: - Dedup

    @Test("Dedup partitions candidates against existing patterns")
    func dedupPartitions() {
        let candidates: [UserTerm] = [
            UserTerm(pattern: "^A$", isRegex: true),
            UserTerm(pattern: "^B$", isRegex: true),
            UserTerm(pattern: "^C$", isRegex: true),
        ]
        let existing: [UserTerm] = [
            UserTerm(pattern: "^B$", isRegex: true),
        ]

        let result = CustomTermsTemplateLoader.deduplicating(candidates, against: existing)

        #expect(result.toImport.map(\.pattern) == ["^A$", "^C$"])
        #expect(result.skipped.map(\.pattern) == ["^B$"])
    }

    @Test("Dedup with no overlap imports everything")
    func dedupNoOverlap() {
        let candidates: [UserTerm] = [
            UserTerm(pattern: "^A$", isRegex: true),
            UserTerm(pattern: "^B$", isRegex: true),
        ]
        let result = CustomTermsTemplateLoader.deduplicating(candidates, against: [])
        #expect(result.toImport.count == 2)
        #expect(result.skipped.isEmpty)
    }

    @Test("Dedup with full overlap skips everything")
    func dedupFullOverlap() {
        let candidates: [UserTerm] = [
            UserTerm(pattern: "^A$", isRegex: true),
            UserTerm(pattern: "^B$", isRegex: true),
        ]
        let result = CustomTermsTemplateLoader.deduplicating(candidates, against: candidates)
        #expect(result.toImport.isEmpty)
        #expect(result.skipped.count == 2)
    }

    // MARK: - Helpers

    /// Build a `.bundle` directory containing only the LP template JSON.
    private func makeTempBundle(payload: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResectaCTTL-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let jsonURL = tmp.appendingPathComponent("license_plate_us_50_state_starter.json")
        try payload.data(using: .utf8)!.write(to: jsonURL)
        return tmp
    }

    private func makeEmptyTempBundle() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResectaCTTL-empty-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }
}
