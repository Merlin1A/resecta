import CryptoKit
import Foundation
import PDFKit
@testable import RedactionEngine

// MARK: - G8 corpus wire format (mirrors G8CorpusIngestionTests)

struct GateG8Corpus: Decodable, Sendable {
    let seed: Int
    let documents: [GateG8Document]
}

struct GateG8Document: Decodable, Sendable {
    let id: String
    let doctype: String
    let text: String
    let pii_spans: [GateG8Span]
}

struct GateG8Span: Decodable, Sendable {
    let category: String
    let start: Int
    let end: Int
    let expected_outcome: String?
}

// MARK: - Output JSON shapes (design 02 §12)

struct GateReport: Encodable, Sendable {
    let run_id: String
    let asset_sha256: String
    let g8_results: GateG8Results
}

struct GateG8Results: Encodable, Sendable {
    let by_category_doctype: [String: GateCellResult]
}

struct GateCellResult: Encodable, Sendable {
    let true_positives: Int
    let false_positives: Int
    let false_negatives: Int
    let suppressed_by_negative_context: Int
}

// MARK: - Category mapping

/// Maps G8 corpus category strings to PIICategory values that the
/// detector emits. Returns nil for categories the detector does not
/// produce (phone, email — these are in the corpus but the detector
/// emits them; they are excluded from the gate scoring).
func gateMapCategory(_ s: String) -> RedactionRegion.PIIKind? {
    switch s {
    case "ssn":      return .ssn
    case "name":     return .name
    case "address":  return .address
    case "dob":      return .dateOfBirth
    case "npi":      return .npi
    case "dea":      return .dea
    case "account":  return .account
    case "mrn":      return .medicalRecord
    // S4 calibration corpus (2026-06-11) carries routingNumber and ein
    // truth spans; without these cases their detections all miscount as
    // false positives against an empty truth set.
    case "routingNumber": return .routingNumber
    case "ein":           return .ein
    // phone and email are in the corpus but are not scored by the gate:
    // they are never suppressed by the negative-context gazetteer and
    // the D1 rubric focuses on categories the gazetteer can affect.
    // Documented in the final report as "G8 categories skipped".
    default:         return nil
    }
}

func gateDoctypeClass(_ s: String) -> DoctypeClass? {
    switch s {
    case "court":     return .court
    case "medical":   return .medical
    case "financial": return .financial
    case "foia":      return .foia
    case "generic":   return .generic
    default:          return nil
    }
}

// MARK: - Balanced preset lookup

/// Returns the balanced preset cutoff for `kind`, using the bundled
/// preset-thresholds.json or the built-in defaults on decode failure.
/// `nil` means the category has no wire name and passes unfiltered through W4.
func balancedCutoff(for kind: RedactionRegion.PIIKind) -> Double? {
    let bundle = PresetThresholdBundle.loadFromEngineBundle()
    guard let vector = bundle.presets[.balanced] else { return nil }
    guard let cat = PIICategory(piiKind: kind) else { return nil }
    return vector.threshold(for: cat)
}

// MARK: - Signal inspection

func isNegativeContextSuppressed(_ match: PIIDetector.PIIMatch) -> Bool {
    guard let signals = match.rationale?.signals else { return false }
    return signals.contains { signal in
        if case .negativeContextSuppressed = signal { return true }
        return false
    }
}

// MARK: - Output helpers

func writeGateReport(_ report: GateReport, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
}

// MARK: - G8 corpus loader

func loadGateG8Corpus() throws -> GateG8Corpus? {
    guard let url = Bundle.module.url(
        forResource: "g8_corpus",
        withExtension: "json",
        subdirectory: "corpus"
    ) else { return nil }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(GateG8Corpus.self, from: data)
}

// MARK: - Negative-context asset SHA-256

func negativeContextAssetSHA256(gazetteer: NegativeContextGazetteer?) -> String {
    // The gazetteer is constructed from negative-context.json in the module
    // bundle. We re-open the file to compute its SHA-256 for the report.
    guard gazetteer != nil else { return "none" }
    // Try env override path first, then fall back to the bundled resource.
    let env = ProcessInfo.processInfo.environment
    let assetPath = env["RESECTA_NEGCTX_ASSET"] ?? env["TEST_RUNNER_RESECTA_NEGCTX_ASSET"]
    if let envPath = assetPath, !envPath.isEmpty {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: envPath)) {
            return sha256Hex(data)
        }
    }
    guard let url = Bundle.module.url(
        forResource: "negative-context",
        withExtension: "json",
        subdirectory: "Gazetteers"
    ), let data = try? Data(contentsOf: url) else {
        return "bundle-read-failed"
    }
    return sha256Hex(data)
}

private func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Output path resolver

// Env var resolution: check the bare name first (set when running directly
// against the xctest process), then the TEST_RUNNER_-prefixed name (the
// mechanism xcodebuild uses to forward env vars to the test host on macOS,
// but which Swift Testing on the simulator may expose under the original name).
// Callers pass vars as `TEST_RUNNER_RESECTA_GATE_OUT=<path>` on the
// xcodebuild command line.

func gateOutputPath(default defaultPath: String = "/tmp/negative_context_gate.json") -> String {
    let env = ProcessInfo.processInfo.environment
    if let p = env["RESECTA_GATE_OUT"], !p.isEmpty { return p }
    if let p = env["TEST_RUNNER_RESECTA_GATE_OUT"], !p.isEmpty { return p }
    return defaultPath
}

func gateRunID(default defaultID: String) -> String {
    let env = ProcessInfo.processInfo.environment
    if let id = env["RESECTA_GATE_RUN_ID"], !id.isEmpty { return id }
    if let id = env["TEST_RUNNER_RESECTA_GATE_RUN_ID"], !id.isEmpty { return id }
    return defaultID
}
