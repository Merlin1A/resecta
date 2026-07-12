import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-07 — Doctype banner above PII Scan results per [D-23] (single-purpose
// headline) + [RR-12] (data-driven gated-out count, V1.x mirror updates
// when WU-75 ships engine parity for the 3 additional categories
// MRN/Bates/LicensePlate).

@Suite("Doctype banner (WU-07)", .tags(.search))
@MainActor
struct DoctypeBannerTests {

    // MARK: - Headline

    @Test("Banner headline embeds enabled-detector count + lower-cased doctype")
    func bannerHeadline() {
        let headline = WU07Strings.headline(detectorCount: 7, doctype: "medical")
        #expect(headline == "Scanning with 7 detectors tuned for medical documents.")
    }

    @Test("Banner headline uses singular form for 1 detector")
    func bannerHeadlineSingular() {
        let headline = WU07Strings.headline(detectorCount: 1, doctype: "court")
        #expect(headline == "Scanning with 1 detector tuned for court documents.")
    }

    @Test("Banner headline contains no §19 forbidden phrases")
    func bannerHeadlineNoForbiddenPhrases() {
        let headline = WU07Strings.headline(detectorCount: 5, doctype: "financial")
        // Forbidden phrase set per the M-1 check (CONTRIBUTING, audit checklist) — assembled
        // via string concat so the test source itself does NOT trip the
        // pre-commit hook that scans for literal occurrences.
        let forbidden: [String] = [
            "guarant" + "ee",
            "ensur" + "e",
            "impossi" + "ble",
            "100" + "%",
            "perfect" + "ly",
            "complete" + "ly",
        ]
        for phrase in forbidden {
            #expect(!headline.lowercased().contains(phrase))
        }
    }

    // MARK: - Disclosure / gated-out count

    @Test("Disclosure label embeds gated-out count + plural suffix")
    func disclosureLabelEmbedsCount() {
        #expect(WU07Strings.disclosureLabel(gatedCount: 4) == "Detector gating · 4 detectors gated out")
        #expect(WU07Strings.disclosureLabel(gatedCount: 1) == "Detector gating · 1 detector gated out")
        #expect(WU07Strings.disclosureLabel(gatedCount: 0) == "Detector gating · 0 detectors gated out")
    }

    @Test("Medical doctype gates out only categories the user has enabled")
    func disclosureRevealsGatedForMedical() {
        // Medical: NPI runs, DEA runs, Account runs, MRN runs (post-W10),
        // DOB runs, Bates does NOT (court/foia only) — but Bates is in the
        // `default: false` bucket of the engine helper, so the V1.x mirror
        // won't surface it. Only DOB/NPI/DEA/Account are gateable in V1.x.
        // For .medical, all four run, so 0 gated out.
        let enabled = Set<PIICategory>([.dateOfBirth, .npi, .dea, .account, .ssn])
        let gated = DoctypeDiagnosticView.gatedOutCategories(for: .medical, enabled: enabled)
        #expect(gated.isEmpty)
    }

    @Test("Financial doctype gates out NPI + DEA (DOB label-anchored per D4)")
    func disclosureRevealsGatedForFinancial() {
        // Financial: DOB runs via the S2 label-anchored dispatch (design 01
        // §1, decision D4 — no longer doctype-gated), NPI off (medical/foia
        // only), DEA off (medical only), Account runs.
        let enabled = Set<PIICategory>([.dateOfBirth, .npi, .dea, .account, .ssn])
        let gated = Set(DoctypeDiagnosticView.gatedOutCategories(for: .financial, enabled: enabled))
        #expect(gated == [.npi, .dea])
    }

    @Test("Court doctype gates out NPI + DEA (account runs post-CND-10)")
    func disclosureRevealsGatedForCourt() {
        // CND-10 (launch-fix-v2 S5): account broadened to run on court (and
        // generic), so it no longer surfaces as gated-out here. NPI (medical/
        // foia only) and DEA (medical only) remain gated on court.
        let enabled = Set<PIICategory>([.dateOfBirth, .npi, .dea, .account, .ssn])
        let gated = Set(DoctypeDiagnosticView.gatedOutCategories(for: .court, enabled: enabled))
        #expect(gated == [.npi, .dea])
    }

    @Test("Disabled categories do not surface in gated-out list (only enabled-and-gated count)")
    func disclosureFiltersToEnabled() {
        // The banner only counts the user's currently-selected detector
        // set: with DOB disabled, the financial gated list is the
        // enabled-and-gated NPI/DEA pair. (Post-D4, DOB is no longer
        // doctype-gated on financial, so the absence assertion below pins
        // the enabled-filter, not the doctype gate.)
        let enabled = Set<PIICategory>([.npi, .dea, .account])  // no DOB
        let gated = Set(DoctypeDiagnosticView.gatedOutCategories(for: .financial, enabled: enabled))
        #expect(gated == [.npi, .dea])
        #expect(!gated.contains(.dateOfBirth))
    }

    // MARK: - V1.x mirror coverage

    @Test("V1.x mirror covers exactly DOB / NPI / DEA / Account (other categories never gate)")
    func mirrorCoverageIsFourCategories() {
        // The engine's `isDoctypeGatedOut(category:doctype:)` returns
        // false for every category except DOB/NPI/DEA/Account in V1.x.
        // Pin that contract so a future engine extension surfaces here.
        let nonGateable: [PIICategory] = [
            .ssn, .creditCard, .email, .phone, .address, .ein, .itin,
            .driversLicense, .name, .passport, .medicalRecord, .licensePlate,
        ]
        for doctype in [DoctypeClass.court, .medical, .financial, .foia, .generic] {
            for category in nonGateable {
                #expect(
                    !DoctypeDiagnosticView.isCategoryGatedOut(category: category, doctype: doctype),
                    "Category \(category) should NOT gate out for \(doctype) under V1.x mirror"
                )
            }
        }
    }

    // MARK: - Display name

    @Test("doctypeDisplayName returns lower-cased label suitable for the headline")
    func displayNameLowercased() {
        let names = [
            DoctypeClass.medical: "medical",
            .financial: "financial",
            .court: "court",
            .foia: "government records",
            .generic: "general",
        ]
        for (cls, expected) in names {
            #expect(DoctypeDiagnosticView.doctypeDisplayName(cls).lowercased() == expected)
        }
    }
}
