import Testing
import Foundation
@testable import RedactionEngine

// The legal-prefix pass reads the words after a role noun or honorific as the
// name that follows it. A sentence boundary directly after the prefix — a
// period, semicolon or colon and then a line break — ends that reading: the
// next line's first capitalised word is a new sentence, not the name after the
// prefix. A bare line break, or punctuation on the same line, still assembles.
//
// Deterministic: the prefix pass needs no NER asset.
//
// Synthetic Hartwell/Sablebrook cast only (repo test-data policy).
//
// Privacy rule (audit-lint M-1): comments and test names use
// locate/surface/resolve vocabulary.

@Suite("Legal prefix pass: sentence boundary after the prefix")
struct LegalPrefixBoundaryTests {

    private static func names(in text: String) -> [PIIDetector.PIIMatch] {
        PIIDetector().detectNames(in: text)
    }

    private static func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    private static func overlaps(_ matches: [PIIDetector.PIIMatch], _ range: NSRange) -> Bool {
        matches.contains { NSIntersectionRange($0.range, range).length > 0 }
    }

    @Test("A period and a line break after the prefix end the assembly")
    func periodThenLineBreakEndsTheAssembly() {
        let texts = [
            "The motion was served on behalf of Plaintiff.\nDefendant reserves all rights.",
            "The motion was served on behalf of Plaintiff. \nDefendant reserves all rights.",
            "The motion was served on behalf of Plaintiff.\r\nDefendant reserves all rights.",
        ]
        for text in texts {
            let hits = Self.names(in: text)
            #expect(!hits.contains { $0.text == "Defendant" },
                    "the next line's opener was read as the name after the prefix")
            #expect(!Self.overlaps(hits, Self.range(of: "Defendant", in: text)))
        }
    }

    @Test("A sentence opener on the next line is not the name after the prefix")
    func sentenceOpenerOnTheNextLineIsNotAName() {
        let text = "Judgment was entered against Defendant.\nThe motion is denied."
        let hits = Self.names(in: text)
        #expect(!hits.contains { $0.text == "The" },
                "the sentence opener on the next line surfaced as a name")
        #expect(!Self.overlaps(hits, Self.range(of: "The motion", in: text)))
    }

    @Test("A semicolon or a colon and a line break after the prefix end the assembly")
    func semicolonOrColonThenLineBreakEndsTheAssembly() {
        let texts = [
            "Notice was served on Plaintiff;\nDefendant reserves all rights.",
            "Notice to Plaintiff:\nDefendant reserves all rights.",
        ]
        for text in texts {
            let hits = Self.names(in: text)
            #expect(!hits.contains { $0.text == "Defendant" },
                    "the next line's opener was read as the name after the prefix")
        }
    }

    @Test("A bare line break after the prefix still assembles the name")
    func bareLineBreakStillAssembles() {
        let text = "Plaintiff\nMarcus Bellamy moved for summary judgment."
        let hits = Self.names(in: text)
        #expect(Self.overlaps(hits, Self.range(of: "Marcus Bellamy", in: text)),
                "a caption line break without punctuation must still assemble the name")
        #expect(!hits.contains { $0.text == "Plaintiff" })
    }

    @Test("Punctuation on the same line as the name still assembles")
    func sameLinePunctuationStillAssembles() {
        let texts = [
            "Plaintiff: Marcus Bellamy moved for summary judgment.",
            "Plaintiff Marcus Bellamy moved for summary judgment.",
            "Plaintiff, Marcus Bellamy, moved for summary judgment.",
            "Patient: Delia Hartwell reported pain at rest.",
        ]
        for text in texts {
            let hits = Self.names(in: text)
            let name = text.contains("Hartwell") ? "Delia Hartwell" : "Marcus Bellamy"
            #expect(Self.overlaps(hits, Self.range(of: name, in: text)),
                    "the name after same-line punctuation must surface: \(text)")
        }
    }
}
