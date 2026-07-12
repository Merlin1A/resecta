import Testing
import RedactionEngine
@testable import ResectaApp

// q19 / UXF-09 — pin the shared detector-ID → human-name mapping and
// its fail-open contract (unmapped ID renders the raw ID, never blank).

@Suite("DetectorNameCatalog mapping (q19)")
struct DetectorNameCatalogTests {

    @Test("Known engine ruleIDs map to human names")
    func knownIDsMapped() {
        #expect(DetectorNameCatalog.humanName(forRuleID: "ssn.state-machine") == "SSN pattern check")
        #expect(DetectorNameCatalog.humanName(forRuleID: "cc.luhn") == "Card number check (Luhn)")
        #expect(DetectorNameCatalog.humanName(forRuleID: "email.regex") == "Email format")
        #expect(DetectorNameCatalog.humanName(forRuleID: "name.nltagger") == "Name recognition")
        #expect(DetectorNameCatalog.humanName(forRuleID: "user.alwaysFlag") == "Your always-flag term")
        #expect(DetectorNameCatalog.humanName(forRuleID: "pii.other") == "Other detector")
    }

    @Test("Every RuleCatalog engine ruleID has a human name")
    func fullEngineVocabularyCovered() {
        // The engine-emission vocabulary is authoritatively enumerated by
        // RuleCatalog's alias-map keys; any new emission added there must
        // gain a display name here or this test flags the gap.
        for ruleID in RuleCatalog.knownEngineRuleIDs {
            #expect(DetectorNameCatalog.humanName(forRuleID: ruleID) != nil,
                    "missing human name for engine ruleID: \(ruleID)")
        }
    }

    @Test("Human names contain no raw-ID vocabulary")
    func namesAreHuman() {
        for (ruleID, name) in DetectorNameCatalog.names {
            #expect(!name.isEmpty, "empty name for \(ruleID)")
            #expect(name != ruleID, "name identical to raw ID for \(ruleID)")
            #expect(!name.contains("regex"), "raw 'regex' token leaked into name for \(ruleID)")
        }
    }

    @Test("Unmapped ruleID fails open to the raw ID, never blank")
    func failOpen() {
        #expect(DetectorNameCatalog.humanName(forRuleID: "totally.unknown") == nil)
        #expect(DetectorNameCatalog.displayName(forRuleID: "totally.unknown") == "totally.unknown")
    }

    @Test("Version-suffixed ruleID resolves to its family name")
    func versionSuffixTolerated() {
        #expect(DetectorNameCatalog.humanName(forRuleID: "ssn.state-machine.v2") == "SSN pattern check")
        #expect(DetectorNameCatalog.displayName(forRuleID: "mrn.labeled.v3") == "Medical record number (labeled)")
        // Only a trailing .vN strips — an unknown base still fails open.
        #expect(DetectorNameCatalog.displayName(forRuleID: "unknown.family.v9") == "unknown.family.v9")
    }
}
