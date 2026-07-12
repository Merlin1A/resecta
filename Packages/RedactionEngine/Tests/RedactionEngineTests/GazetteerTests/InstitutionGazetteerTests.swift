import Testing
import Foundation
@testable import RedactionEngine

// L4 / C10 — InstitutionGazetteer loader, exact lookup, and doctype anchoring.

@Suite("InstitutionGazetteer (L4 / C10)")
struct InstitutionGazetteerTests {

    // MARK: - Bundle loader

    @Test("Loads institutions.json from the module bundle")
    func testLoadsFromBundle() throws {
        let gazetteer = try InstitutionGazetteer()
        #expect(!gazetteer.entries.isEmpty)
        // GSA federal-agency list ships with well over 1,000 rows.
        #expect(gazetteer.entries.count >= 1_000)
    }

    // MARK: - Exact lookup

    @Test("Exact-match lookup resolves a federal agency by canonical name")
    func testExactMatchFederalAgency() throws {
        let gazetteer = try InstitutionGazetteer()

        let ssa = try #require(
            gazetteer.institution(named: "Social Security Administration"))
        #expect(ssa.category == "federal_agency")
        #expect(ssa.jurisdictions.contains("US"))

        let irs = try #require(
            gazetteer.institution(named: "Internal Revenue Service"))
        #expect(irs.category == "federal_agency")
    }

    @Test("Exact-match lookup is case- and whitespace-insensitive")
    func testExactMatchNormalization() throws {
        let gazetteer = try InstitutionGazetteer()
        #expect(gazetteer.institution(named: "social security administration") != nil)
        #expect(gazetteer.institution(named: "SOCIAL SECURITY ADMINISTRATION") != nil)
        #expect(gazetteer.institution(named: "  Internal Revenue Service  ") != nil)
    }

    @Test("Unknown names return nil")
    func testUnknownInstitutionReturnsNil() throws {
        let gazetteer = try InstitutionGazetteer()
        #expect(gazetteer.institution(named: "Clearly Made-Up Agency Of Nothing") == nil)
    }

    // MARK: - Doctype anchoring (C10 headline test)

    @Test("SOCIAL SECURITY ADMINISTRATION header anchors to .foia doctype")
    func testDoctypeAnchoring() throws {
        let gazetteer = try InstitutionGazetteer()
        let header = """
            SOCIAL SECURITY ADMINISTRATION
            Request for Release of Records
            """
        let hit = try #require(gazetteer.findInstitution(in: header))
        #expect(hit.name == "Social Security Administration")
        #expect(InstitutionGazetteer.anchoredDoctype(for: hit) == .foia)
    }

    @Test("Header scan returns nil when no institution is present")
    func testHeaderScanEmpty() throws {
        let gazetteer = try InstitutionGazetteer()
        let header = "Confidential — Acme Corp internal memo"
        #expect(gazetteer.findInstitution(in: header) == nil)
    }

    @Test("Header scan prefers the longest matching name")
    func testHeaderScanPrefersLongest() throws {
        // In-memory gazetteer with two overlapping entries; the scanner
        // should return the longer "Social Security Administration" entry,
        // not the shorter "SSA" alias, when both could match.
        let entries = [
            InstitutionGazetteer.Entry(
                name: "Social Security Administration",
                aliases: ["SSA"],
                category: "federal_agency",
                jurisdictions: ["US"]),
            InstitutionGazetteer.Entry(
                name: "Alternative SSA Entity",
                aliases: [],
                category: "federal_agency",
                jurisdictions: ["US"]),
        ]
        let gazetteer = InstitutionGazetteer(entries: entries)
        let hit = try #require(gazetteer.findInstitution(
            in: "SOCIAL SECURITY ADMINISTRATION — Form W-2"))
        #expect(hit.name == "Social Security Administration")
    }

    // MARK: - Category-to-doctype map

    @Test("federal_agency category maps to .foia")
    func testFederalAgencyCategoryMap() {
        let entry = InstitutionGazetteer.Entry(
            name: "Example",
            aliases: [],
            category: "federal_agency",
            jurisdictions: ["US"])
        #expect(InstitutionGazetteer.anchoredDoctype(for: entry) == .foia)
    }

    @Test("Unknown categories map to nil")
    func testUnknownCategoryMap() {
        let entry = InstitutionGazetteer.Entry(
            name: "Example",
            aliases: [],
            category: "nonprofit",
            jurisdictions: ["US"])
        #expect(InstitutionGazetteer.anchoredDoctype(for: entry) == nil)
    }

    @Test("Version-fence rejects out-of-range version (W-O)")
    func versionFenceRejectsOutOfRange() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appending(path: "wo-followers-institutions-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let fixtureURL = gazetteersDir.appending(path: "institutions.json")
        let fixtureJSON = #"{"version": 99, "entries": [], "_test_note": "W-O fence-test fixture for institutions"}"#
        try fixtureJSON.write(to: fixtureURL, atomically: true, encoding: .utf8)

        guard let bundle = Bundle(path: tempBase.path()) else {
            Issue.record("Failed to create test bundle from \(tempBase.path())")
            return
        }

        do {
            _ = try InstitutionGazetteer(bundle: bundle)
            Issue.record("Expected LoaderError.unsupportedVersion but no error was thrown")
        } catch InstitutionGazetteer.LoaderError.unsupportedVersion(let actual, let supported) {
            #expect(actual == 99)
            #expect(supported == 1...1)
        } catch {
            Issue.record("Expected LoaderError.unsupportedVersion but got \(error)")
        }
    }
}

// MARK: - NegativeContextGazetteer × InstitutionGazetteer integration

// Package J — TEST-neg-ctx-test-target-wiring (`05-implementer-handoff.md §3
// Package J`). The test target's `Bundle.module` previously did not contain
// `Resources/Gazetteers/`; Package.swift now mirrors the gazetteer resources
// into the test target via a parent-relative `.copy(...)` entry, so the
// `bundle: .module` calls below resolve to a bundle with `negative_context.json`.
@Suite("NegativeContextGazetteer institution anchoring (L4 / C10)")
struct NegativeContextInstitutionAnchorTests {

    @Test("Federal-agency header dampens SSN suppression below the keyword-only baseline")
    func testFederalAgencyHeaderDampensSSN() throws {
        let institutions = try InstitutionGazetteer()
        let scorer = try NegativeContextGazetteer(
            bundle: .module, institutions: institutions)

        let body = "Beneficiary 123-45-6789 appears below."
        let header = "SOCIAL SECURITY ADMINISTRATION"

        let baseline = scorer.suppressionScore(
            category: .ssn, doctype: .foia, context: body)
        let anchored = scorer.suppressionScore(
            category: .ssn, doctype: .foia, context: body,
            documentHeader: header)

        #expect(anchored <= baseline)
        #expect(anchored >= 0.25)
    }

    @Test("Anchored doctype hint returns .foia when SSA appears in the header")
    func testAnchoredDoctypeHintSSA() throws {
        let institutions = try InstitutionGazetteer()
        let scorer = try NegativeContextGazetteer(
            bundle: .module, institutions: institutions)
        #expect(scorer.anchoredDoctype(
            documentHeader: "SOCIAL SECURITY ADMINISTRATION") == .foia)
    }

    @Test("Anchored doctype hint returns nil when no institution is present")
    func testAnchoredDoctypeHintMissing() throws {
        let institutions = try InstitutionGazetteer()
        let scorer = try NegativeContextGazetteer(
            bundle: .module, institutions: institutions)
        #expect(scorer.anchoredDoctype(
            documentHeader: "Acme Corp — Internal Memo") == nil)
    }

    @Test("Anchor has no effect for categories outside {ssn, npi}")
    func testAnchorNoEffectForOtherCategories() throws {
        let institutions = try InstitutionGazetteer()
        let scorer = try NegativeContextGazetteer(
            bundle: .module, institutions: institutions)

        let body = "Account 4111 1111 1111 1111 referenced."
        let header = "SOCIAL SECURITY ADMINISTRATION"

        let baseline = scorer.suppressionScore(
            category: .creditCard, doctype: .foia, context: body)
        let anchored = scorer.suppressionScore(
            category: .creditCard, doctype: .foia, context: body,
            documentHeader: header)

        #expect(anchored == baseline)
    }
}
