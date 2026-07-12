import Foundation

// Plan A4 / G5 — five-class doctype label used by DocumentTypeClassifier and
// carried through PageDetectionResult. Canonical ordering matches the Python
// DataPipeline schema at DataPipeline/schemas/doctype_keywords.schema.json
// (classes array, minItems/maxItems=5).
//
// Lives in the engine package (not the app) because PageDetectionResult crosses
// the SPM boundary.

public enum DoctypeClass: String, Sendable, CaseIterable, Codable, Hashable {
    case court
    case medical
    case financial
    case foia
    case generic

    /// Canonical order. Matches the Python `classes` array in
    /// doctype_keywords.schema.json and the 5-float vector order the Swift
    /// softmax dump writes for Phase 3b temperature fitting.
    public static let canonicalOrder: [DoctypeClass] = [
        .court, .medical, .financial, .foia, .generic,
    ]
}
