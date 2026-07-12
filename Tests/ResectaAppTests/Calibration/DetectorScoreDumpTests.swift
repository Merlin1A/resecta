import Testing
import Foundation
@testable import RedactionEngine

private final class CalibrationFixtureBundle: NSObject {}

// Phase 3b calibration input producer.
//
// Iterates the bundled G8 corpus, runs the full PIIDetector over each
// document (no doctype gating, so all eight canonical calibration
// categories can emit candidates), maps each PIIMatch to its canonical
// wire name, and writes `detector_score_dump.json` at the path given by
// `RESECTA_CALIBRATION_OUT_DETECTORS` (default
// `build/calibration/detector_score_dump.json`; point it at the
// resecta-datapipeline build/calibration directory).
//
// Consumed by `make calibrate-sweep`. Schema:
// resecta-datapipeline/schemas/detector_score_dump.schema.json.
//
// `doctype_prior_applied` is left unset (= false): Python performs A7
// posterior composition during the sweep.

@Suite("Detector score dump (Phase 3b calibration input)")
struct DetectorScoreDumpTests {

    struct G8Corpus: Decodable, Sendable {
        let seed: Int
        let documents: [Document]
    }

    struct Document: Decodable, Sendable {
        let id: String
        let text: String
    }

    struct DumpCandidate: Encodable, Sendable {
        let category: String
        let start: Int
        let end: Int
        let raw_score: Double
    }

    struct DumpDocument: Encodable, Sendable {
        let doc_id: String
        let candidates: [DumpCandidate]
    }

    struct DetectorScoreDump: Encodable, Sendable {
        let version: Int
        let generated_by: String
        let g8_corpus_seed: Int
        let categories: [String]
        let documents: [DumpDocument]
    }

    private static let canonicalCategories: [String] = [
        // Order matches the pipeline's sweep_thresholds._CATEGORIES (the
        // loader hard-fails on exact-order mismatch). routingNumber added
        // in search-impl S2 (design 01 §4) — the S4 re-dump carries it.
        "ssn", "npi", "dea", "dob", "address", "account", "mrn", "name",
        "routingNumber",
    ]

    @Test("Emit detector_score_dump.json from the G8 corpus")
    func emitDetectorScoreDump() async throws {
        guard let corpus = try loadCorpus() else {
            print("[detector score dump gate] g8_corpus.json not bundled; skipping")
            return
        }

        let detector = PIIDetector()
        let sortedDocs = corpus.documents.sorted { $0.id < $1.id }

        var dumpDocs: [DumpDocument] = []
        dumpDocs.reserveCapacity(sortedDocs.count)
        for doc in sortedDocs {
            let matches = await detector.detect(in: doc.text, doctype: nil)
            var candidates: [DumpCandidate] = []
            candidates.reserveCapacity(matches.count)
            for match in matches {
                guard let category = Self.canonicalCategory(for: match.kind) else {
                    continue
                }
                let start = match.range.location
                let end = match.range.location + match.range.length
                let clampedScore = max(0.0, min(1.0, match.confidence))
                candidates.append(DumpCandidate(
                    category: category,
                    start: start,
                    end: end,
                    raw_score: clampedScore
                ))
            }
            candidates.sort { lhs, rhs in
                if lhs.category != rhs.category { return lhs.category < rhs.category }
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.end < rhs.end
            }
            dumpDocs.append(DumpDocument(doc_id: doc.id, candidates: candidates))
        }

        let dump = DetectorScoreDump(
            version: 1,
            generated_by: "RedactionEngineTests.DetectorScoreDumpTests",
            g8_corpus_seed: corpus.seed,
            categories: Self.canonicalCategories,
            documents: dumpDocs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(dump)

        // Attachment captures the dump into the .xcresult bundle when run on a
        // device where the test sandbox blocks writes outside Documents. The
        // FileManager write is kept best-effort so macOS/Catalyst runs still
        // produce the file at the env-overridden path.
        Attachment.record(data, named: "detector_score_dump.json")

        let outputURL = Self.outputURL()
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: outputURL, options: .atomic)

        let total = dumpDocs.reduce(0) { $0 + $1.candidates.count }
        print("[detector score dump] emitted \(dumpDocs.count) documents, \(total) candidates (attachment: detector_score_dump.json)")
    }

    // MARK: - Support

    private static func canonicalCategory(for kind: RedactionRegion.PIIKind) -> String? {
        switch kind {
        case .ssn:           return "ssn"
        case .npi:           return "npi"
        case .dea:           return "dea"
        case .dateOfBirth:   return "dob"
        case .address:       return "address"
        case .account:       return "account"
        case .routingNumber: return "routingNumber"
        case .medicalRecord: return "mrn"
        case .name:          return "name"
        case .creditCard, .email, .phone, .ein, .itin,
             .driversLicense, .passport,
             .licensePlate, .barcode, .signatureCandidate, .other:
            // .barcode (DRAW-2) is detected by Vision; .signatureCandidate
            // (DRAW-3) is a heuristic visual detector — neither is on the
            // calibration path; same shape as `.other`.
            return nil
        }
    }

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
        if let override = env["RESECTA_CALIBRATION_OUT_DETECTORS"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath:
            "build/calibration/detector_score_dump.json")
    }
}
