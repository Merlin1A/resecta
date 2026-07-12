import Testing
import Foundation
@testable import RedactionEngine

private final class CalibrationFixtureBundle: NSObject {}

// Phase 3b calibration input producer.
//
// Iterates the bundled G8 corpus and writes `softmax_dump.json` at the path
// given by `RESECTA_CALIBRATION_OUT_SOFTMAX` (default
// `build/calibration/softmax_dump.json`; point it at the resecta-datapipeline
// build/calibration directory). The file is then consumed by
// `make calibrate-temperature` to fit the doctype softmax temperature.
// Schema: resecta-datapipeline/schemas/doctype_softmax_dump.schema.json.
//
// Gated on g8_corpus.json being bundled via `make install-assets` (or a
// matching manual copy). When the fixture is absent the suite exits cleanly
// so the general test run is not blocked.

@Suite("Doctype softmax dump (Phase 3b calibration input)")
struct DoctypeSoftmaxDumpTests {

    struct G8Corpus: Decodable, Sendable {
        let seed: Int
        let documents: [Document]
    }

    struct Document: Decodable, Sendable {
        let id: String
        let text: String
    }

    struct DumpDocument: Encodable, Sendable {
        let doc_id: String
        let logits: [Double]
    }

    struct SoftmaxDump: Encodable, Sendable {
        let version: Int
        let generated_by: String
        let g8_corpus_seed: Int
        let classes: [String]
        let documents: [DumpDocument]
    }

    @Test("Emit softmax_dump.json from the G8 corpus")
    func emitSoftmaxDump() async throws {
        guard let corpus = try loadCorpus() else {
            print("[softmax dump gate] g8_corpus.json not bundled; skipping")
            return
        }

        let classifier = DocumentTypeClassifier()
        let sortedDocs = corpus.documents.sorted { $0.id < $1.id }

        var dumpDocs: [DumpDocument] = []
        dumpDocs.reserveCapacity(sortedDocs.count)
        for doc in sortedDocs {
            let logits = await classifier.rawLogits(pageText: doc.text)
            #expect(logits.count == 5,
                    "rawLogits must return 5 values; got \(logits.count) for \(doc.id)")
            dumpDocs.append(DumpDocument(doc_id: doc.id, logits: logits))
        }

        let dump = SoftmaxDump(
            version: 1,
            generated_by: "RedactionEngineTests.DoctypeSoftmaxDumpTests",
            g8_corpus_seed: corpus.seed,
            classes: DoctypeClass.canonicalOrder.map(\.rawValue),
            documents: dumpDocs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(dump)

        // Attachment captures the dump into the .xcresult bundle when run on a
        // device where the test sandbox blocks writes outside Documents. The
        // FileManager write is kept best-effort so macOS/Catalyst runs still
        // produce the file at the env-overridden path.
        Attachment.record(data, named: "softmax_dump.json")

        let outputURL = Self.outputURL()
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: outputURL, options: .atomic)
        print("[softmax dump] emitted \(dumpDocs.count) documents (attachment: softmax_dump.json)")
    }

    // MARK: - Support

    private func loadCorpus() throws -> G8Corpus? {
        guard let url = Bundle(for: CalibrationFixtureBundle.self).url(
            forResource: "g8_corpus",
            withExtension: "json"
        ) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(G8Corpus.self, from: data)
    }

    private static func outputURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["RESECTA_CALIBRATION_OUT_SOFTMAX"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath:
            "build/calibration/softmax_dump.json")
    }
}
