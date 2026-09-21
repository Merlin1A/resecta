import Foundation

// Explicit-degrade gazetteer loader diagnostics.
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
        // Four new tracked loaders (all four added here in one
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
        // The NLTagger `.personalName`
        // MobileAsset is an OS-provisioned model, NOT a bundled corpus and NOT
        // covered by the gazetteer-manifest signature. Tracked here so a device
        // on which the asset has not downloaded degrades VISIBLY through the same
        // degraded-detection banner instead of silently dropping all NER-sourced name matches.
        // Excluded from the signature-fail loop for the same reason as
        // documentTypeClassifier (it is not signature-covered).
        case nerNameModel = "NERNameModel"
        // The three detection-quality assets under `Classifier/` that fall back
        // (identity scorer / T=1.0 / built-in thresholds) when missing or
        // invalid. Tracked so those fallbacks surface through the same
        // degraded-detection banner the corpus loaders use — reporting only; the fallback values
        // themselves are unchanged. Not covered by the gazetteer-manifest
        // signature, so all three are excluded from the signature-fail loop.
        case contextScorerWeights = "ContextScorerWeights"
        case doctypeTemperature = "DoctypeTemperature"
        case presetThresholds = "PresetThresholds"
        // A signed-manifest digest failure on an UNGATED asset that has no
        // detection loader of its own (today: the audit rule catalog).
        // Ungated assets with a loader report under that loader's case.
        case assetIntegrity = "AssetIntegrity"
    }

    /// Trackers a failed CORPUS verdict (a bad manifest signature, or a
    /// trust-gated asset failing its signed digest) must not auto-attribute:
    /// nothing withholds them on that path, so naming them would overstate the
    /// degradation. Their own load status — and, since the manifest lists
    /// every installed asset, their own digest failures — are folded in on the
    /// trusted path of `PIIDetector.loadWithDiagnostics(bundle:)`.
    static let outsideManifestSignature: Set<Gazetteer> = [
        .documentTypeClassifier, .nerNameModel,
        .contextScorerWeights, .doctypeTemperature, .presetThresholds,
        .assetIntegrity,
        // The three JSON reference tables load through ungated process-
        // lifetime `static let`s (AddressSpatialAssembler.sharedAddressComponents,
        // ZIPStateTable.loader, OCRCustomWordsBuilder.financialCustomWords);
        // a false corpus verdict never withholds them. Their digests are
        // verified with everyone else's and report on the trusted path.
        .institutionGazetteer, .addressComponentsGazetteer, .zipStateTableLoader,
    ]

    /// Engine-facing names of every loader that failed to initialize.
    /// Ordering matches the four init calls inside `PIIDetector.loadWithDiagnostics(bundle:)`
    /// so a partial-failure trace is stable across runs.
    public let failedGazetteers: [String]

    /// Per-loader failure reasons keyed by the same engine-facing name.
    /// Values are mechanism descriptions captured via
    /// `String(describing:)` on the thrown Error (or "init returned nil"
    /// for the `NameGazetteer.init?()` legacy path). Never contains document
    /// content, file paths, or coordinates.
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
        // One entry per loader: the first attribution wins (the integrity pass
        // reports a digest failure before the loader reports the decode
        // failure it causes), so the banner names each loader once.
        guard !failedGazetteers.contains(gazetteer.rawValue) else { return self }
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
