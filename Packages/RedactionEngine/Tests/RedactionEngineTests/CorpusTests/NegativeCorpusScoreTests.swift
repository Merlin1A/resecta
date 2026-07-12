import Testing
import Foundation
@testable import RedactionEngine

// S3 baseline — negative-corpus document-level false-positive emitter.
//
// Pinned by the negative-corpus evaluation contract (File 4).
// Scores the deterministic no-PII negative corpus through the SAME
// PIIDetector.detect path the baseline harness uses. The corpus is all-negative
// (no spans), so ANY surfaced detection on ANY document is a false positive.
//
// The fixture (Fixtures/corpus/negative_corpus.json) is produced by the Python
// generator (resecta_data.corpus.negative.generate) and dropped into the test
// bundle by `make install-assets`. When it is absent this test prints a skip
// note and returns — it is an emitter, not a gate.
//
// "Surfaced" uses the SAME balanced-cutoff helper (balancedCutoff(for:)) as the
// G8 baseline so the FP definition is consistent across both files. Output is
// keyed by category only (CONTRACT File 4) and carries counts + token-rate
// derivations — no document text, no values (ARCH §12.2).

@Suite("S3 negative-corpus FP (standing emitter)", .serialized)
struct NegativeCorpusScoreTests {

    // MARK: - Fixture wire format (CONTRACT "Negative corpus fixture format")

    struct NegativeCorpus: Decodable, Sendable {
        let version: Int
        let generated_by: String?
        let seed: Int?
        let documents: [NegativeCorpusDoc]
    }

    struct NegativeCorpusDoc: Decodable, Sendable {
        let id: String
        let doctype: String
        let text: String
    }

    // MARK: - Output JSON (CONTRACT File 4)

    struct NegCorpusReport: Encodable, Sendable {
        let schema_version: Int
        let corpus_id: String
        let doc_count: Int
        let total_tokens: Int
        let false_positives_by_category: [String: Int]
        let docs_with_any_fp: Int
        let fp_per_doc: Double
        let fp_per_1k_tokens: Double
    }

    // MARK: - Loader (Bundle.module Fixtures/corpus/negative_corpus.json)

    static func loadNegativeCorpus() throws -> NegativeCorpus? {
        guard let url = Bundle.module.url(
            forResource: "negative_corpus",
            withExtension: "json",
            subdirectory: "corpus"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(NegativeCorpus.self, from: data)
    }

    // MARK: - The emit

    @Test("Emit negative-corpus document FP counts")
    func scoreNegativeCorpus() async throws {
        guard let corpus = try Self.loadNegativeCorpus() else {
            print("[S3 negcorpus] negative_corpus.json not bundled; emit skipped " +
                  "until the Python generator + install-assets run.")
            return
        }

        let detector = PIIDetector()
        let sortedDocs = corpus.documents.sorted { $0.id < $1.id }

        var fpByCategory: [String: Int] = [:]
        var docsWithAnyFP = 0
        var totalFP = 0
        var totalTokens = 0

        for doc in sortedDocs {
            // Whitespace-split token estimate (CONTRACT: total_tokens ≈ whitespace
            // splits). Counts only, never the tokens themselves.
            totalTokens += doc.text.split(whereSeparator: { $0.isWhitespace }).count

            let doctype = gateDoctypeClass(doc.doctype) ?? .generic
            let matches = await detector.detect(in: doc.text, doctype: doctype)

            var docHadFP = false
            for match in matches {
                // Surfaced = clears the balanced cutoff (or nil cutoff → unfiltered).
                let cutoff = balancedCutoff(for: match.kind)
                let surfaced = cutoff.map { match.confidence >= $0 } ?? true
                guard surfaced else { continue }
                guard let catKey = G8BaselineHarnessTests.cellCategoryKey(for: match.kind)
                else { continue }
                // All-negative corpus: every surfaced detection is a false positive.
                fpByCategory[catKey, default: 0] += 1
                totalFP += 1
                docHadFP = true
            }
            if docHadFP { docsWithAnyFP += 1 }
        }

        let docCount = sortedDocs.count
        let fpPerDoc = docCount > 0 ? Double(totalFP) / Double(docCount) : 0
        let fpPer1k = totalTokens > 0 ? Double(totalFP) / Double(totalTokens) * 1000.0 : 0

        let report = NegCorpusReport(
            schema_version: 1,
            corpus_id: "negative_corpus.v1",
            doc_count: docCount,
            total_tokens: totalTokens,
            false_positives_by_category: fpByCategory,
            docs_with_any_fp: docsWithAnyFP,
            fp_per_doc: fpPerDoc,
            fp_per_1k_tokens: fpPer1k
        )

        let base = G8BaselineHarnessTests.baselineOutBase()
        try G8BaselineHarnessTests.writeJSON(report, to: "\(base)_negcorpus.json")

        print("[S3 negcorpus] → \(base)_negcorpus.json " +
              "(docs=\(docCount) tokens=\(totalTokens) fp=\(totalFP) " +
              "docsWithFP=\(docsWithAnyFP))")

        // Emitter sanity only.
        #expect(docCount > 0, "negative corpus bundled but contained no documents")
    }
}
