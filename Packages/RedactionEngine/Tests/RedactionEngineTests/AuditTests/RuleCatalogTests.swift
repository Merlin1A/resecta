import Testing
import Foundation
@testable import RedactionEngine

// W-I2 — A22 catalog loader + engine-ruleID alias-map reconciliation
// (path-(a) per Q1 / 2026-04-30 DECIDED).

@Suite("W-I2 RuleCatalog (A22) loader + engine-rule-id reconciliation")
struct RuleCatalogTests {

    @Test("Loader round-trips on shipped rule-catalog.json (21 entries)")
    func loaderRoundTrip() throws {
        let catalog = try RuleCatalog()
        // 21 entries: 18 post Bates-removal (§B.1 row 5) + pii.routing_number.v1
        // (search-impl S2, design 01 §4) + pii.barcode.vision.v1 and
        // pii.signature.heuristic.v1 (speed-S01 rows; the S3 install
        // 2026-06-11 reconciled the bundled copy with the pipeline's
        // 21-row rule_catalog.json). If this count drifts further,
        // surface to the maintainer.
        #expect(catalog.entries.count == 21)
        // Top-level keys + entry shape are sanity-checked via the decoder
        // run above; spot-check a representative entry.
        let ssn = catalog.entry(forCatalogRuleID: "pii.ssn.state_machine.v1")
        #expect(ssn?.detector == "SSNStateMachine")
        #expect(ssn?.family == "pii")
        #expect(ssn?.version == "1.0")
        #expect(ssn?.isChecksumGated == false)
    }

    @Test("Every engine ruleID in the alias map resolves to a catalog entry")
    func engineAliasesAllResolve() throws {
        let catalog = try RuleCatalog()
        for engineID in RuleCatalog.knownEngineRuleIDs {
            #expect(
                catalog.entry(forEngineRuleID: engineID) != nil,
                "engine ruleID \(engineID) maps to a catalog rule_id but the rule_id is not in the catalog"
            )
        }
    }

    @Test("Every catalog rule_id is targeted by ≥1 engine alias")
    func everyCatalogRuleIDIsAliased() throws {
        let catalog = try RuleCatalog()
        let aliasedCatalogIDs = Set(
            RuleCatalog.knownEngineRuleIDs.compactMap {
                catalog.entry(forEngineRuleID: $0)?.ruleID
            }
        )
        let allCatalogIDs = Set(catalog.entries.map { $0.ruleID })
        let unaliased = allCatalogIDs.subtracting(aliasedCatalogIDs)
        // V1 expectation: 0 unaliased. If a new catalog entry lands
        // without a paired engine alias, surface to the maintainer — that's
        // either dead catalog content or a missing engine emission.
        #expect(
            unaliased.isEmpty,
            "catalog rule_ids with no engine alias: \(unaliased.sorted())"
        )
    }

    @Test("Synthetic ruleIDs (user.alwaysFlag, pii.other) do NOT resolve")
    func syntheticRuleIDsAreUntranslated() throws {
        let catalog = try RuleCatalog()
        // These are intentionally absent from the alias map. Catching
        // their accidental addition prevents audit-export rows from
        // claiming a catalog `version` they have no provenance for.
        #expect(catalog.entry(forEngineRuleID: "user.alwaysFlag") == nil)
        #expect(catalog.entry(forEngineRuleID: "pii.other") == nil)
    }

    @Test("Every literal ruleID emitted by the engine has an alias-map entry")
    func everyEmittedRuleIDIsAliased() throws {
        // Closed enumeration of literal `ruleID:` strings reachable from
        // the engine, derived from PIIDetector.defaultRuleID(for:) +
        // explicit-emission sites in PIIDetector / DEADetector. Bates
        // emission removed alongside the Bates detection category;
        // updates here track engine emissions as they change.
        let emittedByEngine: Set<String> = [
            // defaultRuleID(for:) arms
            "ssn.regex", "cc.luhn", "email.regex", "phone.regex",
            "ein.regex", "itin.regex", "address.regex", "dob.regex",
            "dl.regex", "passport.regex", "mrn.regex", "npi.80840",
            "dea.letter-check", "account.regex", "name.nltagger",
            "licensePlate.labeled",
            // Search-impl S2 (design 01 §4): emitted by RoutingNumberDetector
            // and defaultRuleID(for: .routingNumber).
            "routingNumber.aba-checksum",
            // Search-impl S2 (design 01 §6): ITIN scorer-migration rationale
            // ruleID, folded onto pii.itin.v1 (SSN-style).
            "itin.yy-bucket",
            // Speed-S01 catalog rows, aliased at the S3 21-row install:
            // defaultRuleID(for: .barcode / .signatureCandidate) arms.
            "barcode.vision", "signature.heuristic",
            // explicit-emission overrides
            "ssn.state-machine", "mrn.labeled", "mrn.patientID",
            "mrn.institution",
        ]
        // Synthetic ruleIDs are intentionally untranslated (see suite test
        // syntheticRuleIDsAreUntranslated above): "user.alwaysFlag",
        // "pii.other". Excluded from the enumeration on purpose.
        let aliased = RuleCatalog.knownEngineRuleIDs
        let missing = emittedByEngine.subtracting(aliased)
        #expect(
            missing.isEmpty,
            "engine emits ruleID(s) with no alias map entry — runtime ruleVersion will be nil for: \(missing.sorted())"
        )
    }

    @Test("Catalog entry surfaces version + sourceArtifact through alias lookup")
    func aliasLookupSurfacesProvenance() throws {
        let catalog = try RuleCatalog()
        // dl.regex → pii.dl.v1, which has source_artifact "dl_patterns.json".
        let dl = catalog.entry(forEngineRuleID: "dl.regex")
        #expect(dl?.ruleID == "pii.dl.v1")
        #expect(dl?.sourceArtifact == "dl_patterns.json")
        #expect(dl?.version == "1.0")
        // ssn.state-machine → pii.ssn.state_machine.v1 (source_artifact null).
        let ssn = catalog.entry(forEngineRuleID: "ssn.state-machine")
        #expect(ssn?.ruleID == "pii.ssn.state_machine.v1")
        #expect(ssn?.sourceArtifact == nil)
    }
}
