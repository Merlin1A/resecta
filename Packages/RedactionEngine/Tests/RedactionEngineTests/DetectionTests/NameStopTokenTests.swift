import Testing
import Foundation
@testable import RedactionEngine

// The whole-candidate name stop tokens: ten tokens the tagger reads as given
// names when they open a sentence or a label, or that the prefix pass
// assembles on their own after a role noun. Two measured units — five court
// and licence label tokens, then five furniture tokens (the honorific, the
// role nouns and the legal opener) added together and measured together on
// the furniture profiles. Exact, case-sensitive equality on the candidate only
// — a name that FOLLOWS a role noun still surfaces (the prefix pass exists for
// that), the bare role noun never does.
//
// Section A pins the constant and the prefix pass (deterministic). Section B
// drives the detector through NLTagger and is gated on the OS-provisioned
// `.nameType` NER asset (`PIIDetector.isNameNERAvailable()`, reliably
// provisioned on iOS 26.4 — the detection harness pin), following the
// NameRecallTransactionLinesTests skip pattern. Section C pins the set against
// the G8 corpus name inventory.
//
// Synthetic Hartwell/Sablebrook cast only (repo test-data policy).
//
// Privacy rule (audit-lint M-1): comments and test names use
// locate/surface/resolve vocabulary.

@Suite("Name stop tokens (whole-candidate role-noun and label suppression)")
struct NameStopTokenTests {

    /// The second measured unit (S4-P2): the honorific with and without its
    /// period, two role nouns and the legal opener.
    private static let furnitureTokens: [String] = ["Dr.", "Dr", "Patient", "Pursuant", "Counsel"]

    private static func skipNER(_ test: String, sourceLocation: SourceLocation = #_sourceLocation) {
        TestGate.skip("[NLTagger gate] .nameType NER asset unavailable on this runtime; skipping \(test) (harness pin = iOS 26.4).", sourceLocation: sourceLocation)
    }

    private static func names(in text: String) -> [PIIDetector.PIIMatch] {
        PIIDetector().families.name.detect(in: text)
    }

    private static func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    private static func overlaps(_ matches: [PIIDetector.PIIMatch], _ range: NSRange) -> Bool {
        matches.contains { NSIntersectionRange($0.range, range).length > 0 }
    }

    // MARK: - A. The constant and the prefix pass

    @Test("The stop set is exactly the ten measured tokens")
    func stopSetIsTheTenTokens() {
        #expect(NameDetector.nameStopTokens == [
            "Plaintiff", "Reg", "PP", "Lic", "DL",
            "Dr.", "Dr", "Patient", "Pursuant", "Counsel",
        ])
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
            #expect(!NameDetector.nameStopTokens.contains(hit.text))
        }
    }

    @Test("A furniture token standing alone after a legal prefix is not assembled as the name")
    func furnitureTokenAloneAfterAPrefixIsNotAssembled() {
        // Each line puts one furniture token right after a legal prefix so the
        // prefix pass would assemble the token itself as "the name after the
        // prefix"; the lowercase word after it stops the assembly there.
        let lines = [
            "Attorney Counsel appeared for the defense at the hearing.",
            "Witness Patient was examined by the physician on duty.",
            "Respondent Pursuant to the scheduling order filed a reply.",
            "Agent Dr. reported nothing further to the desk.",
            "Agent Dr reported nothing further to the desk.",
        ]
        for text in lines {
            let hits = Self.names(in: text)
            for token in Self.furnitureTokens {
                #expect(!hits.contains { $0.text == token },
                        "\(token) surfaced as a lone name after a prefix in: \(text)")
            }
            for hit in hits {
                #expect(!NameDetector.nameStopTokens.contains(hit.text))
            }
        }
    }

    @Test("A name after a furniture token still surfaces through the prefix pass")
    func nameAfterAFurnitureTokenStillSurfaces() {
        let cases: [(text: String, name: String)] = [
            ("Patient Delia Hartwell reported pain at rest.", "Delia Hartwell"),
            ("Counsel Marcus Bellamy appeared for the defense.", "Marcus Bellamy"),
            ("Dr. Jane Smith signed the discharge summary.", "Jane Smith"),
        ]
        for c in cases {
            let hits = Self.names(in: c.text)
            #expect(Self.overlaps(hits, Self.range(of: c.name, in: c.text)),
                    "the name after the furniture token must surface: \(c.text)")
            for hit in hits {
                #expect(!NameDetector.nameStopTokens.contains(hit.text))
            }
        }
    }

    @Test("An honorific followed by a name is a multi-token candidate the stop set leaves alone")
    func honorificWithNameIsNotAStopToken() {
        // Whole-candidate equality only: "Dr." alone is stopped, "Dr. Jane
        // Smith" is not a member and the name after the honorific surfaces.
        #expect(!NameDetector.nameStopTokens.contains("Dr. Jane Smith"))
        #expect(!NameDetector.nameStopTokens.contains("Jane Smith"))
        let text = "Dr. Jane Smith reviewed the chart before rounds."
        let hits = Self.names(in: text)
        #expect(Self.overlaps(hits, Self.range(of: "Jane Smith", in: text)),
                "the name after the honorific must surface")
        #expect(!hits.contains { $0.text == "Dr." || $0.text == "Dr" },
                "the bare honorific is never a name candidate")
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
            #expect(!NameDetector.nameStopTokens.contains(hit.text))
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
                #expect(!NameDetector.nameStopTokens.contains(hit.text),
                        "a stop token surfaced as a name in a label line")
            }
        }
    }

    @Test("Furniture tokens opening a sentence or a label are not names")
    func furnitureTokensAsLoneCandidatesAreNotNames() {
        guard PIIDetector.isNameNERAvailable() else {
            Self.skipNER("furnitureTokensAsLoneCandidatesAreNotNames"); return
        }
        let lines = [
            "Dr. will review the chart before the afternoon rounds.",
            "Dr will review the chart before the afternoon rounds.",
            "Patient reports no pain at rest and sleeps through the night.",
            "Pursuant to the order, the clerk entered the notice on the docket.",
            "Counsel for the defense objected on the record.",
        ]
        for text in lines {
            let hits = Self.names(in: text)
            for token in Self.furnitureTokens {
                #expect(!hits.contains { $0.text == token },
                        "\(token) surfaced as a lone name in: \(text)")
            }
            for hit in hits {
                #expect(!NameDetector.nameStopTokens.contains(hit.text),
                        "a stop token surfaced as a name in a furniture line")
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

    // MARK: - C. The G8 name inventory pin

    @Test("The 129 distinct G8 corpus name tokens are all outside the stop set")
    func g8NameTokensAreOutsideTheStopSet() throws {
        let url = try #require(Bundle.module.url(forResource: "g8_corpus", withExtension: "json",
                                                 subdirectory: "corpus"))
        let corpus = try JSONDecoder().decode(G8BaselineHarnessTests.BaselineG8Corpus.self,
                                              from: Data(contentsOf: url))
        var tokens = Set<String>()
        var values = Set<String>()
        for doc in corpus.documents {
            let ns = doc.text as NSString
            for span in doc.pii_spans where span.category == "name" {
                let value = ns.substring(with: NSRange(location: span.start, length: span.end - span.start))
                values.insert(value)
                for raw in value.replacingOccurrences(of: ",", with: " ").split(separator: " ") {
                    let t = TextNormalizer.normalize(String(raw)).lowercased()
                        .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
                    if !t.isEmpty { tokens.insert(t) }
                }
            }
        }
        #expect(tokens.count == 129, "the G8 name-token inventory moved (\(tokens.count)); re-pin with the corpus")
        // Case-folded and period-trimmed, so "Dr." and "dr" meet on the same key.
        let folded = Set(NameDetector.nameStopTokens.map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        })
        let overlap = tokens.intersection(folded)
        #expect(overlap.isEmpty, "G8 name tokens in the stop set: \(overlap.sorted())")
        let whole = values.intersection(NameDetector.nameStopTokens)
        #expect(whole.isEmpty, "a G8 name value equals a stop token: \(whole.sorted())")
    }
}
