import Testing
import Foundation
@testable import ResectaApp

// q17 (UXF-08) — gate-viewable legal documents ship in the app bundle and
// stay byte-identical to the repo-root sources.
//
// EULA.md and PRIVACY.md are repo-root files (published to resecta.app and
// pinned by MarkdownContentGuardTests); q17 additionally bundles them so the
// first-launch gate can present them read-only in-app (LegalDocumentView)
// with no egress. That creates a dual-copy hazard of the SampleDocument.pdf
// kind — except here BOTH copies are reachable from one test (app bundle +
// #filePath repo root), so the identity check is a direct byte compare, not
// a shared-SHA convention. A drift between what a user reads at the gate and
// what resecta.app publishes is a legal-surface bug (C-7 territory); this
// suite is the tripwire.
@Suite("Gate legal-document bundling (q17 / UXF-08)")
struct LegalDocumentBundleTests {

    private var appBundle: Bundle { Bundle(for: AppCoordinator.self) }

    // nonisolated: consumed by `@Test(arguments:)` (hoisted nonisolated peer
    // under the s04 SE-0466 MainActor default — same posture as
    // MarkdownContentGuardTests.legalDocs).
    nonisolated static let documents: [LegalDocument] = [.eula, .privacyPolicy]

    @Test("Legal document ships in the app bundle", arguments: documents)
    func documentIsBundled(document: LegalDocument) {
        #expect(
            appBundle.url(forResource: document.resourceName, withExtension: "md") != nil,
            "\(document.resourceName).md missing from the app bundle — its project.yml sources: entry (buildPhase: resources) is gone; the gate's view-only link would open an empty sheet"
        )
    }

    @Test("Bundled bytes match the repo-root source", arguments: documents)
    func bundledCopyMatchesRepoRoot(document: LegalDocument) throws {
        let bundledURL = try #require(
            appBundle.url(forResource: document.resourceName, withExtension: "md"),
            "\(document.resourceName).md missing from the app bundle"
        )
        let repoRoot = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let repoURL = repoRoot.appendingPathComponent("\(document.resourceName).md")

        let bundled = try Data(contentsOf: bundledURL)
        let source = try Data(contentsOf: repoURL)
        #expect(
            bundled == source,
            "app-bundle \(document.resourceName).md differs from the repo-root file — the gate would show a user text that is not the published \(document.resourceName).md (stale build? rebuild after editing legal docs)"
        )
    }
}
