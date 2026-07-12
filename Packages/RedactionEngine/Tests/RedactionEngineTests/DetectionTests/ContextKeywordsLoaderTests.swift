import Testing
import Foundation
@testable import RedactionEngine

// W-N — A21 (`Resources/Gazetteers/context-keywords.json`) loader tests.
// Schema lives at `~/resecta-datapipeline/schemas/context_keywords.schema.json`.
//
// V1 ship is positive-only mechanical lift (Q3 DECIDED 2026-04-30 / STRAT
// §1.5 row 14): the 4 retired `*ContextKeywords.swift` files keep their
// `negativeKeywords:` arrays + threshold constants; only `positiveKeywords:`
// becomes loader-driven. Negative arrays in those files are exercised by
// the sibling `ContextProfileNegativesPreservedTests`.

@Suite("ContextKeywordsLoader (W-N) — A21 schema + parity")
struct ContextKeywordsLoaderTests {

    // MARK: - Smoke / loader contract

    @Test("Loader exposes 192 entries across 9 categories (A21 post-S3 row count)")
    func smokeFullEntries() throws {
        // S3 (search-impl, design 02 §§2.1/2.6): +5 ssn, +5 name, +6 ein.
        // The bundled file carries 213 rows; the 21 bates rows are
        // engine-invisible (mapCategory has no bates case), so the loader
        // exposes 192.
        let loader = try ContextKeywordsLoader()
        let perCategory: [(PIICategory, Int)] = [
            (.ssn, 15), (.medicalRecord, 13), (.licensePlate, 11),
            (.dea, 29), (.dateOfBirth, 26), (.itin, 28), (.name, 35), (.npi, 29),
            (.ein, 6),
        ]
        var total = 0
        for (cat, expected) in perCategory {
            let count = loader.entries(for: cat).count
            #expect(count == expected,
                    "category \(cat) entry count: expected \(expected), got \(count)")
            total += count
        }
        #expect(total == 192, "A21 total entry count regressed (expected 192)")
    }

    @Test("Empty bundle throws resourceMissing")
    func emptyBundleThrows() {
        #expect(throws: ContextKeywordsLoader.LoaderError.self) {
            _ = try ContextKeywordsLoader(bundle: Bundle())
        }
    }

    @Test("supportedVersions is 1...1 (W-O loader-version-fence policy)")
    func supportedVersionsFenceMatchesPolicy() {
        #expect(ContextKeywordsLoader.supportedVersions == 1...1)
    }

    @Test("`weight(for:)` honors the F-50/F-51 five-case enum")
    func confidenceWeightMapping() {
        #expect(ContextKeywordsLoader.weight(for: "high") == 1.0)
        #expect(ContextKeywordsLoader.weight(for: "medium-high") == 0.85)
        #expect(ContextKeywordsLoader.weight(for: "medium") == 0.7)
        #expect(ContextKeywordsLoader.weight(for: "medium (flag)") == 0.55)
        #expect(ContextKeywordsLoader.weight(for: "low") == 0.4)
        // Defensive default for an out-of-enum string (schema gates this
        // at build but the loader should not crash on a hand-edited JSON).
        #expect(ContextKeywordsLoader.weight(for: "garbage") == 0.7)
    }

    // MARK: - Axis 1 (positive lane): every Swift positive appears in A21

    @Test("Axis 1: SSN positives in Swift all present as A21 ssn rows")
    func axis1SSN() throws {
        let loader = try ContextKeywordsLoader()
        let a21 = Set(loader.entries(for: .ssn).map { $0.term.lowercased() })
        // 10 global + 5 financial-scoped (S3, design 02 §2.1).
        #expect(a21.count == 15, "A21 SSN-positive count drifted off 15 — STOP per STRAT §5.1")
        for term in SSNContextKeywords.profile.positiveKeywords {
            #expect(a21.contains(term.lowercased()),
                    "SSN positive '\(term)' missing from A21 (axis 1)")
        }
    }

    @Test("Axis 1: MRN positives in Swift all present as A21 mrn rows")
    func axis1MRN() throws {
        let loader = try ContextKeywordsLoader()
        let a21 = Set(loader.entries(for: .medicalRecord).map { $0.term.lowercased() })
        for term in MRNContextKeywords.profile.positiveKeywords {
            #expect(a21.contains(term.lowercased()),
                    "MRN positive '\(term)' missing from A21 (axis 1)")
        }
    }

    @Test("Axis 1: License-plate positives in Swift all present as A21 licenseplate rows")
    func axis1LicensePlate() throws {
        let loader = try ContextKeywordsLoader()
        let a21 = Set(loader.entries(for: .licensePlate).map { $0.term.lowercased() })
        for term in LicensePlateContextKeywords.profile.positiveKeywords {
            #expect(a21.contains(term.lowercased()),
                    "LP positive '\(term)' missing from A21 (axis 1)")
        }
    }

    // MARK: - Axis 2 (negative lane): Swift negatives do NOT appear in A21

    @Test("Axis 2: SSN negatives in Swift do NOT appear in A21 ssn rows")
    func axis2SSN() throws {
        let loader = try ContextKeywordsLoader()
        let a21 = Set(loader.entries(for: .ssn).map { $0.term.lowercased() })
        for term in SSNContextKeywords.profile.negativeKeywords {
            #expect(!a21.contains(term.lowercased()),
                    "SSN negative '\(term)' incorrectly carried as positive in A21")
        }
    }

    @Test("Axis 2: MRN negatives in Swift do NOT appear in A21 mrn rows")
    func axis2MRN() throws {
        let loader = try ContextKeywordsLoader()
        let a21 = Set(loader.entries(for: .medicalRecord).map { $0.term.lowercased() })
        for term in MRNContextKeywords.profile.negativeKeywords {
            #expect(!a21.contains(term.lowercased()),
                    "MRN negative '\(term)' incorrectly carried as positive in A21")
        }
    }

    @Test("Axis 2: License-plate negatives in Swift do NOT appear in A21 licenseplate rows")
    func axis2LicensePlate() throws {
        let loader = try ContextKeywordsLoader()
        let a21 = Set(loader.entries(for: .licensePlate).map { $0.term.lowercased() })
        for term in LicensePlateContextKeywords.profile.negativeKeywords {
            #expect(!a21.contains(term.lowercased()),
                    "LP negative '\(term)' incorrectly carried as positive in A21")
        }
    }

    @Test("Axis 2 cap: ≤8 SSN negatives overlap with A5 SSN-scoped 108 entries")
    func axis2OverlapCap() throws {
        let bundle = ContextKeywordsLoader._resourceBundleForTesting
        let url = try #require(bundle.url(
            forResource: "negative-context",
            withExtension: "json",
            subdirectory: "Gazetteers"
        ))
        struct A5: Decodable {
            struct Entry: Decodable {
                let keyword: String
                let categoryScope: String
                enum CodingKeys: String, CodingKey {
                    case keyword
                    case categoryScope = "category_scope"
                }
            }
            let entries: [Entry]
        }
        let bytes = try Data(contentsOf: url)
        let a5 = try JSONDecoder().decode(A5.self, from: bytes)
        let a5SSN = Set(
            a5.entries.filter { $0.categoryScope == "ssn" }
                .map { $0.keyword.lowercased() }
        )
        // S3 (2026-06-11): the bundled file is now the maintainer-reviewed
        // 166-entry rebuild (§2.2 review in-session; reviewed_version
        // fdaf6ab9…) — A5 SSN-scoped keywords total 68, down from the
        // pre-audit 108. The invariant is the upstream contract; the cap
        // that matters for W-N is the overlap below.
        #expect(a5SSN.count == 68,
                "A5 SSN-scoped count drifted off 68 (got \(a5SSN.count)); revisit cap before reading further")

        let swiftSSNNegatives = SSNContextKeywords.profile.negativeKeywords
            .map { $0.lowercased() }
        let overlap = swiftSSNNegatives.filter { a5SSN.contains($0) }
        // The ≤N cap is intentionally brittle — see STRAT §5.1 axis 2:
        // when this number changes, the §2.2 A5-review process kicks in.
        // S3 raised it 8 → 10 under the in-session §2.2 review: the S3
        // additions put `claim number` into (ssn, financial) and the
        // reviewed rebuild retains `case number`/`docket`/`docket number`
        // (A5 keep-list trio, decision 2026-06-11) — double-coverage with
        // the Swift hardcoded negatives is redundant, not harmful
        // (design 02 §2.3 risk note).
        #expect(overlap.count <= 10,
                "SSN Swift-negative ↔ A5 overlap = \(overlap.count) > 10 (overlapping: \(overlap.sorted()))")
    }

    // MARK: - Doctype-scoped lookup

    @Test("SSN positives: 10 globals plus the S3 doctype-scoped financial/foia rows")
    func ssnPositivesDoctypeScoping() throws {
        // Pre-S3 every ssn row was doctypes-global. S3 (design 02 §2.1)
        // added 5 doctype-scoped rows: 4 financial-only plus
        // "taxpayer identification number" on financial+foia. The loader
        // layers scoped rows on top of the globals for a concrete doctype
        // and returns only the globals for nil.
        let loader = try ContextKeywordsLoader()
        let nilPositives = try #require(loader.positiveKeywords(for: .ssn, doctype: nil))
        #expect(nilPositives.count == 10, "global ssn positives drifted off 10")

        let expectedCounts: [DoctypeClass: Int] = [
            .financial: 15, .foia: 11,
        ]
        for doctype in DoctypeClass.allCases {
            let scoped = try #require(loader.positiveKeywords(for: .ssn, doctype: doctype))
            let expected = expectedCounts[doctype] ?? 10
            #expect(scoped.count == expected,
                    "SSN positives for doctype \(doctype): expected \(expected), got \(scoped.count)")
            #expect(scoped.isSuperset(of: nilPositives),
                    "doctype-scoped set for \(doctype) must contain every global row")
        }
    }

    // MARK: - Optional flags surfaced through Entry struct

    @Test("`detector_requires_secondary` exposed for F-47 bare DEA")
    func detectorRequiresSecondaryExposedForBareDEA() throws {
        let loader = try ContextKeywordsLoader()
        let flagged = loader.entries(for: .dea)
            .filter { $0.detectorRequiresSecondary == true }
        #expect(flagged.count == 1,
                "Exactly one A21 row should carry detector_requires_secondary=true (F-47 bare DEA)")
        #expect(flagged.first?.term.lowercased() == "dea")
    }

    @Test("`detector_note` exposed for F-52 DOB windowed-matching family")
    func detectorNoteExposedForDOBFamily() throws {
        let loader = try ContextKeywordsLoader()
        let dobNotes = loader.entries(for: .dateOfBirth)
            .filter { $0.detectorNote != nil }
        #expect(!dobNotes.isEmpty,
                "DOB family must carry detector_note rows for F-52 windowed-matching")
        for entry in dobNotes {
            #expect(entry.detectorNote?.contains("F-52") == true,
                    "DOB detector_note should reference F-52 (got \(entry.detectorNote ?? "nil"))")
        }
    }
}
