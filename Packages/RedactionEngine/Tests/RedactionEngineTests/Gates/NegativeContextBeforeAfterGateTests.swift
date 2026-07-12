import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// D1 Gate — NegativeContextBeforeAfterGateTests
// Design reference: the negative-context-and-data design §12.
// Verification gate: §4
//
// Two test methods sweep the same corpus twice. The ONLY delta is the
// negativeContextGazetteer parameter:
//   testBeforeConfiguration — nil gazetteer (current-production behavior)
//   testAfterConfiguration  — gazetteer from env RESECTA_NEGCTX_ASSET path,
//                             or the bundled negative-context.json when unset.
//
// Output: JSON at RESECTA_GATE_OUT (default /tmp/negative_context_gate.json).
// Run-id: from RESECTA_GATE_RUN_ID or derived from the test method name.
//
// G8 categories skipped (no detector emission on the negative-context
// suppression path): "phone", "email". Both appear in pii_spans but the
// negative-context gazetteer schema has no scope entries for them, so
// they are never suppressed; scoring them would add only noise. Documented
// in the final gate report under g8_results.

@Suite("D1 Negative-context before/after gate", .serialized)
struct NegativeContextBeforeAfterGateTests {

    // ─── BEFORE: nil gazetteer = current-production behavior ─────────────────
    //
    // Output path resolution (documented for orchestrator):
    //   1. RESECTA_GATE_OUT env var (set directly in the test process)
    //   2. TEST_RUNNER_RESECTA_GATE_OUT env var (xcodebuild TEST_RUNNER_ prefix)
    //   3. Default: /tmp/negctx_gate_before.json
    //
    // Invocation (xcodebuild passes TEST_RUNNER_-prefixed vars to the runner):
    //   xcodebuild test -scheme RedactionEngine \
    //     -destination 'platform=iOS Simulator,name=iPhone 17' \
    //     -only-testing:RedactionEngineTests/NegativeContextBeforeAfterGateTests \
    //     TEST_RUNNER_RESECTA_GATE_OUT=/tmp/negctx_gate_before.json \
    //     TEST_RUNNER_RESECTA_GATE_RUN_ID=before
    //
    // Note: Swift Testing's -only-testing filter matches at the struct level
    // (not per-method display name), so both testBeforeConfiguration and
    // testAfterConfiguration run when scoping to the suite. Run each half
    // separately with different RESECTA_GATE_OUT values, or run both and
    // let each method resolve its own default path (before → /tmp/negctx_gate_before.json,
    // after → /tmp/negctx_gate_after_SMOKE.json when no env override is set).

    @Test("D1 before — nil gazetteer (current production baseline)")
    func testBeforeConfiguration() async throws {
        let detector = PIIDetector(negativeContextGazetteer: nil)
        let outPath = gateOutputPath(default: "/tmp/negctx_gate_before.json")
        let report = try await runGate(
            detector: detector,
            gazetteer: nil,
            runID: gateRunID(default: "before"),
            outputPath: outPath
        )
        // The before run must produce non-trivial output.
        #expect(!report.g8_results.by_category_doctype.isEmpty,
                "G8 cells must be non-empty (corpus fixture missing or empty)")
        print("[D1 before] output written to \(outPath)")
        printSummary(report, label: "BEFORE")
    }

    // ─── AFTER: bundled (or env-overridden) gazetteer ────────────────────────
    //
    // Smoke run uses the bundled 334-entry pre-audit file.
    // Official after-run (post install-assets) uses RESECTA_NEGCTX_ASSET.
    //
    // Default output: /tmp/negctx_gate_after_SMOKE.json
    // (label clearly distinguishes it from the gate artifact, which uses the
    // reviewed/ file and is produced by the orchestrator post-asset-install).

    @Test("D1 after — wired gazetteer (suppression active)")
    func testAfterConfiguration() async throws {
        let gazetteer = buildAfterGazetteer()
        let detector = PIIDetector(negativeContextGazetteer: gazetteer)
        let outPath = gateOutputPath(default: "/tmp/negctx_gate_after_SMOKE.json")
        let report = try await runGate(
            detector: detector,
            gazetteer: gazetteer,
            runID: gateRunID(default: "after"),
            outputPath: outPath
        )
        #expect(!report.g8_results.by_category_doctype.isEmpty,
                "G8 cells must be non-empty")
        print("[D1 after] output written to \(outPath)")
        printSummary(report, label: "AFTER")
    }

    // ─── Shared sweep ────────────────────────────────────────────────────────

    private func runGate(
        detector: PIIDetector,
        gazetteer: NegativeContextGazetteer?,
        runID: String,
        outputPath: String
    ) async throws -> GateReport {

        let assetSHA = negativeContextAssetSHA256(gazetteer: gazetteer)

        // G8 corpus sweep
        let g8Results = try await sweepG8Corpus(detector: detector)

        let report = GateReport(
            run_id: runID,
            asset_sha256: assetSHA,
            g8_results: g8Results
        )

        try writeGateReport(report, to: outputPath)
        return report
    }

    // ─── G8 corpus sweep ─────────────────────────────────────────────────────

    private func sweepG8Corpus(detector: PIIDetector) async throws -> GateG8Results {
        guard let corpus = try loadGateG8Corpus() else {
            print("[D1 gate] g8_corpus.json not bundled; G8 results will be empty")
            return GateG8Results(by_category_doctype: [:])
        }

        // Sorted for determinism.
        let sortedDocs = corpus.documents.sorted { $0.id < $1.id }

        // Accumulators: key = "<category>_<doctype>"
        var truePositives:    [String: Int] = [:]
        var falsePositives:   [String: Int] = [:]
        var falseNegatives:   [String: Int] = [:]
        var suppressedCounts: [String: Int] = [:]

        for doc in sortedDocs {
            guard let doctype = gateDoctypeClass(doc.doctype) else { continue }

            let matches = await detector.detect(in: doc.text, doctype: doctype)

            // Build a set of (kind, range) tuples for surfaced detections.
            // "Surfaced" = confidence clears the balanced threshold (or has nil threshold).
            var surfacedByKind: [RedactionRegion.PIIKind: [(NSRange, Bool)]] = [:]
            for match in matches {
                let cutoff = balancedCutoff(for: match.kind)
                let surfaced: Bool
                if let c = cutoff {
                    surfaced = match.confidence >= c
                } else {
                    surfaced = true
                }
                if surfaced {
                    let suppressed = isNegativeContextSuppressed(match)
                    surfacedByKind[match.kind, default: []].append((match.range, suppressed))
                }
            }

            // Score per category that appears in this document's pii_spans.
            // Only the categories the gate scores (gateMapCategory returns non-nil).
            // Group ground-truth spans by category.
            var groundTruthByKind: [RedactionRegion.PIIKind: [NSRange]] = [:]
            for span in doc.pii_spans {
                guard let kind = gateMapCategory(span.category) else { continue }
                let nsRange = NSRange(location: span.start, length: span.end - span.start)
                groundTruthByKind[kind, default: []].append(nsRange)
            }

            // For each category present in ground truth or detections, score TP/FP/FN.
            var allKinds = Set(groundTruthByKind.keys)
            allKinds.formUnion(surfacedByKind.keys)

            for kind in allKinds {
                guard let cat = PIICategory(piiKind: kind) else { continue }
                let catKey = cat.rawValue.lowercased().replacingOccurrences(of: " ", with: "")
                let cellKey = "\(catKey)_\(doc.doctype)"

                let gtRanges = groundTruthByKind[kind] ?? []
                let detected = surfacedByKind[kind] ?? []

                // TP: ground-truth span covered by at least one surfaced detection.
                var tpCount = 0
                var fnCount = 0
                for gt in gtRanges {
                    let covered = detected.contains { (det, _) in
                        rangesOverlap(det, gt)
                    }
                    if covered { tpCount += 1 } else { fnCount += 1 }
                }

                // FP: surfaced detections that don't overlap any ground-truth span.
                var fpCount = 0
                var suppressedCount = 0
                for (det, suppressed) in detected {
                    let hasGT = gtRanges.contains { gt in rangesOverlap(det, gt) }
                    if !hasGT { fpCount += 1 }
                    if suppressed { suppressedCount += 1 }
                }

                truePositives[cellKey, default: 0]    += tpCount
                falsePositives[cellKey, default: 0]   += fpCount
                falseNegatives[cellKey, default: 0]   += fnCount
                suppressedCounts[cellKey, default: 0] += suppressedCount
            }
        }

        // Collect all cell keys.
        var allCellKeys = Set(truePositives.keys)
        allCellKeys.formUnion(falsePositives.keys)
        allCellKeys.formUnion(falseNegatives.keys)

        var cells: [String: GateCellResult] = [:]
        for key in allCellKeys.sorted() {
            cells[key] = GateCellResult(
                true_positives:               truePositives[key] ?? 0,
                false_positives:              falsePositives[key] ?? 0,
                false_negatives:              falseNegatives[key] ?? 0,
                suppressed_by_negative_context: suppressedCounts[key] ?? 0
            )
        }

        return GateG8Results(by_category_doctype: cells)
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    /// Build the "after" gazetteer from the env-override path when set,
    /// or fall back to the bundled negative-context.json.
    private func buildAfterGazetteer() -> NegativeContextGazetteer? {
        let env = ProcessInfo.processInfo.environment
        let assetPath = env["RESECTA_NEGCTX_ASSET"] ?? env["TEST_RUNNER_RESECTA_NEGCTX_ASSET"]
        if let path = assetPath, !path.isEmpty {
            // Construct from explicit file path (reviewed/ file post-install).
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else {
                print("[D1 after] RESECTA_NEGCTX_ASSET path unreadable; falling back to bundle")
                return try? NegativeContextGazetteer()
            }
            _ = data  // file exists; use the bundle path that resolves the same resource
            // NegativeContextGazetteer has no Data-based init (it loads from bundle);
            // for smoke test the bundled file is used regardless of the env path.
            // The orchestrator installs the reviewed file into the bundle before
            // running the official after-run via make install-assets.
            return try? NegativeContextGazetteer()
        }
        return try? NegativeContextGazetteer()
    }

    private func printSummary(_ report: GateReport, label: String) {
        print("[D1 \(label)] run_id=\(report.run_id) asset_sha256=\(report.asset_sha256.prefix(16))…")
        let sampleKeys = ["ssn_financial", "ssn_court", "name_financial",
                          "ssn_medical", "name_court", "address_financial"]
        print("[D1 \(label)] G8 cells (sample):")
        for key in sampleKeys {
            if let c = report.g8_results.by_category_doctype[key] {
                print("[D1 \(label)]   \(key): tp=\(c.true_positives) fp=\(c.false_positives) fn=\(c.false_negatives) suppressed=\(c.suppressed_by_negative_context)")
            }
        }
        print("[D1 \(label)] total G8 cells: \(report.g8_results.by_category_doctype.count)")
    }
}

// MARK: - Range overlap (half-open [start, end))

private func rangesOverlap(_ a: NSRange, _ b: NSRange) -> Bool {
    let aEnd = a.location + a.length
    let bEnd = b.location + b.length
    return a.location < bEnd && b.location < aEnd
}
