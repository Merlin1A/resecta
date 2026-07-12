import Testing
import Foundation

// CND-06 (launch-fix-v2 · S2) — legal-doc content-readiness gate.
//
// PRIVACY.md and EULA.md ship to the public resecta.app/privacy and /eula
// pages (CND-03). They currently carry a `DRAFT-FOR-JESSE-APPROVAL` banner and
// an `_TBD …_` effective-date placeholder. This suite is fail-closed over that
// readiness: it lands RED on purpose and turns green only once the maintainer / counsel
// strip the banner and set a real effective date. It is tracked as a gate (not
// a break) in the launch plan.
//
// Net-new coverage: `DRAFT` / `TBD` are NOT in `LegalPhrases.bannedTerms`, and
// the existing legal suites (`LegalKeyExistenceTests` / `LegalPhraseLintTests`)
// read only `Legal.xcstrings` — none of them can see these Markdown files. The
// loader mirrors the `#filePath` repo-root posture of `TransparencyClaimsTests`.

@Suite("Legal-doc content readiness (CND-06)")
struct MarkdownContentGuardTests {

    // nonisolated for the same reason as `LegalKeyExistenceTests.eulaKeys`:
    // consumed by `@Test(arguments:)`, which the Swift Testing macro hoists into
    // a nonisolated peer. Under the s04 SE-0466 MainActor-default flip an
    // unannotated static would be MainActor-isolated and unreadable there.
    nonisolated static let legalDocs = ["PRIVACY.md", "EULA.md"]

    /// Draft-banner marker. Uppercase literal so the assertion targets the
    /// banner (`DRAFT-FOR-JESSE-APPROVAL`, `This is a DRAFT`) and not the
    /// lowercase verb "drafted" inside it.
    nonisolated static let draftMarker = "DRAFT"

    @Test("Legal doc carries no DRAFT banner", arguments: legalDocs)
    func testNoDraftBanner(name: String) throws {
        let contents = try loadRepoFile(name)
        #expect(
            !contents.contains(Self.draftMarker),
            "\(name) still contains a '\(Self.draftMarker)' banner — strip the DRAFT-FOR-JESSE-APPROVAL block before the resecta.app page goes live (CND-06).")
    }

    @Test("Effective-date line is set, not TBD", arguments: legalDocs)
    func testEffectiveDateIsSet(name: String) throws {
        let contents = try loadRepoFile(name)
        let dateLine = try #require(
            effectiveDateLine(in: contents),
            "\(name) has no '**Effective date:**' line")

        // The placeholder token must be gone. Match `TBD` only when it is not
        // part of a longer alphabetic word — but treat markdown punctuation
        // (the `_TBD_` italics wrapper) as a boundary, which `\bTBD\b` would
        // not, since `_` is a regex word character.
        #expect(
            dateLine.range(of: "(?<![A-Za-z])TBD(?![A-Za-z])", options: .regularExpression) == nil,
            "\(name) effective-date line still reads TBD — set the date at the V1.0 tag (CND-06): \(dateLine)")

        // … and a real date must be positively present. An absence-only check
        // would go false-green the moment TBD is deleted with no replacement.
        // Supports long-month ("June 23, 2026"), ISO ("2026-06-23"), and
        // slashed ("06/23/2026") forms.
        let datePattern =
            "(January|February|March|April|May|June|July|August|September|October|November|December)"
            + "\\s+\\d{1,2},?\\s+\\d{4}|\\d{4}-\\d{2}-\\d{2}|\\d{1,2}/\\d{1,2}/\\d{4}"
        #expect(
            dateLine.range(of: datePattern, options: .regularExpression) != nil,
            "\(name) effective-date line has no recognizable date — expected e.g. 'June 23, 2026' or '2026-06-23' (CND-06): \(dateLine)")
    }

    // MARK: - Helpers

    /// First line carrying the `**Effective date:**` marker.
    private func effectiveDateLine(in contents: String) -> String? {
        contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first { $0.contains("Effective date:") }
    }

    /// Reads a repo-root file via `#filePath`, mirroring the
    /// `TransparencyClaimsTests` / D-12 loader posture.
    private func loadRepoFile(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let target = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: target, encoding: .utf8)
    }
}
