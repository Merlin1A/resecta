import Testing
import Foundation
@testable import ResectaApp

// Walks every localized value in `Legal.xcstrings`
// and fails on any case-insensitive match against `LegalPhrases.bannedTerms`.
// Loads the raw `.xcstrings` JSON from the source tree via `#filePath` so the
// lint sees the authoring artifact, not the compiled `.lproj` strings (which
// strip formatting we want to inspect).

@Suite("Legal.xcstrings phrase lint")
struct LegalPhraseLintTests {

    @Test("Every localized value is free of banned outcome-promise vocabulary")
    func noBannedTermsInAnyLocale() throws {
        let catalog = try loadCatalog()
        var hits: [String] = []
        for (key, entry) in catalog.strings {
            guard let localizations = entry.localizations else { continue }
            for (locale, unit) in localizations {
                let value = unit.stringUnit?.value ?? ""
                let lower = value.lowercased()
                for banned in LegalPhrases.bannedTerms {
                    if lower.contains(banned.lowercased()) {
                        hits.append("[\(locale)] \(key): \"\(banned)\" in \"\(value)\"")
                    }
                }
            }
        }
        #expect(hits.isEmpty, "banned phrases found:\n  \(hits.joined(separator: "\n  "))")
    }

    @Test("Banned-term list is non-empty")
    func bannedTermsGuard() {
        // Guard against accidental emptying of LegalPhrases during refactors.
        #expect(LegalPhrases.bannedTerms.contains("guarantee")) // LegalPhrases:safe — the list under test
        #expect(LegalPhrases.bannedTerms.count >= 10)
    }

    @Test("A banned stem matches each of its inflections")
    func bannedStemsCatchTheirInflections() {
        // A banned word listed in one inflection misses the others: the list
        // holds the stem, so every form below is caught by a substring match.
        for word in ["guarantee", "guarantees", "guaranteed", "guaranteeing"] { // LegalPhrases:safe — the words under test
            #expect(
                LegalPhrases.bannedTerms.contains { word.contains($0.lowercased()) },
                "\"\(word)\" is not caught by any banned term")
        }
    }

    /// The stems for a claim that a box hides how long
    /// its text is, the switch's old name among them, are on the one list
    /// the claims lint reads. This test reads the list; it never edits it.
    static let lengthClaimStems = [
        "hide text length",
        "length hidden", "hidden length", "length is hidden",
        "hides the length", "hide the length", "hides its length", "hiding the length",
        "hides how long", "hide how long",
        "conceals the length", "conceal the length", "masks the length",
        "cannot show how long", "can't show how long", "no longer shows how long", "can no longer show",
        "width says nothing", "says nothing about the text", "no longer follows the text",
    ]

    @Test("The banned-term list holds every stem for a length claim, the switch's old name among them")
    func lengthClaimStemsAreBanned() {
        #expect(Self.lengthClaimStems.count == 20)
        let banned = Set(LegalPhrases.bannedTerms.map { $0.lowercased() })
        for stem in Self.lengthClaimStems {
            #expect(banned.contains(stem), "missing from LegalPhrases.bannedTerms: \(stem)")
        }
    }

    @Test("The first-launch agreement body describes PDF documents and images")
    func gateBodyDescribesPDFDocumentsAndImages() throws {
        // The app opens PDF files and JPEG, PNG and HEIC images; the
        // sentence the first-launch screen shows names both inputs.
        let catalog = try loadCatalog()
        let body = try #require(
            catalog.strings["eula_body"]?.localizations?["en"]?.stringUnit?.value
        )
        #expect(body.contains("in PDF documents and images."))
    }

    // MARK: - Helpers

    private struct XCStringsCatalog: Decodable {
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
    }

    private struct StringUnit: Decodable {
        let value: String?
    }

    private func loadCatalog(file: StaticString = #filePath) throws -> XCStringsCatalog {
        // Walk up from the test source file to find the repo root, then locate
        // the xcstrings artifact in the source tree.
        let testFile = URL(fileURLWithPath: "\(file)")
        let repoRoot = testFile
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let xcstrings = repoRoot
            .appendingPathComponent("Sources/ResectaApp/Legal/Legal.xcstrings")
        let data = try Data(contentsOf: xcstrings)
        return try JSONDecoder().decode(XCStringsCatalog.self, from: data)
    }
}
