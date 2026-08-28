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
}

// MARK: - Output JSON shapes

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
    // The calibration corpus (2026-06-11) carries routingNumber and ein
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

