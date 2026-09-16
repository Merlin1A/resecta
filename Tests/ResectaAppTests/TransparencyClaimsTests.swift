import Testing
import Foundation

// Transparency-claim lint.
//
// README.md previously claimed Custom Terms and detection state "do not
// persist across app launches" / are "in-session only". That is false:
// `UserTermsStore` and `SavedRegexStore` persist across launches — first in
// `UserDefaults` (keys `userTerms.v1` / `savedRegexes.v1`, now the one-shot
// migration source), and since the move to `FileJSONBlob` as JSON files
// under Application Support with the complete file-protection class and
// the backup-exclusion flag. After that move the docs kept naming
// `UserDefaults` for a while, so the location is now pinned too.
//
// These guards read the front-door docs from the source tree (mirroring the
// `LegalKeyExistenceTests` / `LegalPhraseLintTests` `#filePath` loader posture)
// and assert two things: the false "does-not-persist" claim is absent, and no
// sentence in README.md or ENGINEERING.md places Custom Terms in
// `UserDefaults`. Whitespace is collapsed first because the claims were
// line-wrapped in the source ("do\n  not persist ...").
//
// This is maintainer-gated copy: the replacement wording lands as
// a draft the maintainer approves/edits at merge. These guards
// pin the *accuracy invariants* (no false non-persistence claim, no stale
// storage location), not the exact approved wording.

@Suite("Transparency claims — persistence accuracy")
struct TransparencyClaimsTests {

    /// False-claim literals that asserted V1 does not persist user terms.
    /// Matched against whitespace-collapsed file contents (case-insensitive).
    static let falsePersistenceClaims = [
        "do not persist across app launches",
        "does not persist across app launches",
        "in-session only",
        "in-session state only"
    ]

    /// The docs that describe where Custom Terms live. `nonisolated` for the
    /// same reason as `MarkdownContentGuardTests.legalDocs`: consumed by
    /// `@Test(arguments:)`, which the macro hoists into a nonisolated peer.
    nonisolated static let storageDocs = ["README.md", "ENGINEERING.md"]

    @Test("README.md does not claim Custom Terms are non-persistent")
    func testREADMEDoesNotClaimInSessionOnly() throws {
        try assertNoFalsePersistenceClaim(in: "README.md")
    }

    @Test("No sentence places Custom Terms in UserDefaults", arguments: storageDocs)
    func testNoSentencePlacesCustomTermsInUserDefaults(name: String) throws {
        try assertNoSentencePairsCustomTermsWithUserDefaults(in: name)
    }

    // MARK: - Helpers

    private func assertNoFalsePersistenceClaim(
        in relativePath: String,
        file: StaticString = #filePath
    ) throws {
        let collapsed = try loadCollapsed(relativePath, from: file)
        for claim in Self.falsePersistenceClaims {
            #expect(
                !collapsed.contains(claim),
                "\(relativePath) still contains the false non-persistence claim '\(claim)'. Custom Terms / saved regexes persist across launches as protected files under Application Support.")
        }
    }

    /// A sentence that names both "Custom Terms" and "UserDefaults" describes
    /// the superseded storage location. Sentences are cut at terminal
    /// punctuation followed by a space, so a dotted file name such as
    /// `PRIVACY.md` does not end a sentence early. A sentence that opens with
    /// "they", "these" or "those" is read together with the one before it:
    /// the wording this guard was written against said "Custom Terms don't
    /// persist across launches. They do (in `UserDefaults`, ...)".
    private func assertNoSentencePairsCustomTermsWithUserDefaults(
        in relativePath: String,
        file: StaticString = #filePath
    ) throws {
        let collapsed = try loadCollapsed(relativePath, from: file)
        let cut = collapsed
            .replacingOccurrences(of: "([.!?]) ", with: "$1\n", options: .regularExpression)
            .split(separator: "\n")
            .map(String.init)
        var sentences: [String] = []
        for sentence in cut {
            let continuesPrevious = ["they ", "these ", "those "].contains { sentence.hasPrefix($0) }
            if continuesPrevious, let previous = sentences.popLast() {
                sentences.append(previous + " " + sentence)
            } else {
                sentences.append(sentence)
            }
        }
        let offending = sentences.filter { $0.contains("custom terms") && $0.contains("userdefaults") }
        #expect(
            offending.isEmpty,
            "\(relativePath) still places Custom Terms in UserDefaults; they are stored as protected files under Application Support:\n  \(offending.joined(separator: "\n  "))")
    }

    /// Whitespace-collapsed, lowercased contents of a repo-root file.
    private func loadCollapsed(_ relativePath: String, from file: StaticString) throws -> String {
        try loadRepoFile(relativePath, from: file)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private func loadRepoFile(_ relativePath: String, from file: StaticString) throws -> String {
        let testFile = URL(fileURLWithPath: "\(file)")
        let repoRoot = testFile
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let target = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: target, encoding: .utf8)
    }
}
