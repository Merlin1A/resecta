import Testing
import Foundation
@testable import RedactionEngine

// The whole-candidate name stop tokens: five court and licence label tokens the
// tagger reads as given names when they open a sentence or a label. Exact,
// case-sensitive equality on the candidate only — a name that FOLLOWS a role
// noun still surfaces (the prefix pass exists for that), the bare role noun
// never does.
//
// Section A pins the constant and the prefix pass (deterministic). Section B
// drives the detector through NLTagger and is gated on the OS-provisioned
// `.nameType` NER asset (`PIIDetector.isNameNERAvailable()`, reliably
// provisioned on iOS 26.4 — the detection harness pin), following the
// NameRecallTransactionLinesTests skip pattern.
//
// Synthetic Hartwell/Sablebrook cast only (repo test-data policy).
//
// Privacy rule (audit-lint M-1): comments and test names use
// locate/surface/resolve vocabulary.

@Suite("Name stop tokens (whole-candidate role-noun and label suppression)")
struct NameStopTokenTests {

    private static func skipNER(_ test: String) {
        print("[NLTagger gate] .nameType NER asset unavailable on this runtime; "
              + "skipping \(test) (harness pin = iOS 26.4).")
    }

    private static func names(in text: String) -> [PIIDetector.PIIMatch] {
        PIIDetector().detectNames(in: text)
    }

    private static func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    private static func overlaps(_ matches: [PIIDetector.PIIMatch], _ range: NSRange) -> Bool {
        matches.contains { NSIntersectionRange($0.range, range).length > 0 }
    }

    // MARK: - A. The constant and the prefix pass

    @Test("The stop set is exactly the five measured tokens")
    func stopSetIsTheFiveTokens() {
        #expect(PIIDetector.nameStopTokens == ["Plaintiff", "Reg", "PP", "Lic", "DL"])
    }

    @Test("A name after a role noun still surfaces; the role noun alone never does")
    func nameAfterRoleNounSurfacesRoleNounDoesNot() {
        let text = "Plaintiff Marcus Bellamy moved for summary judgment."
        let hits = Self.names(in: text)
        // The prefix pass anchors on "Plaintiff" and yields the name that
        // follows it, NER or not.
        #expect(Self.overlaps(hits, Self.range(of: "Marcus Bellamy", in: text)),
                "the name following the role noun must surface")
        #expect(!hits.contains { $0.text == "Plaintiff" },
                "the bare role noun is never a name candidate")
        for hit in hits {
            #expect(!PIIDetector.nameStopTokens.contains(hit.text))
        }
    }

    // MARK: - B. The tagger passes (NER-gated)

    @Test("A sentence-initial role noun over a registration label is not a name")
    func sentenceInitialRoleNounIsNotAName() {
        guard PIIDetector.isNameNERAvailable() else {
            Self.skipNER("sentenceInitialRoleNounIsNotAName"); return
        }
        let text = "Plaintiff is a corporation, Business Registration # 2018-VA-22914 "
            + "on file with the secretary of state."
        let hits = Self.names(in: text)
        #expect(!Self.overlaps(hits, Self.range(of: "Plaintiff", in: text)),
                "the sentence-initial role noun must not be redacted as a name")
        for hit in hits {
            #expect(!PIIDetector.nameStopTokens.contains(hit.text))
        }
    }

    @Test("Licence and registration label tokens are not names")
    func labelTokensAreNotNames() {
        guard PIIDetector.isNameNERAvailable() else {
            Self.skipNER("labelTokensAreNotNames"); return
        }
        let lines = [
            "The vehicle bearing Reg # 7XK-4419 is registered to the defendant as owner.",
            "Defendant identification on file -- Lic O7187809.",
            "Scope: travel records associated with PP U12899779.",
            "Identity verified at intake -- DL S4482911.",
        ]
        for text in lines {
            let hits = Self.names(in: text)
            for hit in hits {
                #expect(!PIIDetector.nameStopTokens.contains(hit.text),
                        "a stop token surfaced as a name in a label line")
            }
        }
    }

    @Test("A control name adjacent to a stop token still surfaces")
    func controlNameBesideStopTokenStillSurfaces() {
        guard PIIDetector.isNameNERAvailable() else {
            Self.skipNER("controlNameBesideStopTokenStillSurfaces"); return
        }
        let text = "Reg # 7XK-4419 is registered to Delia Hartwell as owner."
        let hits = Self.names(in: text)
        #expect(Self.overlaps(hits, Self.range(of: "Delia Hartwell", in: text)),
                "the name beside the label token must still surface")
        #expect(!hits.contains { $0.text == "Reg" })
    }
}
