import Foundation
import Testing
@testable import RedactionEngine

// S4-X5 — the corpus INPUT dump (a standing emitter beside the H2.2 runner).
//
// The coordinator-parity emitter (C12-123) lives in the APP test target,
// which can reach neither this target's fixture factories (`RawPDFBuilder`
// / `TestFixtures`) nor its bundled `TestResources`. This test writes every
// H2.2 input document to disk by doc id so the app emitter can load the
// SAME bytes the mirror redacted; the app emitter asserts each file's
// SHA-256 against the H2.2 cell's `regions.json.doc_sha256`.
//
// MEASUREMENT HARNESS: env-gated (RESECTA_INPUT_DUMP_OUT / RESECTA_DOCS_ROOT,
// plus the TEST_RUNNER_-prefixed forms xcodebuild forwards). Never in the
// batched gate. All fixtures are synthetic with public values manifests.

@Suite("Corpus input dump (standing emitter)", .serialized)
struct CorpusInputDumpTests {

    static func dumpOut() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["RESECTA_INPUT_DUMP_OUT"], !p.isEmpty { return p }
        if let p = env["TEST_RUNNER_RESECTA_INPUT_DUMP_OUT"], !p.isEmpty { return p }
        return nil
    }

    struct DumpSummary: Encodable {
        let schema_version: Int
        let generated_by: String
        /// doc id → SHA-256 of the written bytes.
        let docs: [String: String]
        let skipped: [String: String]
    }

    @Test("Dump every H2.2 input document by doc id")
    func dumpCorpusInputs() async throws {
        guard let out = Self.dumpOut() else {
            TestGate.skip("RESECTA_INPUT_DUMP_OUT unset — the corpus input dump was not requested")
            return
        }
        let root = VerificationCorpusRunnerTests.docsRoot()
        try FileManager.default.createDirectory(
            atPath: out, withIntermediateDirectories: true)
        var docs: [String: String] = [:]
        var skipped: [String: String] = [:]

        func write(_ id: String, _ data: Data) throws {
            try data.write(to: URL(fileURLWithPath: "\(out)/\(id).pdf"), options: .atomic)
            docs[id] = VerificationCorpusRunnerTests.sha256Hex(data)
        }

        // A. Manifest rows with drawable GT — resolved exactly as the H2.2
        // runner resolves them (bundled → the test bundle; external → the
        // DOCS_ROOT), with the same manifest pin check.
        for row in try VerificationCorpusRunnerTests.loadManifest()
        where row.path.hasSuffix(".pdf") && row.gt != nil {
            guard let url = VerificationCorpusRunnerTests.resolve(row, root: root),
                  let data = try? Data(contentsOf: url) else {
                skipped[row.id] = row.source == "external"
                    ? "RESECTA_DOCS_ROOT unset or file missing" : "bundle resource missing"
                continue
            }
            let hex = VerificationCorpusRunnerTests.sha256Hex(data)
            #expect(hex == row.sha256, "\(row.id): loaded bytes drift from the manifest pin")
            try write(row.id, data)
        }

        // B. The statement · C. the fill-hallucination artifact (verify-only cell).
        if let stmt = try? TestFixtures.sampleStatementPDF() {
            try write("sample-bank-statement", stmt)
        } else {
            skipped["sample-bank-statement"] = "bundle resource missing"
        }
        if let fh = try? TestFixtures.fillHallucinationRedactedPDF() {
            try write("secureraster-fill-hallucination", fh)
        } else {
            skipped["secureraster-fill-hallucination"] = "bundle resource missing"
        }

        // D. The RawPDFBuilder factory set + D2. the compat-residue cell.
        for input in VerificationCorpusRunnerTests.factoryInputs()
            + VerificationCorpusRunnerTests.compatResidueInputs() {
            try write(input.docId, input.data)
        }

        try VerificationCorpusRunnerTests.writeJSON(
            DumpSummary(
                schema_version: 1,
                generated_by: "CorpusInputDumpTests.dumpCorpusInputs",
                docs: docs,
                skipped: skipped),
            to: "\(out)/dump-summary.json")
        print("[DUMP] done: \(docs.count) documents -> \(out); skipped: \(skipped.count)")
    }
}
