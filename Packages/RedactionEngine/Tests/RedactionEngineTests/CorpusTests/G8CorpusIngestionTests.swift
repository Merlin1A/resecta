import Testing
import Foundation
@testable import RedactionEngine

// This suite decodes "Fixtures/corpus/g8_corpus.json" against the schema at
// DataPipeline/schemas/g8_corpus.schema.json and validates counts.
//
// Gated on fixture presence. Skipped cleanly when the maintainer has not yet run
// `DataPipeline/make install-assets` to drop g8_corpus.json into the
// test bundle.

@Suite("G8 corpus ingestion (Phase 2)")
struct G8CorpusIngestionTests {

    /// Wire format matching `DataPipeline/schemas/g8_corpus.schema.json`.
    struct G8Corpus: Decodable, Sendable {
        let version: Int
        let generated_by: String
        let seed: Int
        let counts_by_doctype: CountsByDoctype
        let counts_by_demographic: CountsByDemographic
        let demographic_labels: [String]
        let documents: [Document]
    }

    struct CountsByDoctype: Decodable, Sendable {
        let court: Int
        let medical: Int
        let financial: Int
        let foia: Int
        let generic: Int
    }

    struct CountsByDemographic: Decodable, Sendable {
        let white: Int?
        let black: Int?
        let hispanic: Int?
        let asian: Int?
        let ai_an: Int?
        let unlabeled: Int?
    }

    struct Document: Decodable, Sendable {
        let id: String
        let doctype: String
        let demographic_bucket: String
        let text: String
        let pii_spans: [PIISpan]
    }

    struct PIISpan: Decodable, Sendable {
        let category: String
        let start: Int
        let end: Int
        let value: String
        // 1.2 P1.10 (C12-25): the packet-tier bridge written by the dp
        // generator (must / should / watch / must_not). Optional so the
        // decoder also reads a pre-extension corpus.
        let tier: String?
    }

    static let allowedTiers: Set<String> = ["must", "should", "watch", "must_not"]

    // MARK: - Tests

    @Test("Corpus decodes and counts match plan (gated on fixture presence)")
    func corpusDecodes() throws {
        let corpus = try loadCorpus()
        guard let corpus else {
            print("[G8 gate] g8_corpus.json not bundled; test skipped until `make install-assets` runs.")
            return
        }

        // Counts: 1 100 documents split 300/250/300/150/100 — financial grew
        // 200 → 300 with the W-2 (`financial_tax`) sub-template third.
        #expect(corpus.counts_by_doctype.court == 300)
        #expect(corpus.counts_by_doctype.medical == 250)
        #expect(corpus.counts_by_doctype.financial == 300)
        #expect(corpus.counts_by_doctype.foia == 150)
        #expect(corpus.counts_by_doctype.generic == 100)

        // Sum sequentially. Swift 6.2 (Xcode 26.3 CI) times out type-checking
        // a single 6-term chain of `?? 0` over heterogeneous Optional<Int>s.
        var demographicSum = 0
        demographicSum += corpus.counts_by_demographic.white ?? 0
        demographicSum += corpus.counts_by_demographic.black ?? 0
        demographicSum += corpus.counts_by_demographic.hispanic ?? 0
        demographicSum += corpus.counts_by_demographic.asian ?? 0
        demographicSum += corpus.counts_by_demographic.ai_an ?? 0
        demographicSum += corpus.counts_by_demographic.unlabeled ?? 0
        #expect(demographicSum == 1100)

        #expect(corpus.seed == 20260416)
        #expect(corpus.documents.count == 1100)
    }

    @Test("Every document has well-formed PII spans (gated on fixture presence)")
    func allSpansWellFormed() throws {
        let corpus = try loadCorpus()
        guard let corpus else { return }

        // 17/17 since 1.2 T1.1 (C12-25): itin / creditCard / driversLicense /
        // passport / licensePlate joined the original twelve.
        let allowedCategories: Set<String> = [
            "ssn", "npi", "dea", "dob", "address", "account",
            "mrn", "name", "phone", "email", "routingNumber", "ein",
            "itin", "creditCard", "driversLicense", "passport", "licensePlate",
        ]
        let allowedDoctypes: Set<String> = [
            "court", "medical", "financial", "foia", "generic",
        ]

        var seenCategories: Set<String> = []
        for doc in corpus.documents {
            #expect(allowedDoctypes.contains(doc.doctype), "unknown doctype in \(doc.id)")
            #expect(!doc.pii_spans.isEmpty, "\(doc.id) has no PII spans")
            for span in doc.pii_spans {
                #expect(allowedCategories.contains(span.category),
                        "unknown category \(span.category) in \(doc.id)")
                #expect(span.start >= 0)
                #expect(span.end > span.start)
                #expect(span.end <= doc.text.count)
                #expect(!span.value.isEmpty)
                if let tier = span.tier {
                    #expect(Self.allowedTiers.contains(tier),
                            "unknown tier \(tier) in \(doc.id)")
                }
                seenCategories.insert(span.category)
            }
        }
        // The bundled corpus is the 17/17 one (1.2 T1.1); a 12/17 fixture
        // would silently under-measure the five added categories.
        #expect(seenCategories == allowedCategories,
                "corpus categories \(seenCategories.sorted()) != the 17-category set")
    }

    // 1.2 C12-95: the test-target override the G8 emitters honour (a generator
    // PROFILE the datapipeline built, read from build/ and never installed)
    // must load the very bytes the invoking target announced. Gated on the
    // override: without it this test has nothing to check and passes quietly.
    @Test("Corpus path override loads the announced file (gated on the override)")
    func overrideLoadsAnnouncedFile() throws {
        guard let (url, overridden) = G8BaselineHarnessTests.baselineCorpusURL(),
              overridden else {
            return
        }
        let data = try Data(contentsOf: url)
        G8BaselineHarnessTests.expectAnnouncedCorpusSHA(data)
        let corpus = try JSONDecoder().decode(G8Corpus.self, from: data)
        // A profile is the same 1,100 documents (same seed, same counts) with
        // its name slots re-rendered and/or furniture planted.
        #expect(corpus.seed == 20260416)
        #expect(corpus.documents.count == 1100)
    }

    // MARK: - Loader (the bundled fixture, or the RESECTA_G8_CORPUS_PATH
    // override the emitters honour — resolved by the one shared function)

    private func loadCorpus() throws -> G8Corpus? {
        guard let (url, _) = G8BaselineHarnessTests.baselineCorpusURL() else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(G8Corpus.self, from: data)
    }
}
