import Testing
import Foundation
@testable import ResectaApp

// WU-47 — verify EULA `Legal.xcstrings` key existence.
//
// Per ACTION-WU-47 / D-32 / OQ-03: EULA copy is treated as final and
// authoritative; this WU is read-only over content. Loads the raw
// `.xcstrings` JSON from the source tree via `#filePath` (mirroring the
// `LegalPhraseLintTests` loader posture) and asserts that the three
// keys consumed by `EULAGateView.swift` (`eula_title`, `eula_body`,
// `eula_agree`) are present in the catalog with a non-empty `en`
// localization value and no obvious placeholder marker.
//
// Failure paths:
// - Missing key, missing `en` localization, missing `stringUnit.value`,
//   empty value, or value containing "todo" / "placeholder" / "fixme"
//   (case-insensitive substring) → fail. Per ACTION-WU-47, a true
//   miss is launch-blocking and re-escalates to D-16.

@Suite("Legal.xcstrings EULA key existence")
struct LegalKeyExistenceTests {

    // nonisolated: consumed by `@Test(arguments: eulaKeys)`, which the Swift Testing
    // macro hoists into a nonisolated peer. Under the s04 SE-0466 MainActor-default
    // flip this static (in an unannotated suite) would be MainActor-isolated and
    // unreadable from that peer. These are localization-key identifiers, not legal
    // text — the annotation is pure isolation, no content change.
    // q17 (UXF-08) extended the original three EULAGateView keys with the
    // gate's document-link labels and LegalDocumentView's chrome strings.
    nonisolated static let eulaKeys = [
        "eula_title", "eula_body", "eula_agree",
        "eula_view_eula", "eula_view_privacy",
        "legal_doc_done", "legal_doc_unavailable",
    ]

    @Test("EULA key present with non-empty en value", arguments: eulaKeys)
    func eulaKeyPresent(key: String) throws {
        let catalog = try loadCatalog()
        let entry = try #require(
            catalog.strings[key],
            "Missing EULA key in Legal.xcstrings: \(key)")
        let localizations = try #require(
            entry.localizations,
            "Entry \(key) has no localizations table")
        let en = try #require(
            localizations["en"],
            "Entry \(key) missing 'en' localization")
        let value = try #require(
            en.stringUnit?.value,
            "Entry \(key) 'en' missing stringUnit.value")
        #expect(!value.isEmpty, "EULA key \(key) has empty value")

        let lower = value.lowercased()
        let placeholderMarkers = ["todo", "placeholder", "fixme"]
        for marker in placeholderMarkers {
            #expect(
                !lower.contains(marker),
                "EULA key \(key) value contains placeholder marker '\(marker)': \(value)")
        }
    }

    // MARK: - Helpers (mirror LegalPhraseLintTests loader; D-12 parity)

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

// CND-03 / CND-05 (launch-fix-v2 · S2) — in-app outbound links.
//
// CND-03: `SettingsView.Links.privacyPolicy` / `.eula` point at the hosted
// resecta.app pages (`/privacy`, `/eula`), moved off the prior
// `github.com/.../blob/master/…` form. CND-05: `.sourceCode` / `.reportIssue`
// point at the canonical public org `Merlin1A/resecta`, not the pre-launch
// `resecta/resecta-app` placeholder. These guards pin both halves at the
// `Links` source of truth. Operator gates — the resecta.app pages going live
// and the repo going public — are tracked separately, not here.
@Suite("In-app outbound links (CND-03 / CND-05)")
struct LegalLinkExistenceTests {

    /// The pre-launch placeholder org left in the Source-Code / Report-an-Issue
    /// URLs before CND-05.
    static let wrongOrgPath = "resecta/resecta-app"
    /// The canonical public org/repo those links now use (CND-05).
    static let correctOrgPath = "Merlin1A/resecta"

    @Test("Privacy Policy + EULA point at the resecta.app hosted pages")
    func testLegalLinksUseHostedPages() {
        let cases: [(url: URL, pathFragment: String)] = [
            (SettingsView.Links.privacyPolicy, "/privacy"),
            (SettingsView.Links.eula, "/eula"),
        ]
        for (url, fragment) in cases {
            let s = url.absoluteString
            #expect(url.host == "resecta.app", "expected a resecta.app host: \(s)")
            #expect(
                s.contains(fragment),
                "expected the hosted-page path '\(fragment)': \(s)")
        }
    }

    @Test("Source-Code + Report-an-Issue use the canonical org, not the placeholder")
    func testSourceLinksUseCorrectOrg() {
        for url in [SettingsView.Links.sourceCode, SettingsView.Links.reportIssue] {
            let s = url.absoluteString
            #expect(url.host == "github.com", "expected a github.com host: \(s)")
            #expect(
                !s.contains(Self.wrongOrgPath),
                "source link still points at the placeholder org '\(Self.wrongOrgPath)': \(s)")
            #expect(
                s.contains(Self.correctOrgPath),
                "source link should point at '\(Self.correctOrgPath)': \(s)")
        }
    }

    @Test("PRIVACY.md and EULA.md exist at the repo root", arguments: ["PRIVACY.md", "EULA.md"])
    func testLegalDocExists(name: String) throws {
        let repoRoot = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let doc = repoRoot.appendingPathComponent(name)
        #expect(
            FileManager.default.fileExists(atPath: doc.path),
            "expected legal doc to exist at repo root: \(name)")
    }
}
