import Foundation
@testable import RedactionEngine

// H2.1 — VerificationReport → JSON serializer (1.2 instrumentation plan I-2).
//
// TEST-TARGET ONLY, zero engine-module delta: `VerificationReport`,
// `LayerResult`, and `VerificationStatus` are `Sendable` only, and no Codable
// conformance is added to them. The encoding below is a private Encodable
// MIRROR of the report, so the engine's public surface is untouched and the
// wire format is pinned here (a model change that renames or adds a case
// breaks this file's exhaustive switches at compile time, never silently).
//
// Wire format (schema_version 1):
//   {schema_version, overall:{case, message?}, duration_s,
//    layers:[{index, name, symbol, status:{case, message?}, short, detail,
//             pages:[Int]?, duration_s, review_terms:[String]?,
//             could_not_verify:Bool}],
//   `could_not_verify` (2026-09-17) mirrors `LayerResult.couldNotVerify`:
//   additive — every earlier evidence file reads as `false`, so
//   schema_version stays 1.
//    per_page_modes:["secureRasterization"|"searchableRedaction"],
//    per_page_fallback_reasons:[String?],   // FallbackReason case names
//    skip_reason:"autoVerifyOff"|"cancelled"|"error",
//    user_overrode_failure, user_acknowledged_skipped_share}
//
// Keys are emitted sorted (`.sortedKeys`) so evidence diffs are line-level.
//
// Privacy note: status messages are content-free by construction (ARCH §12.2);
// `review_terms` (LayerResult.reviewTermTexts) DOES carry applied term texts —
// this serializer is for the corpus runner's evidence dirs (synthetic inputs),
// never for logs or app-side export.

extension VerificationReport {

    /// Canonical evidence encoding of this report.
    func jsonData(schemaVersion: Int = 1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ReportJSON(self, schemaVersion: schemaVersion))
    }
}

// MARK: - Private Encodable mirror

private struct StatusJSON: Encodable {
    let `case`: String
    let message: String?

    init(_ status: VerificationStatus) {
        switch status {
        case .pass:                 self.case = "pass";      self.message = nil
        case .warn(let msg):        self.case = "warn";      self.message = msg
        case .info(let msg):        self.case = "info";      self.message = msg
        case .attention(let msg):   self.case = "attention"; self.message = msg
        case .fail(let msg):        self.case = "fail";      self.message = msg
        case .skipped:              self.case = "skipped";   self.message = nil
        }
    }
}

private struct LayerJSON: Encodable {
    let index: Int
    let name: String
    let symbol: String
    let status: StatusJSON
    let short: String
    let detail: String
    let pages: [Int]?
    let duration_s: Double
    let review_terms: [String]?
    let could_not_verify: Bool

    init(_ layer: LayerResult, index: Int) {
        self.index = index
        self.name = layer.name
        self.symbol = layer.symbolName
        self.status = StatusJSON(layer.status)
        self.short = layer.shortDescription
        self.detail = layer.detailDescription
        self.pages = layer.pageReferences
        self.duration_s = layer.durationSeconds
        self.review_terms = layer.reviewTermTexts
        self.could_not_verify = layer.couldNotVerify
    }
}

private struct ReportJSON: Encodable {
    let schema_version: Int
    let overall: StatusJSON
    let duration_s: Double
    let layers: [LayerJSON]
    let per_page_modes: [String]
    let per_page_fallback_reasons: [String?]
    let skip_reason: String
    let user_overrode_failure: Bool
    let user_acknowledged_skipped_share: Bool

    init(_ report: VerificationReport, schemaVersion: Int) {
        self.schema_version = schemaVersion
        self.overall = StatusJSON(report.overallStatus)
        self.duration_s = report.durationSeconds
        self.layers = report.layers.enumerated().map { LayerJSON($0.element, index: $0.offset) }
        self.per_page_modes = report.perPageModes.map(\.rawValue)
        self.per_page_fallback_reasons = report.perPageFallbackReasons.map { $0.map(Self.name(for:)) }
        self.skip_reason = Self.name(for: report.skipReason)
        self.user_overrode_failure = report.userOverrodeFailure
        self.user_acknowledged_skipped_share = report.userAcknowledgedSkippedShare
    }

    // Exhaustive by-name maps — a new engine case fails compilation here.

    static func name(for reason: TextLayerDetector.FallbackReason) -> String {
        switch reason {
        case .noExtractableText:  "noExtractableText"
        case .cjkEncodingFailure: "cjkEncodingFailure"
        case .rtlText:            "rtlText"
        case .verticalText:       "verticalText"
        case .zeroSizeBounds:     "zeroSizeBounds"
        case .unresolvedEncoding: "unresolvedEncoding"
        case .extractionFailed:   "extractionFailed"
        case .hiddenText:         "hiddenText"
        }
    }

    static func name(for reason: VerificationReport.SkipReason) -> String {
        switch reason {
        case .autoVerifyOff: "autoVerifyOff"
        case .cancelled:     "cancelled"
        case .error:         "error"
        }
    }
}
