import Testing
import Foundation
@testable import RedactionEngine

// CAT-070 — name-range mapping fixes. Two independent defects in the name
// passes produced redaction boxes offset from the actual name:
//   (1) `runNLTagger` converted a title-cased-string range against the original
//       string (cross-string NSRange) — wrong whenever `titleCaseAllCapsWords`
//       changed the layout (collapsed runs of spaces / length-changing casing).
//   (2) `scanLegalPrefixes` placed the name range at the post-prefix offset
//       without accounting for the leading punctuation/whitespace it trimmed
//       ("Patient: " etc.), left-shifting the box onto the separator.
//
// These drive the two private passes through the #if DEBUG seams so each fix is
// validated in isolation, free of the NLTagger/dedup interaction inside
// `detectNames`. Synthetic names only — no real document content.
//
// Privacy rule (audit-lint M-1): test names use locate/resolve vocabulary.

@Suite("Name detector range correctness (CAT-070)")
struct NameDetectorRangeTests {

    @Test("Title-cased ALL-CAPS name range resolves in the original string")
    func testTitleCasedNameRangeInOriginal() {
        // Faithfully reproduces the Pass-2 call: the tagger runs on the
        // title-cased string while ranges must index the raw original. The
        // leading run of spaces collapses under title-casing, so a cross-string
        // NSRange shifts every box left (the red state pre-fix).
        let raw = "  JOHN SMITH attended"
        let titleCased = PIIDetector.titleCaseAllCapsWords(raw)
        let detector = PIIDetector()

        // strict:false → no gazetteer-dependent suppression, so the result set
        // is stable whether or not the name bloom is bundled in the test target.
        // The range fix runs identically for both strictness modes.
        let matches = detector._testRunNLTagger(on: titleCased, original: raw, strict: false)
        let nameMatches = matches.filter { $0.kind == .name }

        // NLTagger reliably tags "John" / "Smith"; require at least one so the
        // per-match assertion below is not vacuous.
        #expect(!nameMatches.isEmpty)

        let originalNS = raw as NSString
        for match in nameMatches {
            guard match.range.location != NSNotFound,
                  NSMaxRange(match.range) <= originalNS.length else {
                Issue.record("name range out of bounds: \(match.range) in length \(originalNS.length)")
                continue
            }
            // The box must cover exactly the matched text within the original
            // (case-insensitive: the original is ALL-CAPS, the tag is title-cased).
            let box = originalNS.substring(with: match.range)
            #expect(box.lowercased() == match.text.lowercased())
        }
    }

    @Test("Legal-prefix name range accounts for the punctuation trim")
    func testLegalPrefixNameRangeWithPunctuation() {
        // "Patient: Maria Johnson" — pre-fix the range started at the colon
        // (": Maria Johns"); post-fix it covers "Maria Johnson".
        let text = "Patient: Maria Johnson"
        let detector = PIIDetector()

        let matches = detector._testScanLegalPrefixes(in: text)
        let nameMatch = matches.first { $0.text == "Maria Johnson" }

        #expect(nameMatch != nil)
        if let match = nameMatch {
            let box = (text as NSString).substring(with: match.range)
            #expect(box == "Maria Johnson")
        }
    }
}
