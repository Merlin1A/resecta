import Foundation
import Testing
@testable import RedactionEngine

// S5 §2.7 — InstitutionGazetteer + NegativeContextGazetteer tests for the
// financial_institution and employer category expansion (design 02 §6).
//
// Tests use InstitutionGazetteer(entries:) — no bundle fixtures — per spec.

// MARK: - anchoredDoctype for new categories

@Suite("InstitutionGazetteer financial anchoring (S5 §2.7)")
struct InstitutionGazetteerFinancialTests {

    // MARK: - Deliverable 7: anchoredDoctype new cases

    @Test("financial_institution category maps to .financial")
    func testFinancialInstitutionAnchorsFinancial() {
        let entry = InstitutionGazetteer.Entry(
            name: "Chase Bank, N.A.",
            aliases: ["chase bank"],
            category: "financial_institution",
            jurisdictions: ["OH"])
        #expect(InstitutionGazetteer.anchoredDoctype(for: entry) == .financial)
    }

    @Test("employer category maps to .financial")
    func testEmployerAnchorsFinancial() {
        let entry = InstitutionGazetteer.Entry(
            name: "Apple Inc.",
            aliases: ["apple"],
            category: "employer",
            jurisdictions: ["US"])
        #expect(InstitutionGazetteer.anchoredDoctype(for: entry) == .financial)
    }

    @Test("federal_agency still maps to .foia (regression guard)")
    func testFederalAgencyStillMapsFoia() {
        let entry = InstitutionGazetteer.Entry(
            name: "Social Security Administration",
            aliases: ["SSA"],
            category: "federal_agency",
            jurisdictions: ["US"])
        #expect(InstitutionGazetteer.anchoredDoctype(for: entry) == .foia)
    }

    @Test("Unknown category returns nil")
    func testUnknownCategoryReturnsNil() {
        let entry = InstitutionGazetteer.Entry(
            name: "Some Nonprofit",
            aliases: [],
            category: "nonprofit",
            jurisdictions: ["US"])
        #expect(InstitutionGazetteer.anchoredDoctype(for: entry) == nil)
    }

    // MARK: - Deliverable 9: guard tests — financial anchor does NOT suppress dateOfBirth

    @Test("Financial anchor does NOT suppress .dateOfBirth (guard not in {ssn, npi, name})")
    func testFinancialAnchorNoEffectOnDOB() throws {
        let entries = [
            InstitutionGazetteer.Entry(
                name: "Chase Bank",
                aliases: ["chase bank"],
                category: "financial_institution",
                jurisdictions: ["OH"])
        ]
        let institutionGazetteer = InstitutionGazetteer(entries: entries)

        // Build a minimal NegativeContextGazetteer with an institution source.
        // The gazetteer needs a bundle; use an empty bundle so the keyword path
        // is inert — we only care about the header-anchor path here.
        // We can't easily create a NegativeContextGazetteer with the entries-init,
        // so we use the bundle init with an empty bundle (which throws resourceMissing).
        // Instead, test directly via the suppressionScore(category:doctype:context:documentHeader:)
        // method — construct with a fixture bundle that has a valid but empty entries list.
        let tempBase = FileManager.default.temporaryDirectory
            .appending(path: "fin-anchor-dob-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let negCtxURL = gazetteersDir.appending(path: "negative-context.json")
        try #"{"version": 1, "entries": []}"#
            .write(to: negCtxURL, atomically: true, encoding: .utf8)
        guard let bundle = Bundle(path: tempBase.path()) else {
            Issue.record("Failed to create test bundle"); return
        }

        let scorer = try NegativeContextGazetteer(bundle: bundle, institutions: institutionGazetteer)

        let context = "Date of birth 01/15/1980 appears below."
        let header = "Chase Bank Statement"

        let baseline = scorer.suppressionScore(
            category: .dateOfBirth, doctype: .financial, context: context)
        let anchored = scorer.suppressionScore(
            category: .dateOfBirth, doctype: .financial, context: context,
            documentHeader: header)

        // Guard: dateOfBirth is NOT in {ssn, npi, name} → factor must equal baseline.
        #expect(
            abs(anchored - baseline) < 0.001,
            "financial anchor must NOT affect .dateOfBirth; baseline=\(baseline) anchored=\(anchored)"
        )
        #expect(anchored == 1.0, "no keywords + no anchor → factor must be exactly 1.0")
    }

    // MARK: - Deliverable 10: header-anchor suppresses name in financial doc

    @Test("Header-anchor suppresses .name in financial doc when institution in header")
    func testHeaderAnchorSuppressesNameInFinancialDoc() throws {
        let entries = [
            InstitutionGazetteer.Entry(
                name: "Chase Bank",
                aliases: ["chase bank"],
                category: "financial_institution",
                jurisdictions: ["OH"])
        ]
        let institutionGazetteer = InstitutionGazetteer(entries: entries)

        let tempBase = FileManager.default.temporaryDirectory
            .appending(path: "fin-anchor-name-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let negCtxURL = gazetteersDir.appending(path: "negative-context.json")
        try #"{"version": 1, "entries": []}"#
            .write(to: negCtxURL, atomically: true, encoding: .utf8)
        guard let bundle = Bundle(path: tempBase.path()) else {
            Issue.record("Failed to create test bundle"); return
        }

        let scorer = try NegativeContextGazetteer(bundle: bundle, institutions: institutionGazetteer)

        let context = "Account holder: John Smith"
        let header = "Chase Bank Statement"  // "chase bank" is in the gazetteer

        let factor = scorer.suppressionScore(
            category: .name, doctype: .financial, context: context,
            documentHeader: header)

        // The header contains "Chase Bank" → institution found → financial anchor →
        // category .name is in {ssn, npi, name} → 0.6 multiplier applies.
        // base (no keywords) = 1.0; 1.0 * 0.6 = 0.6, floored at 0.25 → 0.6.
        #expect(factor < 1.0, "header anchor should suppress .name; factor=\(factor)")
        #expect(factor >= 0.25, "factor must honor A1 floor; factor=\(factor)")
        #expect(abs(factor - 0.6) < 0.001, "expected 0.6 (base 1.0 * 0.6); got \(factor)")
    }

    @Test("Adversarial: institution in body text, empty documentHeader → no suppression")
    func testBodyNotHeaderNoSuppression() throws {
        let entries = [
            InstitutionGazetteer.Entry(
                name: "Credit Suisse",
                aliases: ["credit suisse"],
                category: "financial_institution",
                jurisdictions: ["US"])
        ]
        let institutionGazetteer = InstitutionGazetteer(entries: entries)

        let tempBase = FileManager.default.temporaryDirectory
            .appending(path: "fin-anchor-body-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let negCtxURL = gazetteersDir.appending(path: "negative-context.json")
        try #"{"version": 1, "entries": []}"#
            .write(to: negCtxURL, atomically: true, encoding: .utf8)
        guard let bundle = Bundle(path: tempBase.path()) else {
            Issue.record("Failed to create test bundle"); return
        }

        let scorer = try NegativeContextGazetteer(bundle: bundle, institutions: institutionGazetteer)

        // Institution name appears only in the body context, not in the header.
        let context = "credit suisse account 123-45-6789"
        let emptyHeader = ""  // no institution in header

        let factor = scorer.suppressionScore(
            category: .name, doctype: .financial, context: context,
            documentHeader: emptyHeader)

        // Empty header → findInstitution returns nil → anchor path inactive → factor == 1.0.
        #expect(factor == 1.0, "body-only institution mention with empty header → no suppression; got \(factor)")
    }

    // MARK: - Foia guard: foia anchor + name still suppresses (design §6 intent)

    @Test("Foia anchor + .name category suppresses (widened guard per design 02 §6)")
    func testFoiaAnchorSuppressesName() throws {
        // This test verifies that the widened guard (now includes .name)
        // correctly applies to the .foia anchor class.
        let entries = [
            InstitutionGazetteer.Entry(
                name: "Social Security Administration",
                aliases: ["SSA"],
                category: "federal_agency",
                jurisdictions: ["US"])
        ]
        let institutionGazetteer = InstitutionGazetteer(entries: entries)

        let tempBase = FileManager.default.temporaryDirectory
            .appending(path: "foia-anchor-name-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let negCtxURL = gazetteersDir.appending(path: "negative-context.json")
        try #"{"version": 1, "entries": []}"#
            .write(to: negCtxURL, atomically: true, encoding: .utf8)
        guard let bundle = Bundle(path: tempBase.path()) else {
            Issue.record("Failed to create test bundle"); return
        }

        let scorer = try NegativeContextGazetteer(bundle: bundle, institutions: institutionGazetteer)

        let context = "Beneficiary: Jane Doe"
        let header = "SOCIAL SECURITY ADMINISTRATION"

        let factor = scorer.suppressionScore(
            category: .name, doctype: .foia, context: context,
            documentHeader: header)

        // Design 02 §6: the guard was widened to include .name for BOTH .foia and .financial.
        // SSA in header → federal_agency → foia anchor → category .name is now in guard.
        // base = 1.0; 1.0 * 0.6 = 0.6.
        // FLAG FOR JESSE: this changes behavior from S3 where .name was NOT in the foia guard
        // (S3 guard was ssn || npi only). The existing test in NegativeContextInstitutionAnchorTests
        // "Anchor has no effect for categories outside {ssn, npi}" uses .creditCard which is
        // still outside the guard. The .name widening is intentional per design 02 §6 lines 905-910.
        #expect(factor < 1.0, "foia anchor must suppress .name after S5 widening; factor=\(factor)")
        #expect(abs(factor - 0.6) < 0.001, "expected 0.6; got \(factor)")
    }
}
