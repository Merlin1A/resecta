import Testing
import Foundation
@testable import RedactionEngine

// The legal-prefix pass reads the name after a role noun or honorific from a
// single-spaced rebuild of the words, but its match must cover the RAW span
// in the page text: a run of spaces between the name's words ("Mr. Quillon
// Varrastine" set with two spaces by a justified line) is one UTF-16 unit
// per extra space longer than the rebuild, and a range sized from the
// rebuild leaves the name's last characters outside the box.
//
// The pass is read directly (`scanLegalPrefixes`), so a tagger row on the
// same text cannot stand in for it. Deterministic: no NER asset.
//
// Synthetic cast only: the names are invented so neither the tagger nor the
// gazetteer reads them (repo test-data policy).
//
// Privacy rule (audit-lint M-1): comments and test names use locate/cover/
// resolve vocabulary.

@Suite("Legal prefix pass: the match covers the raw span")
struct LegalPrefixRawSpanTests {

    private static func prefixMatches(in text: String) -> [PIIDetector.PIIMatch] {
        PIIDetector().families.name.scanLegalPrefixes(in: text)
    }

    private static func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    @Test("Two spaces inside the name after an honorific: the range and text cover the raw name")
    func doubleSpaceInsideTheNameCoversTheRawSpan() {
        let text = "Mr. Quillon  Varrastine appeared in person."
        let hits = Self.prefixMatches(in: text)
        let expected = Self.range(of: "Quillon  Varrastine", in: text)
        #expect(hits.count == 1)
        #expect(hits.first?.range == expected,
                "the range must end at the raw surname's end, not one unit short: \(String(describing: hits.first?.range)) vs \(expected)")
        #expect(hits.first?.text == "Quillon  Varrastine")
    }

    @Test("A form label with spaces after the colon and a run inside the name covers the raw span")
    func formLabelWithRunsOfSpacesCoversTheRawSpan() {
        let text = "Patient:  Xyrel   Obundo reported pain at rest."
        let hits = Self.prefixMatches(in: text)
        let expected = Self.range(of: "Xyrel   Obundo", in: text)
        #expect(hits.count == 1)
        #expect(hits.first?.range == expected,
                "the range must start after the label's trim and end at the raw surname's end: \(String(describing: hits.first?.range)) vs \(expected)")
        #expect(hits.first?.text == "Xyrel   Obundo")
        if let hit = hits.first {
            #expect((text as NSString).substring(with: hit.range) == hit.text)
        }
    }

    @Test("A single-spaced name after the prefix is unchanged")
    func singleSpacedNameUnchanged() {
        let texts = [
            ("Mr. Quillon Varrastine appeared in person.", "Quillon Varrastine"),
            ("Patient: Xyrel Obundo reported pain at rest.", "Xyrel Obundo"),
        ]
        for (text, name) in texts {
            let hits = Self.prefixMatches(in: text)
            #expect(hits.count == 1)
            #expect(hits.first?.range == Self.range(of: name, in: text))
            #expect(hits.first?.text == name)
        }
    }

    @Test("A stop token standing alone after the prefix is still not a name")
    func stopTokenAloneStillSkipped() {
        // The stop-token check reads the single-spaced rebuild; the raw span
        // only sizes a match that passes it.
        let text = "The clerk notified Witness  Pursuant to the order of the Court."
        let hits = Self.prefixMatches(in: text)
        #expect(!hits.contains { $0.text.hasPrefix("Pursuant") },
                "a stop token after the prefix surfaced as a name: \(hits.map(\.text))")
    }
}
