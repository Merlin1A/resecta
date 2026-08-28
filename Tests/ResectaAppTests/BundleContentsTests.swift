import Testing
import Foundation
import CryptoKit
@testable import ResectaApp

// Bundle-contents guard. The ResectaApp target's
// XcodeGen `resources:` block silently enumerates nothing; every shipped
// resource must be routed through an explicit `sources:` entry in
// project.yml (the SampleDocument.pdf precedent). Nothing asserted that
// contract until the privacy manifest and custom-terms
// template shipped builds with both files missing. These tests resolve the
// APP bundle via Bundle(for:) on an app class, so a Bundle.main that
// points at the xctest runner cannot produce a false green.

@Suite("Bundle contents guard")
struct BundleContentsTests {

    private var appBundle: Bundle { Bundle(for: AppCoordinator.self) }

    @Test("App bundle resolves to com.resecta.app, not the test runner")
    func appBundleResolves() {
        #expect(appBundle.bundleIdentifier == "com.resecta.app")
    }

    @Test("PrivacyInfo.xcprivacy ships in the app bundle")
    func privacyManifestIsBundled() {
        #expect(
            appBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil,
            "PrivacyInfo.xcprivacy missing from the app bundle — its project.yml sources: entry is gone (ITMS-91053 at submission)"
        )
    }

    @Test("Custom-terms license-plate template ships and round-trips")
    func customTermsTemplateLicensePlateIsBundled() throws {
        #expect(
            appBundle.url(
                forResource: "license_plate_us_50_state_starter",
                withExtension: "json"
            ) != nil,
            "license_plate_us_50_state_starter.json missing from the app bundle — its project.yml sources: entry is gone"
        )
        // Full round-trip against the real bundled JSON: throws
        // .resourceMissing when the sources: routing is absent.
        let template = try CustomTermsTemplateLoader.licensePlate50StateStarter(
            bundle: appBundle
        )
        #expect(!template.entries.isEmpty)
    }

    @Test("SampleDocument.pdf ships in the app bundle (regression)")
    func sampleDocumentIsBundled() {
        #expect(
            appBundle.url(forResource: "SampleDocument", withExtension: "pdf") != nil,
            "SampleDocument.pdf missing from the app bundle — its project.yml sources: entry is gone"
        )
    }

    // App half of the sample-statement dual-copy
    // identity guard. The shipped statement ships in TWO repo locations that
    // must stay byte-identical (three names, ONE SHA): the app-bundle copy
    // (SampleDocument.pdf, here) and the engine test fixture
    // (sample-bank-statement.pdf, pinned by the engine
    // SampleStatementSnapshotTests against TestFixtures.sampleStatementSHA256).
    // Cross-bundle byte compare in a single test is not feasible (different
    // bundles), so each side SHA-pins to the SAME shared constant and
    // Scripts/audit-lint.sh (M-9) cmp's the two repo files at commit time.
    @Test("SampleDocument.pdf bytes match the frozen statement SHA (dual-copy guard)")
    func sampleDocumentMatchesFrozenSHA() throws {
        let url = try #require(
            appBundle.url(forResource: "SampleDocument", withExtension: "pdf"),
            "SampleDocument.pdf missing from the app bundle"
        )
        let data = try Data(contentsOf: url)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // MUST equal TestFixtures.sampleStatementSHA256 in the RedactionEngine
        // test target (different bundle — cannot be imported here). The
        // commit-time cmp in Scripts/audit-lint.sh is the byte-identity backstop.
        #expect(
            hex == "992ca0543eb1a2eaab8d8dba0a4ad4b8339cf95b804a0347ab1b0987ce18fa20",
            "app-bundle SampleDocument.pdf SHA drift — no longer matches the frozen shipped statement"
        )
    }

    // App half of the loan-packet dual-copy
    // identity guard. The Hartwell loan packet ships as the second in-app
    // sample (bundled asset only, no UI picker yet). It lives in TWO
    // repo locations that must stay byte-identical (one SHA): the app-bundle
    // copy (packet.pdf, here) and the engine test fixture
    // (Packages/RedactionEngine/Tests/.../TestResources/packet.pdf, pinned by
    // TestFixtures.loanPacketSHA256). Same rationale as the statement
    // guard: cross-bundle byte compare in one test is not feasible, so each
    // side SHA-pins to the SAME shared constant and Scripts/audit-lint.sh
    // (M-10) cmp's the two repo files at commit time.
    @Test("packet.pdf ships in the app bundle (second sample)")
    func loanPacketIsBundled() {
        #expect(
            appBundle.url(forResource: "packet", withExtension: "pdf") != nil,
            "packet.pdf missing from the app bundle — its project.yml sources: entry is gone"
        )
    }

    @Test("packet.pdf bytes match the loan-packet SHA (dual-copy guard)")
    func loanPacketMatchesFixtureSHA() throws {
        let url = try #require(
            appBundle.url(forResource: "packet", withExtension: "pdf"),
            "packet.pdf missing from the app bundle"
        )
        let data = try Data(contentsOf: url)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // MUST equal TestFixtures.loanPacketSHA256 in the RedactionEngine test
        // target (different bundle — cannot be imported here). The commit-time
        // cmp in Scripts/audit-lint.sh (M-10) is the byte-identity backstop.
        #expect(
            hex == "362375692b8cff378d66c43fcf46f00ba09e1ea982602fcc5c8b70e96f54339a",
            "app-bundle packet.pdf SHA drift — no longer matches the committed engine packet fixture"
        )
    }

    // Export-compliance key ships in the bundle.
    // The app declares ITSAppUsesNonExemptEncryption = NO (its only cryptography
    // is Ed25519 verification of its own bundled gazetteer manifest), so the App
    // Store Connect export-compliance question is answered non-interactively.
    // This is a plist KEY, not a bundled resource, so it is read from
    // infoDictionary rather than url(forResource:). The synthesized Info.plist
    // stores it as a Boolean <false/>; the string form is accepted too for
    // representation-robustness across plist toolchains.
    @Test("Export-compliance key ITSAppUsesNonExemptEncryption=NO ships in the app bundle")
    func exportComplianceKeyIsDeclaredNo() {
        let value = appBundle.infoDictionary?["ITSAppUsesNonExemptEncryption"]
        let declaredNo = (value as? Bool) == false || (value as? String)?.uppercased() == "NO"
        #expect(
            declaredNo,
            "ITSAppUsesNonExemptEncryption is not NO in the app Info.plist — its project.yml INFOPLIST_KEY entry is gone; App Store Connect will prompt for export compliance at submission"
        )
    }
}
