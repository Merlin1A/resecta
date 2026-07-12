import Foundation

// SEC-7 — Explicit-degrade gazetteer loader diagnostics.
//
// Promotes the previous `try? NameGazetteer()` / `try? DLPatternGazetteer()`
// / `try? PassportPatternGazetteer()` / `try? ContextKeywordsLoader()` swallow-
// nils into structured per-loader outcomes. When the iOS app constructs the
// detection stack via `PIIDetector.loadWithDiagnostics(bundle:)`, the returned
// diagnostics value records which gazetteers failed and the underlying error
// description (mechanism-only — no document content, no file paths).
//
// Failure surface: persistent top banner on triage sheet + warning
// toast on first failure.
//
// `Sendable` so the value can cross the engine → app actor boundary alongside
// the `PIIDetector` that produced it.
public struct GazetteerLoadDiagnostics: Sendable, Equatable {

    /// Loader identifier — one per gazetteer / context source.
    /// The string values are stable engine-facing names; not user-visible.
    /// Mirror to keep `failedGazetteers` self-describing for the audit log.
    public enum Gazetteer: String, Sendable, Equatable, CaseIterable {
        case nameGazetteer = "NameGazetteer"
        case dlPatternGazetteer = "DLPatternGazetteer"
        case passportPatternGazetteer = "PassportPatternGazetteer"
        case contextKeywordsLoader = "ContextKeywordsLoader"
        // S3 §2.10: four new tracked loaders (all four added here in one
        // extension to prevent a double-add compile error if added piecemeal;
        // `allCases` enumeration in the signature-fail loop picks them up
        // automatically — no additional wiring required).
        case negativeContextGazetteer = "NegativeContextGazetteer"
        case institutionGazetteer = "InstitutionGazetteer"
        case addressComponentsGazetteer = "AddressComponentsGazetteer"
        case zipStateTableLoader = "ZIPStateTableLoader"
        // The doctype classifier is tracked alongside the gazetteers so
        // a missing or corrupt doctype-keywords.json degrades visibly (the
        // auto-detect-degraded banner) instead of silently classifying every
        // page as `.generic`. Its JSON is NOT covered by the gazetteer-manifest
        // signature, so the signature-fail path in
        // `PIIDetector.loadWithDiagnostics(bundle:)` deliberately excludes it.
        case documentTypeClassifier = "DocumentTypeClassifier"
        // GAP-DEPTARGET-NER / D04-F3 == D11-F3 — the NLTagger `.personalName`
        // MobileAsset is an OS-provisioned model, NOT a bundled corpus and NOT
        // covered by the gazetteer-manifest signature. Tracked here so a device
        // on which the asset has not downloaded degrades VISIBLY through the same
        // SEC-7 banner instead of silently dropping all NER-sourced name matches.
        // Excluded from the signature-fail loop for the same reason as
        // documentTypeClassifier (it is not signature-covered).
        case nerNameModel = "NERNameModel"
    }

    /// Engine-facing names of every loader that failed to initialize.
    /// Ordering matches the four init calls inside `PIIDetector.loadWithDiagnostics(bundle:)`
    /// so a partial-failure trace is stable across runs.
    public let failedGazetteers: [String]

    /// Per-loader failure reasons keyed by the same engine-facing name.
    /// Values are mechanism descriptions captured via
    /// `String(describing:)` on the thrown Error (or "init returned nil"
    /// for the `NameGazetteer.init?()` legacy path). Never contains document
    /// content, file paths, or coordinates — ARCH §12.2 invariant.
    public let failureReasons: [String: String]

    /// True iff at least one loader failed. Drives the app-side
    /// `RedactionState.autoDetectionDegraded` flag and the triage-sheet
    /// banner / warning-toast surfaces.
    public var didDegrade: Bool { !failedGazetteers.isEmpty }

    public init(failedGazetteers: [String] = [], failureReasons: [String: String] = [:]) {
        self.failedGazetteers = failedGazetteers
        self.failureReasons = failureReasons
    }

    /// Append a single failure. Used by `PIIDetector.loadWithDiagnostics(bundle:)`
    /// as it walks the four loaders. Returns a new value (struct semantics).
    public func appending(_ gazetteer: Gazetteer, reason: String) -> GazetteerLoadDiagnostics {
        var failures = failedGazetteers
        failures.append(gazetteer.rawValue)
        var reasons = failureReasons
        reasons[gazetteer.rawValue] = reason
        return GazetteerLoadDiagnostics(
            failedGazetteers: failures,
            failureReasons: reasons
        )
    }
}
