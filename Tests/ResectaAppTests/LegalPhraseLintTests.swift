import Testing
import Foundation
@testable import ResectaApp

// ARCHITECTURE §1.3 — walks every localized value in `Legal.xcstrings`
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
        #expect(LegalPhrases.bannedTerms.contains("guaranteed"))
        #expect(LegalPhrases.bannedTerms.count >= 10)
    }

    // MARK: - Helpers

    private struct XCStringsCatalog: Decodable {
        let sourceLanguage: String?
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let extractionState: String?
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
    }

    private struct StringUnit: Decodable {
        let state: String?
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
