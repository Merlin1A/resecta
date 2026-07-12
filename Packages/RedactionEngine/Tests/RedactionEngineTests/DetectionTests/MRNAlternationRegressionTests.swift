import Testing
import Foundation
@testable import RedactionEngine

// W10 — `MRNAlternationRegressionTests`. Ensures the three-pattern MRN
// rewrite (mrnPatternLabeled / mrnPatternPatientID / mrnPatternInstitution)
// does not drop any hit the pre-W10 single alternation regex produced on
// the G8 medical corpus, AND recalls the corpus's ground-truth MRN spans.
//
// The pre-W10 pattern is re-created inline below so the test stays
// self-contained after the detector-level source is rewritten.

@Suite("MRN alternation regression (G8 medical)")
struct MRNAlternationRegressionTests {

    /// The pre-W10 MRN regex — required a numeric-only identifier (4–12 digits)
    /// after one of the fixed labels. The W10 rewrite accepts alphanumerics
    /// and adds an institution-prefix pattern.
    private static let oldAlternation: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?:MRN|Medical\s+Record|Patient\s+ID|Medical\s+ID)\s*[#:]?\s*(\d{4,12})"#,
            options: [.caseInsensitive]
        )
    }()

    /// Any old-alternation hit whose label+value matches an item here is
    /// treated as an intentional exception (documented drop). Empty today —
    /// the W10 rewrite is a strict superset on the G8 medical slice.
    private static let intentionalExceptions: [String] = []

    private struct CorpusDoc: Decodable {
        let id: String
        let doctype: String
        let text: String
        let piiSpans: [Span]
        enum CodingKeys: String, CodingKey {
            case id, doctype, text
            case piiSpans = "pii_spans"
        }
    }

    private struct Span: Decodable {
        let category: String
        let start: Int
        let end: Int
        let value: String
    }

    private struct Corpus: Decodable {
        let documents: [CorpusDoc]
    }

    private func loadMedicalDocs() throws -> [CorpusDoc]? {
        guard let url = Bundle.module.url(
            forResource: "g8_corpus",
            withExtension: "json",
            subdirectory: "corpus"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        return corpus.documents.filter { $0.doctype == "medical" }
    }

    @Test("W10 three-pattern set is a superset of the pre-W10 alternation")
    func noRegressionOnOldAlternation() throws {
        guard let medical = try loadMedicalDocs() else {
            print("[MRN regression] g8_corpus.json not bundled; skipping.")
            return
        }
        #expect(!medical.isEmpty, "G8 medical slice must be non-empty")

        let detector = PIIDetector()
        var lostExamples: [String] = []

        for doc in medical {
            let ns = doc.text as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            let oldMatches = Self.oldAlternation.matches(in: doc.text, range: fullRange)

            // Collect the new set's ranges once per doc.
            let newMatches = detector.detectMedicalRecords(in: ns, range: fullRange)

            for old in oldMatches {
                let covered = newMatches.contains { new in
                    new.range.location <= old.range.location
                        && NSMaxRange(new.range) >= NSMaxRange(old.range)
                }
                if !covered {
                    let snippet = ns.substring(with: old.range)
                    let inExceptions = Self.intentionalExceptions.contains(snippet)
                    if !inExceptions {
                        lostExamples.append(snippet)
                    }
                }
            }
        }

        let lostSample = lostExamples.prefix(10).joined(separator: "; ")
        #expect(lostExamples.isEmpty,
                "W10 MRN rewrite dropped old-alternation hits not in intentionalExceptions: \(lostSample)")
    }

    @Test("W10 three-pattern set recalls every G8 medical ground-truth MRN span")
    func groundTruthRecall() throws {
        guard let medical = try loadMedicalDocs() else { return }
        let detector = PIIDetector()
        var misses: [String] = []

        for doc in medical {
            let ns = doc.text as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            let newMatches = detector.detectMedicalRecords(in: ns, range: fullRange)

            for span in doc.piiSpans where span.category == "mrn" {
                let expected = NSRange(location: span.start, length: span.end - span.start)
                let hit = newMatches.contains { NSIntersectionRange($0.range, expected).length == expected.length }
                if !hit {
                    misses.append("\(doc.id): '\(span.value)' @\(span.start)..\(span.end)")
                }
            }
        }

        // G8 medical ground-truth MRNs are generated with the institution-prefix
        // or labeled shapes supported by the rewrite. Missing any of them is a
        // real regression.
        let missSample = misses.prefix(10).joined(separator: "\n  ")
        #expect(misses.isEmpty,
                "W10 MRN rewrite missed ground-truth spans:\n  \(missSample)")
    }
}
