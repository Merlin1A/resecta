import Testing
import Foundation

// CAT-083 (D-11) — transparency-claim lint.
//
// README.md previously claimed Custom Terms and detection state "do not
// persist across app launches" / are "in-session only". That is false:
// `UserTermsStore` and `SavedRegexStore` persist to `UserDefaults` (keys
// `userTerms.v1` / `savedRegexes.v1`) in V1.0 — see
// `docs/release-notes/v1.0.md`, which already describes this correctly.
//
// These guards read the front-door docs from the source tree (mirroring the
// `LegalKeyExistenceTests` / `LegalPhraseLintTests` `#filePath` loader posture)
// and assert the false "does-not-persist" claim is absent, so a future doc
// pass cannot silently re-introduce it. Whitespace is collapsed first because
// the claim was line-wrapped in the source ("do\n  not persist ...").
//
// D-11 is maintainer-gated copy: the replacement wording lands as
// a draft the maintainer approves/edits at merge. These guards
// pin the *accuracy invariant* (no false non-persistence claim), not the exact
// approved wording.

@Suite("Transparency claims — persistence accuracy (CAT-083)")
struct TransparencyClaimsTests {

    /// False-claim literals that asserted V1 does not persist user terms.
    /// Matched against whitespace-collapsed file contents (case-insensitive).
    static let falsePersistenceClaims = [
        "do not persist across app launches",
        "does not persist across app launches",
        "in-session only",
        "in-session state only"
    ]

    @Test("README.md does not claim Custom Terms are non-persistent")
    func testREADMEDoesNotClaimInSessionOnly() throws {
        try assertNoFalsePersistenceClaim(in: "README.md")
    }

    // MARK: - Helper

    private func assertNoFalsePersistenceClaim(
        in relativePath: String,
        file: StaticString = #filePath
    ) throws {
        let contents = try loadRepoFile(relativePath, from: file)
        let collapsed = contents
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
        for claim in Self.falsePersistenceClaims {
            #expect(
                !collapsed.contains(claim),
                "\(relativePath) still contains the false non-persistence claim '\(claim)'. V1.0 persists Custom Terms / saved regexes via UserDefaults (CAT-083 / D-11).")
        }
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
