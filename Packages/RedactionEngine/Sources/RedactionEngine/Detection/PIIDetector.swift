import Foundation
import NaturalLanguage
import OSLog

// PII detection runs as regex-based passes plus NLTagger-based name detection.

/// Detects PII patterns in OCR text. Stateless, runs on cooperative thread pool.
/// Detection runs regex-based passes first, then NLTagger-based name detection.
public struct PIIDetector: Sendable {

    // Phase 3 detectors — lazy instances reused across calls.
    private let npiDetector = NPIDetector()
    private let deaDetector = DEADetector()
    private let accountDetector = AccountDetector()
    private let routingNumberDetector = RoutingNumberDetector()

    // Optional because NameGazetteer.init?() fails when bundled
    // resources are stripped (test-bundle-only builds). `runNLTagger` reads
    // this via `?.` so a nil gazetteer preserves the 0.70 baseline.
    private let nameGazetteer: NameGazetteer?

    // Context-keywords loader. Drives the positive-keyword set for the
    // retired *ContextKeywords.swift files (SSN / MRN / LP). nil
    // preserves the const-array fallback via the call-site `??` fallback
    // in detectSSNs / detectMedicalRecords / detectLicensePlate, so
    // test-bundle-only builds and any context that can't load the corpus
    // keep working with the engine-side baseline.
    private let contextLoader: ContextKeywordsLoader?

    // Negative-context gazetteer wired into the three scored
    // detectors (SSN / MRN / LP). nil = no gazetteer suppression (the correct
    // fail-safe: detection continues without negative-context dampening).
    // Header-anchor path is not yet wired here; `suppressionScore(documentHeader:)`
    // is live in the struct but not called here.
    private let negativeContextGazetteer: NegativeContextGazetteer?

    /// The family detectors in evaluation order (`DetectorRegistry.rows`),
    /// keyed by category for the reverse-rationale explainer. Constructed
    /// once from the loaders above.
    let families: DetectorRegistry

    // The default arguments consult the same memoized corpus verdict the
    // diagnostics loader uses (the manifest signature plus the signed digests
    // of the files these five read), so `PIIDetector()` cannot load a corpus
    // the check would have withheld. With the shipped bundle intact every
    // default evaluates exactly as before.
    public init(
        nameGazetteer: NameGazetteer? =
            GazetteerTrust.isShippedCorpusTrusted() ? NameGazetteer() : nil,
        dlPatternGazetteer: DLPatternGazetteer? =
            GazetteerTrust.isShippedCorpusTrusted() ? (try? DLPatternGazetteer()) : nil,
        passportPatternGazetteer: PassportPatternGazetteer? =
            GazetteerTrust.isShippedCorpusTrusted() ? (try? PassportPatternGazetteer()) : nil,
        contextLoader: ContextKeywordsLoader? =
            GazetteerTrust.isShippedCorpusTrusted() ? (try? ContextKeywordsLoader()) : nil,
        negativeContextGazetteer: NegativeContextGazetteer? =
            GazetteerTrust.isShippedCorpusTrusted() ? (try? NegativeContextGazetteer()) : nil
    ) {
        self.nameGazetteer = nameGazetteer
        self.contextLoader = contextLoader
        self.negativeContextGazetteer = negativeContextGazetteer
        self.families = DetectorRegistry(
            nameGazetteer: nameGazetteer,
            dlPatternGazetteer: dlPatternGazetteer,
            passportPatternGazetteer: passportPatternGazetteer,
            contextLoader: contextLoader
        )
    }

    // MARK: - Explicit-degrade loader

    /// Construct a `PIIDetector` from the supplied bundle, recording per-
    /// gazetteer load failures into a `GazetteerLoadDiagnostics` value. Each
    /// loader is invoked via its throwing variant so the underlying error
    /// description can be captured for the diagnostic; failures degrade the
    /// detector into nil-gazetteer pass-through behavior identical to the
    /// `try?` path (so non-gazetteer regex detectors — SSN, CC,
    /// email, phone, EIN, ITIN, DEA, NPI, address, DOB — still produce
    /// matches when corpus resources are missing or corrupted).
    ///
    /// The diagnostics value is consumed
    /// by `PipelineCoordinator.runDetectionPipeline` which posts a one-time
    /// warning toast and flips `RedactionState.autoDetectionDegraded = true`
    /// on first failure. The triage sheet renders a persistent top banner
    /// while the flag is set (mechanism-description copy).
    public static func loadWithDiagnostics()
        -> (detector: PIIDetector, diagnostics: GazetteerLoadDiagnostics)
    {
        loadWithDiagnostics(bundle: .module)
    }

    /// Testing / composition entry point. Internal so an empty `Bundle()`
    /// (or a fixture bundle) can be injected by `PIIDetectorInitDegradedTests`
    /// to exercise the all-fail and partial-fail paths without relying on
    /// the strip-bundle environment. The public overload above is the
    /// production path that uses `Bundle.module`.
    static func loadWithDiagnostics(bundle: Bundle)
        -> (detector: PIIDetector, diagnostics: GazetteerLoadDiagnostics)
    {
        var diagnostics = GazetteerLoadDiagnostics()

        // Verify the corpus before trusting any bundled asset: the manifest's
        // Ed25519 signature, then the signed SHA-256 of every file the five
        // gated loaders read (`AssetIntegrity`). The verdict comes from the
        // shared memoized chokepoint (`GazetteerTrust`), the same one the
        // public `PIIDetector.init` default arguments consult. A false verdict
        // short-circuits the five gated loaders below: each reports as failed
        // (with the signature or digest reason in `failureReasons`) so the
        // existing auto-detect-degraded banner / toast surface fires
        // unchanged. The detector is constructed with nil gazetteers —
        // non-gazetteer detectors (SSN state machine, regex-based DEA /
        // email / phone) keep running so manual redaction users retain
        // partial auto-detection (degrade-with-banner).
        let verdict = GazetteerTrust.corpusVerdict(bundle: bundle)
        if let reason = verdict.failureReason {
            // Trackers a false corpus verdict does not withhold must not be
            // auto-attributed here (their load status and their own digest
            // failures are folded in on the trusted path below): the doctype
            // classifier, the OS-provisioned NER MobileAsset, the three
            // Classifier/ quality assets, the audit rule catalog's integrity
            // tracker, and the three JSON reference tables whose ungated
            // static loads a false verdict never reaches. Membership lives on
            // the enum so the loop and the trusted-path probes cannot drift.
            for gazetteer in GazetteerLoadDiagnostics.Gazetteer.allCases
            where !GazetteerLoadDiagnostics.outsideManifestSignature.contains(gazetteer) {
                diagnostics = diagnostics.appending(gazetteer, reason: reason)
            }
            // False-verdict path: the five gated loaders are nil; the
            // institution, address-components and ZIP-state reference
            // tables load outside the verdict and stay live (see
            // ENGINEERING.md §8). negativeContextGazetteer: nil is the
            // correct degrade behavior (no suppression).
            let detector = PIIDetector(
                nameGazetteer: nil,
                dlPatternGazetteer: nil,
                passportPatternGazetteer: nil,
                contextLoader: nil,
                negativeContextGazetteer: nil
            )
            return (detector, diagnostics)
        }

        // 0. Signed-digest failures on UNGATED assets (the reference tables,
        //    the Classifier files, the audit rule catalog): the asset's own
        //    tracker reports the digest mismatch first, so the banner names
        //    the root cause; the loader's own decode failure, if any, is
        //    folded into the same entry below. The loaders keep their
        //    fail-open fallbacks — reporting only.
        if let report = verdict.report {
            for failure in report.ungated {
                let tracker = AssetIntegrity.diagnosticsCase(forPath: failure.path ?? "")
                diagnostics = diagnostics.appending(tracker, reason: failure.description)
            }
        }

        // 1. NameGazetteer — paired throwing variant exists alongside init?();
        //    using the throwing form so the rejection reason (resource-missing,
        //    decode failure, manifest-version fence) can be captured.
        let name: NameGazetteer?
        do {
            name = try NameGazetteer(throwingFromBundle: bundle)
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            name = nil
            diagnostics = diagnostics.appending(
                .nameGazetteer,
                reason: String(describing: error)
            )
        }

        // 2. DLPatternGazetteer
        let dl: DLPatternGazetteer?
        do {
            dl = try DLPatternGazetteer(bundle: bundle)
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            dl = nil
            diagnostics = diagnostics.appending(
                .dlPatternGazetteer,
                reason: String(describing: error)
            )
        }

        // 3. PassportPatternGazetteer
        let passport: PassportPatternGazetteer?
        do {
            passport = try PassportPatternGazetteer(bundle: bundle)
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            passport = nil
            diagnostics = diagnostics.appending(
                .passportPatternGazetteer,
                reason: String(describing: error)
            )
        }

        // 4. ContextKeywordsLoader
        let context: ContextKeywordsLoader?
        do {
            context = try ContextKeywordsLoader(bundle: bundle)
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            context = nil
            diagnostics = diagnostics.appending(
                .contextKeywordsLoader,
                reason: String(describing: error)
            )
        }

        // 5. InstitutionGazetteer (visibility tracking; also fed
        //    into NegativeContextGazetteer below so the header-anchor path
        //    gets a properly-constructed institution source when that path is wired).
        let institution: InstitutionGazetteer?
        do {
            institution = try InstitutionGazetteer(bundle: bundle)
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            institution = nil
            diagnostics = diagnostics.appending(
                .institutionGazetteer,
                reason: String(describing: error)
            )
        }

        // 6. NegativeContextGazetteer. Pass the loaded
        //    InstitutionGazetteer so the header-anchor path is ready for
        //    future wiring without re-loading the institution file.
        let negCtx: NegativeContextGazetteer?
        do {
            negCtx = try NegativeContextGazetteer(bundle: bundle, institutions: institution)
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            negCtx = nil
            diagnostics = diagnostics.appending(
                .negativeContextGazetteer,
                reason: String(describing: error)
            )
        }

        // 7. AddressComponentsGazetteer (visibility only — the gazetteer
        //    feeds AddressSpatialAssembler separately; no behavior change here).
        do {
            _ = try AddressComponentsGazetteer(bundle: bundle)
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            diagnostics = diagnostics.appending(
                .addressComponentsGazetteer,
                reason: String(describing: error)
            )
        }

        // 8. ZIPStateTableLoader (visibility only — feeds address
        //    validation separately; no behavior change here).
        do {
            _ = try ZIPStateTableLoader(bundle: bundle)
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            diagnostics = diagnostics.appending(
                .zipStateTableLoader,
                reason: String(describing: error)
            )
        }

        // 9. DocumentTypeClassifier (visibility only; the live
        //    classifier instance is owned by DetectionOrchestrator). Folds a
        //    missing/corrupt doctype-keywords.json into the same diagnostics
        //    that drive the auto-detect-degraded banner, rather than silently
        //    classifying every page as `.generic`. The factory's classifier is
        //    discarded here — the load is startup-cheap (<5 ms) and idempotent.
        let (_, classifierDiagnostic) = DocumentTypeClassifier.loadWithDiagnostics(bundle: bundle)
        if let reason = classifierDiagnostic?
            .failureReasons[GazetteerLoadDiagnostics.Gazetteer.documentTypeClassifier.rawValue] {
            diagnostics = diagnostics.appending(.documentTypeClassifier, reason: reason)
        }

        // 10. NER name model availability.
        //     The `.nameType` model is OS-provisioned (a downloadable MobileAsset),
        //     not a bundled corpus. If absent on this device, ALL NER-sourced name
        //     matches are silently dropped; fold that into the same diagnostics that
        //     drive the auto-detect-degraded banner so the user sees the same
        //     degraded indication as a corpus failure. Mechanism-only reason
        //     (no document content / paths reported). Probe is side-effect-free
        //     (no asset download); see `isNameNERAvailable()`.
        if !Self.isNameNERAvailable() {
            diagnostics = diagnostics.appending(
                .nerNameModel,
                reason: "NLTagger .nameType MobileAsset unavailable on this OS build (NER name detection disabled)"
            )
        }

        // 11. Context-scorer weights (visibility only — DetectionOrchestrator
        //     and DocumentSearcher own the live instances via
        //     `loadFromEngineBundle()`, which shares this loader). Any fallback
        //     to the identity scorer (missing / unreadable / hash-mismatched /
        //     invalid wire) previously reached OSLog only; folding it here
        //     drives the same auto-detect-degraded banner the corpus loaders use. The load is
        //     startup-cheap and idempotent; the instance is discarded.
        let (_, scorerReason) = ContextScorerWeights.loadWithDiagnostics(from: bundle)
        if let reason = scorerReason {
            diagnostics = diagnostics.appending(.contextScorerWeights, reason: reason)
        }

        // 12. Doctype softmax temperature (visibility only — CalibratedScorer
        //     owns the live value). Fallback to identity T=1.0 reports here.
        let (_, temperatureReason) = CalibratedScorer.loadTemperatureWithDiagnostics(from: bundle)
        if let reason = temperatureReason {
            diagnostics = diagnostics.appending(.doctypeTemperature, reason: reason)
        }

        // 13. Preset threshold vectors (visibility only — consumers load via
        //     `PresetThresholdBundle.loadFromEngineBundle()`). Fallback to
        //     `.builtInDefaults` reports here.
        let (_, presetsReason) = PresetThresholdBundle.loadWithDiagnostics(from: bundle)
        if let reason = presetsReason {
            diagnostics = diagnostics.appending(.presetThresholds, reason: reason)
        }

        let detector = PIIDetector(
            nameGazetteer: name,
            dlPatternGazetteer: dl,
            passportPatternGazetteer: passport,
            contextLoader: context,
            negativeContextGazetteer: negCtx
        )
        return (detector, diagnostics)
    }

    // MARK: - Per-detector elapsed-time telemetry

    /// Mirror of `DocumentSearcher.perPageRegexTimeout`. The search path
    /// enforces its budget inside `enumerateMatches`; the detection path's
    /// regex detectors use `pattern.matches(in:range:)` all at once, which
    /// cannot be interrupted mid-match. `withPerPageTimeout` therefore
    /// measures each detector after `matches()` returns and logs a
    /// mechanism-only warning (detector name and elapsed time, never
    /// document content) when the elapsed time exceeds this value — it is
    /// telemetry, not a pre-emptive guard. A detector that moves to
    /// `pattern.enumerateMatches(...)` can compare `ContinuousClock.now`
    /// against this value inside the stop block, as the search path does.
    public static let perPageRegexTimeout: Duration = .seconds(5)

    /// Wrap a detector body with elapsed-time measurement. The body runs
    /// synchronously to completion; the elapsed time is recorded via
    /// `ContinuousClock` and logged at warning level if it exceeds
    /// `perPageRegexTimeout`. The measurement never interrupts a match. No
    /// document content is logged — only the detector name and elapsed
    /// duration.
    private func withPerPageTimeout(_ name: String, _ body: () -> [PIIMatch]) -> [PIIMatch] {
        let start = ContinuousClock.now
        let results = body()
        let elapsed = ContinuousClock.now - start
        if elapsed > Self.perPageRegexTimeout {
            Self.reDoSLogger.warning("detector \(name, privacy: .public) exceeded 5s (elapsed=\(String(describing: elapsed), privacy: .public))")
        }
        return results
    }

    private static let reDoSLogger = Logger(subsystem: "app.resecta.engine", category: "PIIDetector")

    /// A detected PII item with its text, location, kind, and confidence.
    public struct PIIMatch: Sendable {
        public let text: String
        public let range: NSRange
        public let kind: RedactionRegion.PIIKind
        public let confidence: Double
        /// Per-match explainability. Populated by detectors that emit
        /// structured evidence (SSN, names); left nil otherwise so the
        /// detect() wrapper can fill in a generic `regexPattern` fallback.
        public let rationale: MatchRationale?

        public init(
            text: String,
            range: NSRange,
            kind: RedactionRegion.PIIKind,
            confidence: Double,
            rationale: MatchRationale? = nil
        ) {
            self.text = text
            self.range = range
            self.kind = kind
            self.confidence = confidence
            self.rationale = rationale
        }

        /// Map to PIICategory for search-layer filtering.
        public var category: PIICategory? {
            PIICategory(piiKind: kind)
        }

        /// Return a copy with the rationale replaced. Used by the
        /// threshold post-filter to annotate survivors without mutating
        /// PIIMatch's `let` fields.
        public func withRationale(_ rationale: MatchRationale) -> PIIMatch {
            PIIMatch(text: text, range: range, kind: kind,
                     confidence: confidence, rationale: rationale)
        }

        /// Return a copy replacing ONLY the `range` (mirrors
        /// `withRationale`'s initializer-copy; `PIIMatch`'s fields are `let`).
        /// Used to widen an overlap survivor to the coalesced group span so a
        /// partially-overlapping loser's non-overlapping tail still maps to a
        /// redaction region. `text`/`kind`/`confidence`/`rationale` are copied
        /// unchanged — the `.address` spatial path keys `spatialRectByText` on
        /// `text`, so text must not move.
        public func withRange(_ newRange: NSRange) -> PIIMatch {
            PIIMatch(text: text, range: newRange, kind: kind,
                     confidence: confidence, rationale: rationale)
        }
    }

    /// Detect all PII in the given text. Returns matches from all passes.
    /// Pass 1: Regex (SSN, CC, email, phone, EIN, ITIN, DL, passport, MRN).
    /// Pass 2: NLTagger (names).
    ///
    /// Phase 3: `doctype` is an optional context hint that gates the new
    /// NPI/DEA/DOB/Account detectors. `nil` = run all (back-compat for
    /// pre-Phase-3 callers). When non-nil, medical/financial-only detectors
    /// are activated per the doctype gating rules below.
    ///
    /// `documentHeader` is an optional first-page text prefix used
    /// by the institution-anchor suppression path. When
    /// non-nil, the three scored detectors (SSN / MRN / LP) pass it into
    /// `ContextWindowScorer.score(documentHeader:)` so the institution
    /// named in the header can widen suppression to `.name` in addition to
    /// `.ssn` and `.npi`. Nil = header-anchor path inactive (no behavior
    /// change for existing call sites).
    @concurrent
    public func detect(
        in text: String,
        doctype: DoctypeClass? = nil,
        documentHeader: String? = nil
    ) async -> [PIIMatch] {
        var results: [PIIMatch] = []

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Capture doctype, negativeContextGazetteer, and
        // documentHeader for threaded scorer calls in detectSSNs /
        // detectMedicalRecords / detectLicensePlate.
        let currentDoctype = doctype
        let negCtxGazetteer = negativeContextGazetteer
        let currentHeader = documentHeader

        // Pass 1: Regex patterns. Each detector wrapped
        // with per-page timeout measurement.
        results.append(contentsOf: withPerPageTimeout("ssn") {
            families.ssn.detect(in: nsText, range: fullRange,
                       doctype: currentDoctype, gazetteer: negCtxGazetteer,
                       documentHeader: currentHeader)
        })
        results.append(contentsOf: withPerPageTimeout("creditCard") { families.creditCard.detect(in: nsText, range: fullRange) })
        results.append(contentsOf: withPerPageTimeout("email") { families.email.detect(in: nsText, range: fullRange) })
        results.append(contentsOf: withPerPageTimeout("phone") { families.phone.detect(in: nsText, range: fullRange) })
        results.append(contentsOf: withPerPageTimeout("ein") { families.ein.detect(in: nsText, range: fullRange) })
        results.append(contentsOf: withPerPageTimeout("address") { families.address.detect(in: nsText, range: fullRange) })
        if DOBDetector.runsDOBFull(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("dob") {
                families.dateOfBirth.detect(in: nsText, range: fullRange)
            })
        } else if doctype == .financial {
            // Financial doctype gets the label-anchored path only (fixed 0.85).
            results.append(contentsOf: withPerPageTimeout("dob.label") {
                families.dateOfBirth.detectLabelAnchored(in: nsText, range: fullRange)
            })
        }
        results.append(contentsOf: withPerPageTimeout("itin") { families.itin.detect(in: nsText, range: fullRange) })
        results.append(contentsOf: withPerPageTimeout("dl") { families.driversLicense.detect(in: nsText, range: fullRange) })
        results.append(contentsOf: withPerPageTimeout("passport") { families.passport.detect(in: nsText, range: fullRange) })
        if families.medicalRecord.runs(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("mrn") {
                families.medicalRecord.detect(in: nsText, range: fullRange,
                                     doctype: currentDoctype, gazetteer: negCtxGazetteer,
                                     documentHeader: currentHeader)
            })
        }
        if Self.runsNPI(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("npi") { npiDetector.detect(in: nsText, range: fullRange) })
        }
        if Self.runsDEA(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("dea") { deaDetector.detect(in: nsText, range: fullRange) })
        }
        if Self.runsAccount(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("account") { accountDetector.detect(in: nsText, range: fullRange) })
        }
        if Self.runsRoutingNumber(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("routingNumber") { routingNumberDetector.detect(in: nsText, range: fullRange) })
        }
        if families.licensePlate.runs(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("licensePlate") {
                families.licensePlate.detect(in: nsText, range: fullRange,
                                   doctype: currentDoctype, gazetteer: negCtxGazetteer,
                                   documentHeader: currentHeader)
            })
        }

        // Pass 2: NLTagger
        results.append(contentsOf: withPerPageTimeout("name") { detectNames(in: text, doctype: currentDoctype) })

        return Self.ensureRationales(results, doctype: doctype)
    }

    /// Detect PII, filtering to only the specified categories.
    /// More efficient than detect(in:) + post-filter because it skips
    /// regex passes for categories not in the set.
    ///
    /// Phase 3: accepts optional doctype. When set, Phase-3 detectors are
    /// gated per the doctype gating rules below. When nil and the category is requested, the
    /// detector runs unconditionally (back-compat for the user-search
    /// path which has no doctype context).
    ///
    /// `documentHeader` mirrors the overload above.
    @concurrent
    public func detect(
        in text: String,
        categories: Set<PIICategory>,
        doctype: DoctypeClass? = nil,
        documentHeader: String? = nil
    ) async -> [PIIMatch] {
        var results: [PIIMatch] = []

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        let currentDoctype = doctype
        let negCtxGazetteer = negativeContextGazetteer
        let currentHeader = documentHeader

        // Pass 1: Only run regex patterns for requested categories
        if categories.contains(.ssn) {
            results.append(contentsOf: withPerPageTimeout("ssn") {
                families.ssn.detect(in: nsText, range: fullRange,
                           doctype: currentDoctype, gazetteer: negCtxGazetteer,
                           documentHeader: currentHeader)
            })
        }
        if categories.contains(.creditCard) { results.append(contentsOf: withPerPageTimeout("creditCard") { families.creditCard.detect(in: nsText, range: fullRange) }) }
        if categories.contains(.email) { results.append(contentsOf: withPerPageTimeout("email") { families.email.detect(in: nsText, range: fullRange) }) }
        if categories.contains(.phone) { results.append(contentsOf: withPerPageTimeout("phone") { families.phone.detect(in: nsText, range: fullRange) }) }
        if categories.contains(.ein) { results.append(contentsOf: withPerPageTimeout("ein") { families.ein.detect(in: nsText, range: fullRange) }) }
        if categories.contains(.address) { results.append(contentsOf: withPerPageTimeout("address") { families.address.detect(in: nsText, range: fullRange) }) }
        if categories.contains(.dateOfBirth) {
            if DOBDetector.runsDOBFull(doctype: doctype) {
                results.append(contentsOf: withPerPageTimeout("dob") {
                    families.dateOfBirth.detect(in: nsText, range: fullRange)
                })
            } else if doctype == .financial {
                // Financial doctype gets the label-anchored path only (fixed 0.85).
                results.append(contentsOf: withPerPageTimeout("dob.label") {
                    families.dateOfBirth.detectLabelAnchored(in: nsText, range: fullRange)
                })
            }
        }
        if categories.contains(.itin) { results.append(contentsOf: withPerPageTimeout("itin") { families.itin.detect(in: nsText, range: fullRange) }) }
        if categories.contains(.driversLicense) { results.append(contentsOf: withPerPageTimeout("dl") { families.driversLicense.detect(in: nsText, range: fullRange) }) }
        if categories.contains(.passport) { results.append(contentsOf: withPerPageTimeout("passport") { families.passport.detect(in: nsText, range: fullRange) }) }
        if categories.contains(.medicalRecord), families.medicalRecord.runs(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("mrn") {
                families.medicalRecord.detect(in: nsText, range: fullRange,
                                     doctype: currentDoctype, gazetteer: negCtxGazetteer,
                                     documentHeader: currentHeader)
            })
        }
        if categories.contains(.npi), Self.runsNPI(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("npi") { npiDetector.detect(in: nsText, range: fullRange) })
        }
        if categories.contains(.dea), Self.runsDEA(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("dea") { deaDetector.detect(in: nsText, range: fullRange) })
        }
        if categories.contains(.account), Self.runsAccount(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("account") { accountDetector.detect(in: nsText, range: fullRange) })
        }
        if categories.contains(.routingNumber), Self.runsRoutingNumber(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("routingNumber") { routingNumberDetector.detect(in: nsText, range: fullRange) })
        }
        if categories.contains(.licensePlate), families.licensePlate.runs(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout("licensePlate") {
                families.licensePlate.detect(in: nsText, range: fullRange,
                                   doctype: currentDoctype, gazetteer: negCtxGazetteer,
                                   documentHeader: currentHeader)
            })
        }

        // Pass 2: NLTagger (names) — only if requested
        if categories.contains(.name) { results.append(contentsOf: withPerPageTimeout("name") { detectNames(in: text, doctype: currentDoctype) }) }

        return Self.ensureRationales(results, doctype: doctype)
    }

    /// Luhn checksum validation (the credit-card family's; kept here as the
    /// public entry point).
    public static func luhnCheck(_ number: String) -> Bool {
        CreditCardDetector.luhnCheck(number)
    }

    // MARK: - Rationale fallback

    /// Decorate any PIIMatch that didn't set its own rationale with a generic
    /// one carrying the rule ID, an optional doctype-gate signal, and the
    /// raw detector confidence as both pre- and final score. Detectors with
    /// richer evidence (SSN state machine, NLTagger + Bloom) attach their
    /// own rationale upstream.
    private static func ensureRationales(
        _ matches: [PIIMatch], doctype: DoctypeClass?
    ) -> [PIIMatch] {
        matches.map { match in
            if let existing = match.rationale {
                // Detector-built rationale present; only annotate with the
                // doctype gate when a doctype is in scope and the signal isn't
                // already there.
                guard let doctype else { return match }
                let alreadyTagged = existing.signals.contains {
                    if case .doctypeGate(let d) = $0, d == doctype { return true }
                    return false
                }
                if alreadyTagged { return match }
                var signals = existing.signals
                signals.append(.doctypeGate(doctype: doctype))
                let annotated = MatchRationale(
                    ruleID: existing.ruleID,
                    signals: signals,
                    preThresholdScore: existing.preThresholdScore,
                    finalScore: existing.finalScore,
                    appliedThreshold: existing.appliedThreshold
                )
                return match.withRationale(annotated)
            }
            let ruleID = defaultRuleID(for: match.kind)
            var signals: [MatchRationale.Signal] = [.regexPattern(name: ruleID)]
            if let doctype {
                signals.append(.doctypeGate(doctype: doctype))
            }
            return PIIMatch(
                text: match.text,
                range: match.range,
                kind: match.kind,
                confidence: match.confidence,
                rationale: MatchRationale(
                    ruleID: ruleID,
                    signals: signals,
                    preThresholdScore: match.confidence,
                    finalScore: match.confidence
                )
            )
        }
    }

    private static func defaultRuleID(for kind: RedactionRegion.PIIKind) -> String {
        switch kind {
        case .ssn:            "ssn.regex"
        case .creditCard:     "cc.luhn"
        case .email:          "email.regex"
        case .phone:          "phone.regex"
        case .ein:            "ein.regex"
        case .itin:           "itin.regex"
        case .address:        "address.regex"
        case .dateOfBirth:    "dob.regex"
        case .driversLicense: "dl.regex"
        case .passport:       "passport.regex"
        case .medicalRecord:  "mrn.regex"
        case .npi:            "npi.80840"
        case .dea:            "dea.letter-check"
        case .account:        "account.regex"
        case .routingNumber:  "routingNumber.aba-checksum"
        case .name:           "name.nltagger"
        case .licensePlate:   "licensePlate.labeled"
        case .barcode:        "barcode.vision"  // Produced by BarcodeDetector via Vision.
        // Heuristic visual detector; never emitted via PIIDetector
        // but the switch is exhaustive over PIIKind.
        case .signatureCandidate: "signature.heuristic"
        case .other:          "pii.other"
        }
    }

    // MARK: - Doctype Gating

    /// NPI: medical + FOIA (provider rosters commonly appear in both).
    /// nil doctype → run.
    private static func runsNPI(doctype: DoctypeClass?) -> Bool {
        guard let doctype else { return true }
        return doctype == .medical || doctype == .foia
    }

    /// DEA: medical only. nil doctype → run.
    private static func runsDEA(doctype: DoctypeClass?) -> Bool {
        guard let doctype else { return true }
        return doctype == .medical
    }

    /// Account: financial + medical + court + generic. nil doctype → run.
    /// Court and generic doctypes were added to close the
    /// account-recall doctype gap — bank/loan account numbers recur in court
    /// filings (garnishment, financial affidavits) and untyped uploads. The
    /// account context window (AccountDetector requires a label near the digit
    /// run) carries the false-positive load on these broader doctypes; the gate
    /// only governs whether the detector runs at all. `.foia` stays held.
    private static func runsAccount(doctype: DoctypeClass?) -> Bool {
        guard let doctype else { return true }
        return doctype == .financial || doctype == .medical
            || doctype == .court || doctype == .generic
    }

    /// Routing number: financial (primary target) + generic. nil doctype → run.
    /// Suppressed on medical/court/foia — those contexts carry too many
    /// 9-digit document IDs.
    private static func runsRoutingNumber(doctype: DoctypeClass?) -> Bool {
        guard let doctype else { return true }
        return doctype == .financial || doctype == .generic
    }

    // MARK: - Name Detection via NLTagger

    /// Detect names using NLTagger with ALL-CAPS workaround.
    ///
    /// The mixed-case pass runs non-strict (miss is neutral — baseline
    /// 0.70 stays). The shadow pass (nerShadow: title-casing + separator
    /// segmentation) runs strict — a candidate absent from both the surname
    /// and given-name blooms is suppressed, which is how we keep ALL-CAPS
    /// recall without letting the looser tokenizer flood the triage list.
    func detectNames(in text: String, doctype: DoctypeClass? = nil) -> [PIIMatch] {
        var results: [PIIMatch] = []
        // Per-page cache of gazetteer verdicts keyed on lowercased candidate
        // text. Bounds the Levenshtein-1 enumeration cost across both passes.
        var verdictCache: [String: NameGazetteer.NameGazetteerVerdict] = [:]

        // Pass 1: Original text (catches mixed-case names). Non-strict.
        results.append(contentsOf: runNLTagger(
            on: text, original: text, strict: false, cache: &verdictCache))

        // Pass 2: NER shadow (surfaces ALL-CAPS and label-glued names).
        // Strict. The shadow preserves
        // UTF-16 offsets position-for-position, so each tagger hit anchors
        // at its own occurrence in `text` (see runNLTagger).
        let shadow = Self.nerShadow(text)
        if shadow != text {
            results.append(contentsOf: runNLTagger(
                on: shadow, original: text, strict: true, cache: &verdictCache))
        }

        // Pass 3: Legal prefix heuristics
        results.append(contentsOf: scanLegalPrefixes(in: text))

        // Pass 4: Label anchors — the deterministic readings of the label
        // slots (a role or field label with its colon, the caption
        // connector). Same confidence as the prefix pass; a tagger row on
        // the same text wins the overlap below.
        results.append(contentsOf: scanLabelAnchors(in: text, doctype: doctype))

        // Deduplicate overlapping name matches across the passes.
        // When multiple passes detect the same text region, keep the match
        // with the higher confidence to avoid duplicate triage entries.
        return Self.deduplicateByRange(results)
    }

    /// Remove name detection results whose NSRanges overlap. When two matches
    /// overlap, the one with higher confidence is retained.
    private static func deduplicateByRange(_ matches: [PIIMatch]) -> [PIIMatch] {
        guard matches.count > 1 else { return matches }
        let sorted = matches.sorted { $0.confidence > $1.confidence }
        var kept: [PIIMatch] = []
        for candidate in sorted {
            let overlaps = kept.contains { existing in
                NSIntersectionRange(existing.range, candidate.range).length > 0
            }
            if !overlaps {
                kept.append(candidate)
            }
        }
        return kept
    }

    #if DEBUG
    /// Test seam: base address of the surname Bloom buffer, or nil
    /// when the name gazetteer is absent from the bundle. Lets DocumentSearcher
    /// prove its process-shared detector reuses one Bloom allocation across
    /// instances. Observation only.
    internal var _testNameBloomBufferAddress: Int? {
        nameGazetteer?.surnameFilter._testBufferBaseAddress
    }
    #endif

    #if DEBUG
    /// Test seam — bind via
    /// `$_nerAvailabilityOverride.withValue(_) { … }` to force
    /// `isNameNERAvailable()` in unit tests. Task-local (NOT a process-global)
    /// so Swift Testing's parallel execution can neither race the value nor
    /// pollute a concurrent test's `loadWithDiagnostics`. DEBUG-only; never
    /// consulted in release builds.
    @TaskLocal static var _nerAvailabilityOverride: Bool?
    #endif

    /// Probe whether the OS-provisioned
    /// `.nameType` NER model is present. `.nameType` requires a downloadable
    /// MobileAsset that is point-release-gated; on a clean install of an in-range
    /// OS where the asset has not been provisioned, `availableTagSchemes(for:.word)`
    /// omits `.nameType` and `enumerateTags(scheme:.nameType)` yields no
    /// `.personalName` tags. Returns true iff names can be NER-detected.
    ///
    /// Side-effect-free: no `requestAssets` download is triggered (that would add a
    /// network-shaped operation the app forbids); read-only against the local asset
    /// catalog. The canary fallback uses a fixed literal name — never document
    /// content.
    static func isNameNERAvailable() -> Bool {
        #if DEBUG
        if let override = _nerAvailabilityOverride { return override }
        #endif
        // PRIMARY: documented read-only query — no download, zero networking.
        if NLTagger.availableTagSchemes(for: .word, language: .english).contains(.nameType) {
            return true
        }
        // FALLBACK: a synchronous tag pass over a fixed canonical English name. If
        // the primary query is conservative on some build but the model in fact
        // tags, this confirms availability without a network fetch.
        let canary = "Michael Johnson"            // fixed literal — not document content
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = canary
        tagger.setLanguage(.english, range: canary.startIndex..<canary.endIndex)
        var sawName = false
        tagger.enumerateTags(in: canary.startIndex..<canary.endIndex,
                             unit: .word, scheme: .nameType) { tag, _ in
            if tag == .personalName { sawName = true; return false }
            return true
        }
        return sawName
    }

    private func runNLTagger(
        on text: String,
        original: String,
        strict: Bool,
        cache: inout [String: NameGazetteer.NameGazetteerVerdict]
    ) -> [PIIMatch] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var results: [PIIMatch] = []

        let originalNS = original as NSString
        // Production invariant: Pass 1 passes
        // `original` itself and Pass 2 passes `nerShadow(original)`, which
        // substitutes and case-folds in place without inserting or removing
        // UTF-16 units — so a tagger range on `text` indexes `original`
        // directly. Only the DEBUG test seam can supply a cross-length pair.
        let offsetsAligned = (text as NSString).length == originalNS.length

        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .nameType) { tag, range in
            if tag == .personalName {
                let name = String(text[range])
                guard name.count >= 2 else { return true }
                // A whole-candidate stop token (`nameStopTokens`) is never a
                // name by itself, whatever the tagger says of it.
                guard !Self.nameStopTokens.contains(name) else { return true }
                // `range` indexes `text` (the `on:` string),
                // but the redaction box must index `original`. Anchor at THIS
                // tag's own offset: a from-zero `range(of:)` search resolves
                // every repeat of the same name to its first occurrence, so N
                // occurrences collapse to one box and repeats ship unredacted.
                let shadowRange = NSRange(range, in: text)
                let nsRange: NSRange
                if offsetsAligned, NSMaxRange(shadowRange) <= originalNS.length {
                    nsRange = shadowRange
                } else {
                    // Seam-only path (cross-length `on:`/`original:` pair):
                    // legacy first-occurrence search — imprecise for repeats
                    // but in-bounds and non-fatal.
                    let foundInOriginal = originalNS.range(
                        of: name,
                        options: [.caseInsensitive],
                        range: NSRange(location: 0, length: originalNS.length)
                    )
                    nsRange = foundInOriginal.location != NSNotFound
                        ? foundInOriginal
                        : shadowRange
                }
                // Surface the ORIGINAL casing in the match text — the range
                // points at "DELIA", the shadow's "Delia" is the tagger's view.
                let matchedText = NSMaxRange(nsRange) <= originalNS.length
                    ? originalNS.substring(with: nsRange)
                    : name

                // Consult gazetteer if available. Cache keyed on
                // lowercased name so both passes pay the Levenshtein-1
                // enumeration cost at most once per unique candidate.
                let verdict: NameGazetteer.NameGazetteerVerdict
                if let gazetteer = nameGazetteer {
                    let cacheKey = name.lowercased()
                    if let cached = cache[cacheKey] {
                        verdict = cached
                    } else {
                        verdict = gazetteer.queryBoosted(candidate: name, fuzzy: !strict)
                        cache[cacheKey] = verdict
                    }
                } else {
                    verdict = .none
                }

                // Inventory gate on BOTH tagger passes. The strict (ALL-CAPS
                // shadow) pass suppresses candidates the gazetteer didn't
                // recognize at all (`hadAnyHit`); the first pass suppresses
                // candidates the inventory does not SUPPORT (`hadSupport`:
                // an exact surname hit that is not a curated common word, or
                // a fuzzy hit) — the mirror of the strict gate, so a
                // Title-case pair the inventory has never seen no longer
                // surfaces at 0.70 on the tagger's word alone. The prefix
                // pass is untouched. nil-gazetteer → fall through so
                // stripped-bundle environments keep the same behavior.
                // `unit: .word` delivers one-word candidates
                // and `queryBoosted` treats a lone token as a surname query,
                // so a given-name word ("Delia") tagged on a transaction line
                // would be suppressed even once the tagger sees it. Accept a
                // single-token candidate present in the given-name bloom on
                // either pass; the boost table is unchanged (given-only
                // carries no boost).
                var givenNameOnlyHit = false
                if let gazetteer = nameGazetteer,
                   strict ? !verdict.hadAnyHit : !verdict.hadSupport {
                    givenNameOnlyHit = !name.contains(" ")
                        && gazetteer.contains(givenName: name)
                    if !givenNameOnlyHit {
                        return true
                    }
                }

                var signals: [MatchRationale.Signal] = [.regexPattern(name: "name.nltagger")]
                if verdict.surnameHit { signals.append(.bloomSurnameHit) }
                if verdict.givenHit || givenNameOnlyHit { signals.append(.bloomGivenHit) }
                if verdict.fuzzySurnameHit {
                    signals.append(.bloomFuzzySurnameHit(score: verdict.fuzzyScore ?? 0.6))
                }

                let confidence = 0.70 + verdict.boost
                let rationale = MatchRationale(
                    ruleID: "name.nltagger",
                    signals: signals,
                    preThresholdScore: 0.70,
                    finalScore: confidence
                )
                results.append(PIIMatch(text: matchedText, range: nsRange, kind: .name,
                                       confidence: confidence, rationale: rationale))
            }
            return true
        }
        return results
    }

    // MARK: - Name Stop Tokens

    /// Tokens the name path never surfaces as a name candidate on their own.
    /// Exact, case-sensitive, whole-candidate equality — nothing looser: a
    /// name that follows a role noun still surfaces (the prefix pass exists
    /// for that), the bare role noun never does. Two measured units: the five
    /// court and licence label tokens the tagger reads as given names when
    /// they open a sentence or a label ("Plaintiff is a corporation, Business
    /// Registration # …", "Reg # …", the "PP" / "Lic" / "DL" document labels),
    /// then the five furniture tokens — the honorific with and without its
    /// period, two role nouns and the legal opener — that the tagger and the
    /// prefix pass surface alone on furniture-dense pages ("Dr." before a
    /// line break, "Patient reports …", "Pursuant to …", "Counsel for …").
    /// Each unit was added together and measured together on the synthetic
    /// corpus and its furniture profiles, where it removes label and
    /// furniture false positives and changes no true positive. Any addition
    /// is its own measured change, never a quiet edit here. Checked before
    /// the gazetteer query on both tagger passes and on the prefix pass's
    /// assembled name.
    static let nameStopTokens: Set<String> = [
        "Plaintiff", "Reg", "PP", "Lic", "DL",
        "Dr.", "Dr", "Patient", "Pursuant", "Counsel",
    ]

    // MARK: - Legal Prefix Heuristics

    private static let legalPrefixes = [
        "Mr.", "Ms.", "Mrs.", "Dr.", "Judge", "Plaintiff", "Defendant",
        "Appellant", "Respondent", "Patient", "Witness",
        "Attorney", "Counsel", "Prof.", "Professor", "Officer", "Agent",
        "Senator", "Rep.", "Honorable", "Reverend", "Rev."
    ]

    /// True when the text right after a prefix hit opens with a sentence
    /// boundary: optional horizontal whitespace, one of `.` `;` `:`, optional
    /// horizontal whitespace, then a line break. Anything else — a name, a
    /// bare line break, a comma, a dash — is not a boundary.
    private static func sentenceBoundaryOpens(_ window: String) -> Bool {
        var sawTerminator = false
        for ch in window {
            if ch == " " || ch == "\t" { continue }
            if ch.isNewline { return sawTerminator }
            if !sawTerminator, ch == "." || ch == ";" || ch == ":" {
                sawTerminator = true
                continue
            }
            return false
        }
        return false
    }

    private func scanLegalPrefixes(in text: String) -> [PIIMatch] {
        var results: [PIIMatch] = []
        let nsText = text as NSString

        for prefix in Self.legalPrefixes {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while true {
                let found = nsText.range(of: prefix, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }

                // Look for the word(s) following the prefix. Strip leading
                // whitespace AND the punctuation marks that commonly sit
                // between a legal/medical prefix and the name (e.g.
                // "Patient: Maria Johnson", "Plaintiff, John Doe",
                // "Witness — Jane Smith"). Without this the colon/comma
                // becomes the first "word" and the uppercase-prefix scan
                // bails before it reaches the name.
                let afterPrefix = found.length + found.location
                let remaining = nsText.length - afterPrefix
                guard remaining > 1 else { break }

                let afterRange = NSRange(location: afterPrefix, length: min(50, remaining))
                let trimSet = CharacterSet.whitespacesAndNewlines
                    .union(CharacterSet(charactersIn: ":,;.-—–"))
                let window = nsText.substring(with: afterRange)
                // A sentence boundary right after the prefix — `.` / `;` / `:`
                // and then a line break — ends the reading before the trim:
                // the next line's first capitalised word opens a new sentence
                // and is not the name after the prefix. A bare line break or
                // same-line punctuation still reaches the trim below.
                let afterText = Self.sentenceBoundaryOpens(window)
                    ? ""
                    : window.trimmingCharacters(in: trimSet)

                // Extract first 1-3 capitalized words
                let words = afterText.split(separator: " ", maxSplits: 3)
                let nameWords = words.prefix(while: { word in
                    guard let first = word.first else { return false }
                    return first.isUppercase
                })
                let name = nameWords.joined(separator: " ")
                // An empty assembly or a stop token standing alone after the
                // prefix is not a name; the scan moves on to the next prefix hit.
                if !nameWords.isEmpty, !Self.nameStopTokens.contains(name) {
                    // `afterText` was trimmed of leading punctuation/
                    // whitespace, but `afterPrefix` still points at the first
                    // trimmed char, so the name range was left-shifted by the
                    // leading-trim width (e.g. the ": " in "Patient: Maria").
                    // Recover the true start from the first non-trim character in
                    // the window. This measures the LEADING trim only; a
                    // window-length-minus-trimmed-length width would also absorb
                    // any TRAILING trim and push the box past the name when the
                    // 50-char window ends on punctuation/whitespace.
                    let firstNonTrim = nsText.rangeOfCharacter(
                        from: trimSet.inverted, options: [], range: afterRange
                    )
                    let nameStart = firstNonTrim.location != NSNotFound
                        ? firstNonTrim.location
                        : afterPrefix
                    let nameRange = NSRange(location: nameStart, length: (name as NSString).length)
                    results.append(PIIMatch(text: name, range: nameRange, kind: .name,
                                           confidence: 0.65))
                }

                searchRange = NSRange(location: found.location + found.length,
                                     length: nsText.length - found.location - found.length)
            }
        }
        return results
    }

    // MARK: - Label Anchor Routes

    /// Confidence of every label-anchor match: the prefix pass's number. The
    /// conservative preset's cutoff drops them by design. The routes sit
    /// outside the inventory gate, as the prefix pass does, and say so
    /// through their own rule id and route signal.
    static let labelAnchorConfidence = 0.65

    /// Rule id every label-anchor match carries; the rationale's pattern
    /// signal names the route (`name.label-anchor.<route>`).
    static let labelAnchorRuleID = "name.label-anchor"

    /// Tokens that mark a capitalised run as an organisation rather than a
    /// person (case-folded, trailing period stripped). A candidate holding
    /// any of them is not read: in `Marcus Bellamy v. Sablebrook Holdings
    /// Inc.` only the left party is a name.
    static let organizationMarkers: Set<String> = [
        "inc", "incorporated", "corp", "corporation", "co", "company",
        "llc", "llp", "lp", "ltd", "limited", "plc", "pllc", "group",
        "holdings", "bank", "trust", "association", "partners",
        "partnership", "industries", "enterprises", "hospital", "clinic",
        "university", "college", "school", "county", "city", "state",
        "department", "board", "commission", "agency", "authority",
        "district", "bureau", "office", "services", "systems", "solutions",
        "technologies", "insurance", "foundation", "institute", "center",
        "fund", "union", "council", "court", "estate", "united", "national",
        "federal", "government", "unit", "division", "section", "branch",
        "team", "desk", "program",
    ]

    /// The caption connector between two parties, read case-folded and
    /// bounded by horizontal whitespace on both sides.
    private static let captionConnectors = ["v.", "vs."]

    /// A candidate a route read: one to three capitalised tokens on one line.
    private struct AnchorCandidate {
        let text: String
        let range: NSRange
        let tokens: [String]
    }

    private static let anchorTokenJoiners = CharacterSet(charactersIn: "'\u{2019}-.")

    private static func scalar(_ u: unichar) -> UnicodeScalar? { UnicodeScalar(u) }
    private static func isAnchorLetter(_ u: unichar) -> Bool {
        scalar(u).map { CharacterSet.letters.contains($0) } ?? false
    }
    private static func isAnchorUppercase(_ u: unichar) -> Bool {
        scalar(u).map { CharacterSet.uppercaseLetters.contains($0) } ?? false
    }
    private static func isAnchorAlphanumeric(_ u: unichar) -> Bool {
        scalar(u).map { CharacterSet.alphanumerics.contains($0) } ?? false
    }
    private static func isAnchorTokenChar(_ u: unichar) -> Bool {
        scalar(u).map { CharacterSet.letters.contains($0) || anchorTokenJoiners.contains($0) } ?? false
    }
    private static func isHorizontalSpace(_ u: unichar) -> Bool { u == 0x20 || u == 0x09 }

    /// Read forwards from `start`: skip horizontal whitespace, then take up
    /// to three tokens, each a maximal run of letters, apostrophes, hyphens
    /// and periods that opens with an uppercase letter, separated by
    /// horizontal whitespace only. A comma, a colon, a digit, a lowercase
    /// token or the line's end closes the reading.
    private static func readCandidate(
        forwardFrom start: Int, lineEnd: Int, in ns: NSString, minTokens: Int
    ) -> AnchorCandidate? {
        var i = start
        while i < lineEnd, isHorizontalSpace(ns.character(at: i)) { i += 1 }
        var ranges: [NSRange] = []
        while ranges.count < 3 {
            guard i < lineEnd, isAnchorUppercase(ns.character(at: i)) else { break }
            var j = i
            while j < lineEnd, isAnchorTokenChar(ns.character(at: j)) { j += 1 }
            ranges.append(NSRange(location: i, length: j - i))
            var k = j
            while k < lineEnd, isHorizontalSpace(ns.character(at: k)) { k += 1 }
            guard k > j else { break }
            i = k
        }
        return assemble(ranges, in: ns, minTokens: minTokens)
    }

    /// Read backwards from `end` (exclusive): the mirror of the forward
    /// reading, so the tokens closest to the anchor are taken first.
    private static func readCandidate(
        backwardFrom end: Int, lineStart: Int, in ns: NSString, minTokens: Int
    ) -> AnchorCandidate? {
        var i = end
        while i > lineStart, isHorizontalSpace(ns.character(at: i - 1)) { i -= 1 }
        var ranges: [NSRange] = []
        while ranges.count < 3 {
            guard i > lineStart, isAnchorTokenChar(ns.character(at: i - 1)) else { break }
            var j = i
            while j > lineStart, isAnchorTokenChar(ns.character(at: j - 1)) { j -= 1 }
            guard isAnchorUppercase(ns.character(at: j)) else { break }
            ranges.insert(NSRange(location: j, length: i - j), at: 0)
            var k = j
            while k > lineStart, isHorizontalSpace(ns.character(at: k - 1)) { k -= 1 }
            guard k < j else { break }
            i = k
        }
        return assemble(ranges, in: ns, minTokens: minTokens)
    }

    /// Join the token ranges into one candidate. A trailing period on a
    /// token of three or more letters is a sentence's, not the name's, and
    /// is left outside the box; an initial (`J.`) or a short suffix (`Jr.`)
    /// keeps its period.
    private static func assemble(_ ranges: [NSRange], in ns: NSString, minTokens: Int) -> AnchorCandidate? {
        guard ranges.count >= minTokens, let first = ranges.first, var last = ranges.last else { return nil }
        let lastText = ns.substring(with: last)
        if lastText.hasSuffix("."), lastText.filter(\.isLetter).count >= 3 {
            last = NSRange(location: last.location, length: last.length - 1)
        }
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var tokens = ranges.map { ns.substring(with: $0) }
        tokens[tokens.count - 1] = ns.substring(with: last)
        return AnchorCandidate(text: ns.substring(with: range), range: range, tokens: tokens)
    }

    /// Words that name a role, an honorific or a generic addressee rather
    /// than a person (case-folded, period-stripped): the legal prefixes, the
    /// stop tokens and the generic addressees, read on EVERY token of a
    /// candidate — `Records Officer` and `Hiring Committee` are titles, not
    /// names, whichever token carries the role word.
    private static let nonPersonTokens: Set<String> = {
        var set = Set<String>()
        for word in legalPrefixes + Array(nameStopTokens) + genericAddressees.flatMap({ $0.split(separator: " ").map(String.init) }) {
            var folded = word.lowercased()
            while folded.hasSuffix(".") { folded.removeLast() }
            if !folded.isEmpty { set.insert(folded) }
        }
        return set
    }()

    /// The candidate is a person's name only if it is not a stop token, does
    /// not open with a legal prefix or a stop token (the prefix pass's
    /// shape), holds no organisation marker and no role, honorific or
    /// generic-addressee word on any token, and carries at least one token
    /// of two or more letters.
    private static func admits(_ candidate: AnchorCandidate) -> Bool {
        guard !nameStopTokens.contains(candidate.text), let first = candidate.tokens.first else { return false }
        guard !legalPrefixes.contains(first), !nameStopTokens.contains(first) else { return false }
        for token in candidate.tokens {
            var folded = token.lowercased()
            while folded.hasSuffix(".") { folded.removeLast() }
            if organizationMarkers.contains(folded) || nonPersonTokens.contains(folded) { return false }
        }
        return candidate.tokens.contains { $0.filter(\.isLetter).count >= 2 }
    }

    private static func anchorMatch(_ candidate: AnchorCandidate, route: String) -> PIIMatch {
        PIIMatch(
            text: candidate.text, range: candidate.range, kind: .name,
            confidence: labelAnchorConfidence,
            rationale: MatchRationale(
                ruleID: labelAnchorRuleID,
                signals: [.regexPattern(name: "\(labelAnchorRuleID).\(route)")],
                preThresholdScore: labelAnchorConfidence,
                finalScore: labelAnchorConfidence
            )
        )
    }

    /// Pass 4 of `detectNames`: the label-anchor routes, one line at a time.
    /// The vocabulary of the label route is the legal prefixes plus the
    /// shipped name positives in scope for `doctype` (the court role words
    /// are court-scoped; with no doctype only the global rows read).
    /// Internal so the routes can be exercised on their own, apart from the
    /// tagger rows that win the overlap in `detectNames`.
    func scanLabelAnchors(in text: String, doctype: DoctypeClass? = nil) -> [PIIMatch] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var labels = Set(Self.legalPrefixes.map { $0.lowercased() })
        if let positives = contextLoader?.positiveKeywords(for: .name, doctype: doctype) {
            labels.formUnion(positives)
        }
        let orderedLabels = labels.sorted()
        var lines: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            lines.append(line)
        }
        var results: [PIIMatch] = []
        for (index, line) in lines.enumerated() where line.length > 0 {
            Self.scanLabelColon(in: ns, line: line, labels: orderedLabels, into: &results)
            Self.scanCaption(in: ns, line: line, into: &results)
            Self.scanClosingLine(in: ns, lines: lines, at: index, into: &results)
            Self.scanSalutation(in: ns, line: line, into: &results)
            Self.scanSubjectLine(in: ns, line: line, into: &results)
        }
        return results
    }

    /// Route 1a — a label from the vocabulary, matched case-folded and
    /// token-bounded (no letter or digit touches it on either side),
    /// optional horizontal whitespace, a colon, then the candidate.
    private static func scanLabelColon(
        in ns: NSString, line: NSRange, labels: [String], into results: inout [PIIMatch]
    ) {
        let lineEnd = NSMaxRange(line)
        for label in labels {
            var search = line
            while search.length > 0 {
                let hit = ns.range(of: label, options: [.caseInsensitive], range: search)
                guard hit.location != NSNotFound else { break }
                let after = NSMaxRange(hit)
                search = NSRange(location: after, length: lineEnd - after)
                if hit.location > line.location, isAnchorAlphanumeric(ns.character(at: hit.location - 1)) { continue }
                if after < lineEnd, isAnchorAlphanumeric(ns.character(at: after)) { continue }
                var i = after
                while i < lineEnd, isHorizontalSpace(ns.character(at: i)) { i += 1 }
                guard i < lineEnd, ns.character(at: i) == 0x3A else { continue }
                guard let candidate = readCandidate(forwardFrom: i + 1, lineEnd: lineEnd, in: ns, minTokens: 2),
                      admits(candidate) else { continue }
                results.append(anchorMatch(candidate, route: "label-colon"))
            }
        }
    }

    /// Route 1b — the caption connector with a candidate read backwards on
    /// its left and forwards on its right; each side is kept on its own.
    private static func scanCaption(in ns: NSString, line: NSRange, into results: inout [PIIMatch]) {
        let lineEnd = NSMaxRange(line)
        for connector in captionConnectors {
            var search = line
            while search.length > 0 {
                let hit = ns.range(of: connector, options: [.caseInsensitive], range: search)
                guard hit.location != NSNotFound else { break }
                let after = NSMaxRange(hit)
                search = NSRange(location: after, length: lineEnd - after)
                guard hit.location > line.location, isHorizontalSpace(ns.character(at: hit.location - 1)),
                      after < lineEnd, isHorizontalSpace(ns.character(at: after)) else { continue }
                if let left = readCandidate(backwardFrom: hit.location, lineStart: line.location, in: ns, minTokens: 2),
                   admits(left) {
                    results.append(anchorMatch(left, route: "caption"))
                }
                if let right = readCandidate(forwardFrom: after, lineEnd: lineEnd, in: ns, minTokens: 2),
                   admits(right) {
                    results.append(anchorMatch(right, route: "caption"))
                }
            }
        }
    }

    /// The closing phrases a letter signs off with, case-folded; the line
    /// that carries one ends with a comma and holds nothing else.
    private static let closingPhrases: Set<String> = [
        "sincerely", "regards", "best regards", "kind regards", "warm regards",
        "respectfully", "respectfully submitted", "yours truly",
        "very truly yours", "cordially", "best", "thank you", "thanks",
    ]

    /// How many blank lines may sit between the closing phrase and the
    /// signature line (room for a handwritten signature).
    private static let closingLineBlankLimit = 3

    /// True when the line is exactly a closing phrase followed by a comma.
    private static func isClosingPhraseLine(_ ns: NSString, _ line: NSRange) -> Bool {
        let text = ns.substring(with: line).trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix(",") else { return false }
        return closingPhrases.contains(String(text.dropLast()).trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Route 2 — the closing line: the first non-blank line after a
    /// closing-phrase line (at most `closingLineBlankLimit` blank lines
    /// skipped) is read when the candidate opens it and nothing but a
    /// comma-led suffix (`, Esq.`) or a period follows on that line.
    private static func scanClosingLine(
        in ns: NSString, lines: [NSRange], at index: Int, into results: inout [PIIMatch]
    ) {
        guard isClosingPhraseLine(ns, lines[index]) else { return }
        var next = index + 1
        var blanks = 0
        while next < lines.count, blanks <= closingLineBlankLimit {
            let line = lines[next]
            let trimmed = ns.substring(with: line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blanks += 1
                next += 1
                continue
            }
            let lineEnd = NSMaxRange(line)
            guard let candidate = readCandidate(forwardFrom: line.location, lineEnd: lineEnd, in: ns, minTokens: 2),
                  admits(candidate) else { return }
            var i = NSMaxRange(candidate.range)
            while i < lineEnd, isHorizontalSpace(ns.character(at: i)) { i += 1 }
            if i < lineEnd {
                let u = ns.character(at: i)
                guard u == 0x2C || u == 0x2E else { return }   // ',' or '.'
                if u == 0x2E, i + 1 < lineEnd { return }
            }
            results.append(anchorMatch(candidate, route: "closing-line"))
            return
        }
    }

    /// Generic addressees a salutation names instead of a person; a
    /// candidate equal to one of them (case-folded) is not read.
    private static let genericAddressees: Set<String> = [
        "sir", "madam", "sir or madam", "sirs", "customer", "valued customer",
        "member", "colleague", "colleagues", "team", "all", "friend", "friends",
        "parent", "parents", "guardian", "patient", "resident", "homeowner",
        "applicant", "candidate", "hiring manager", "committee", "editor",
        "doctor", "counsel", "client", "employee", "staff", "student",
        "occupant", "taxpayer",
    ]

    /// The subject-line labels, case-folded; the colon follows.
    private static let subjectLabels = ["re", "subject", "regarding"]

    /// Route 4a — the salutation: `Dear` at the line's start, then the
    /// candidate, closed by a comma, a colon or the line's end. A generic
    /// addressee (`Dear Sir or Madam,`) is not a name.
    private static func scanSalutation(in ns: NSString, line: NSRange, into results: inout [PIIMatch]) {
        let lineEnd = NSMaxRange(line)
        var i = line.location
        while i < lineEnd, isHorizontalSpace(ns.character(at: i)) { i += 1 }
        let dear = ns.range(of: "dear", options: [.caseInsensitive, .anchored], range: NSRange(location: i, length: lineEnd - i))
        guard dear.location != NSNotFound else { return }
        let after = NSMaxRange(dear)
        guard after < lineEnd, isHorizontalSpace(ns.character(at: after)) else { return }
        guard let candidate = readCandidate(forwardFrom: after, lineEnd: lineEnd, in: ns, minTokens: 1) else { return }
        var j = NSMaxRange(candidate.range)
        while j < lineEnd, isHorizontalSpace(ns.character(at: j)) { j += 1 }
        if j < lineEnd {
            let u = ns.character(at: j)
            guard u == 0x2C || u == 0x3A else { return }   // ',' or ':'
        }
        guard !genericAddressees.contains(candidate.text.lowercased()), admits(candidate) else { return }
        results.append(anchorMatch(candidate, route: "salutation"))
    }

    /// Route 4b — the subject line: `Re:` / `Subject:` / `Regarding:` at
    /// the line's start, and the candidate that CLOSES the line when a
    /// lower-case token stands right before it (`Re: Records pertaining to
    /// Jane Q. Public`); a subject in title case throughout is a title, not
    /// a name, and yields nothing.
    private static func scanSubjectLine(in ns: NSString, line: NSRange, into results: inout [PIIMatch]) {
        let lineEnd = NSMaxRange(line)
        var i = line.location
        while i < lineEnd, isHorizontalSpace(ns.character(at: i)) { i += 1 }
        var labelled = false
        for label in subjectLabels {
            let hit = ns.range(of: label, options: [.caseInsensitive, .anchored], range: NSRange(location: i, length: lineEnd - i))
            guard hit.location != NSNotFound else { continue }
            var k = NSMaxRange(hit)
            while k < lineEnd, isHorizontalSpace(ns.character(at: k)) { k += 1 }
            if k < lineEnd, ns.character(at: k) == 0x3A { labelled = true; i = k + 1; break }
        }
        guard labelled else { return }
        // The line's tail: drop trailing whitespace and one closing period.
        var end = lineEnd
        while end > i, isHorizontalSpace(ns.character(at: end - 1)) { end -= 1 }
        if end > i, ns.character(at: end - 1) == 0x2E {
            // A period that closes an initial or a suffix stays; a sentence's is dropped.
            var t = end - 1
            while t > i, isAnchorLetter(ns.character(at: t - 1)) { t -= 1 }
            if end - 1 - t >= 3 { end -= 1 }
        }
        guard let candidate = readCandidate(backwardFrom: end, lineStart: i, in: ns, minTokens: 2), admits(candidate) else { return }
        // The token before the candidate must be a lower-case word.
        var p = candidate.range.location
        while p > i, isHorizontalSpace(ns.character(at: p - 1)) { p -= 1 }
        guard p > i, p < candidate.range.location, isAnchorLetter(ns.character(at: p - 1)) else { return }
        var q = p
        while q > i, isAnchorTokenChar(ns.character(at: q - 1)) { q -= 1 }
        guard !isAnchorUppercase(ns.character(at: q)) else { return }
        results.append(anchorMatch(candidate, route: "subject-line"))
    }

    // MARK: - ALL-CAPS Title-Casing

    private static let acronymWhitelist: Set<String> = [
        "FBI", "CIA", "SSN", "EIN", "DOJ", "DOD", "IRS", "SEC", "FTC",
        "LLC", "INC", "LLP", "DBA", "AKA", "DOB", "SSA", "ICE", "DEA",
        "ATF", "TSA", "FAA", "EPA", "FDA", "OSHA", "HIPAA", "FOIA",
        "USA", "NYC", "PDF", "OCR", "PII"
    ]

    /// Separator characters that glue name tokens to transaction-line labels
    /// (`INDN:DELIA`, `PAYMENT TO DELIA HARTWELL,CHECKING`). Substituted with
    /// a space in the NER shadow so the tagger sees word boundaries. `.` is
    /// deliberately absent: abbreviations and decimal amounts rely on it, and
    /// the observed leak class is label-glued colons/commas, not periods.
    private static let nerShadowSeparators: Set<Character> = [":", ";", ",", "/"]

    /// Build the Pass-2 NER shadow.
    ///
    /// The legacy single-space-split title-casing this replaced title-cased
    /// a label-glued token (`INDN:DELIA`) to `Indn:delia`, so the embedded
    /// name never surfaced as a taggable word; its space-run collapse also
    /// drifted shadow offsets away from the original. This shadow instead:
    /// - substitutes separator punctuation (`nerShadowSeparators`) with a
    ///   space, so glued tokens segment into words the tagger can see;
    /// - treats all whitespace (including newlines and tabs) as word
    ///   boundaries, so line breaks do not glue words;
    /// - title-cases ALL-CAPS words per character, keeping the first letter
    ///   of every letter run uppercase (`O'BRIEN` → `O'Brien`, `MARY-JANE` →
    ///   `Mary-Jane`) and preserving whitelisted acronyms;
    /// - does not insert, remove, or reorder characters: a substitution that
    ///   would change a character's UTF-16 width is skipped, so
    ///   `shadow.utf16.count == text.utf16.count` holds by construction and a
    ///   tagger range on the shadow indexes the original string directly (the
    ///   per-occurrence anchoring invariant consumed by `runNLTagger`).
    static func nerShadow(_ text: String) -> String {
        var chars = Array(text)
        for i in chars.indices where Self.nerShadowSeparators.contains(chars[i]) {
            chars[i] = " "
        }
        var i = 0
        while i < chars.count {
            guard !chars[i].isWhitespace else {
                i += 1
                continue
            }
            var j = i
            while j < chars.count, !chars[j].isWhitespace { j += 1 }
            Self.titleCaseAllCapsWordInPlace(&chars, in: i..<j)
            i = j
        }
        return String(chars)
    }

    /// Title-case one shadow word in place. No-ops unless the word is
    /// ALL-CAPS (≥2 characters, contains a letter, equals its own
    /// uppercasing) and is not a whitelisted acronym. Width-changing case
    /// mappings are skipped to preserve the shadow's UTF-16 length invariant.
    private static func titleCaseAllCapsWordInPlace(
        _ chars: inout [Character], in word: Range<Int>
    ) {
        let s = String(chars[word])
        let stripped = s.trimmingCharacters(in: .punctuationCharacters)
        if acronymWhitelist.contains(stripped) { return }
        guard s.count >= 2, s == s.uppercased(),
              s.rangeOfCharacter(from: .letters) != nil else { return }
        var previousWasLetter = false
        for k in word {
            let c = chars[k]
            defer { previousWasLetter = c.isLetter }
            // The first letter of each letter run stays uppercase so
            // apostrophe/hyphen-joined name parts remain tagger-visible.
            guard c.isLetter, previousWasLetter else { continue }
            let lower = String(c).lowercased()
            if lower.count == 1, let lc = lower.first,
               String(c).utf16.count == lower.utf16.count {
                chars[k] = lc
            }
        }
    }

    // MARK: - Reverse Rationale
    //
    // Snippet-as-page contract: the caller supplies a `fullContext` buffer
    // (≤500 chars recommended) that embeds `snippet`. Each private detector
    // runs against the full buffer exactly as it would against a page; the
    // match whose NSRange overlaps the snippet span is the one evaluated.
    // This differs from a real scan in two ways users are told about via
    // the popover footer: (a) cross-page context is absent, (b) N-gram
    // neighbors outside the window are absent.

    /// Score `snippet` through every `PIICategory` detector and return
    /// a `ReverseRationale` explaining why each detector matched or did not.
    /// Read-only — does not mutate state anywhere in the engine.
    @concurrent
    public func reverseRationale(
        for snippet: String,
        fullContext: String,
        doctype: DoctypeClass?,
        thresholdVector: PresetThresholdVector,
        userTerms: UserTermMatcher? = nil
    ) async -> ReverseRationale {
        let nsContext = fullContext as NSString
        let snippetRange = nsContext.range(of: snippet)

        // Snippet missing from context — bail with a stable row-per-category
        // result so the UI does not need a second empty-state branch.
        guard snippetRange.location != NSNotFound else {
            let considered = PIICategory.allCases.map { cat in
                ConsiderationResult(
                    category: cat,
                    ruleID: Self.defaultRuleID(for: cat.piiKind),
                    matched: false,
                    finalScore: nil,
                    threshold: nil,
                    reason: .snippetNotInContext
                )
            }
            return ReverseRationale(
                snippet: snippet,
                contextRange: NSRange(location: NSNotFound, length: 0),
                considered: considered,
                doctypeGatedOut: []
            )
        }

        let contextRange = NSRange(location: 0, length: nsContext.length)
        var considered: [ConsiderationResult] = []
        var gatedOut: [PIICategory] = []

        for cat in PIICategory.allCases {
            let result = considerCategory(
                cat,
                snippet: snippet,
                snippetRange: snippetRange,
                contextBuffer: nsContext,
                contextRange: contextRange,
                doctype: doctype,
                threshold: thresholdVector.threshold(for: cat),
                userTerms: userTerms
            )
            considered.append(result)
            if result.reason == .doctypeGated {
                gatedOut.append(cat)
            }
        }

        return ReverseRationale(
            snippet: snippet,
            contextRange: snippetRange,
            considered: considered,
            doctypeGatedOut: gatedOut
        )
    }

    /// Default threshold used when the caller's `PresetThresholdVector` has
    /// no wire-name for the category (e.g., `.email`, `.phone`, `.ein`).
    /// Chosen as the Balanced preset's uniform placeholder (0.70) minus a
    /// small cushion so uncalibrated categories aren't artificially harsh.
    private static let defaultReverseRationaleThreshold: Double = 0.5

    private func considerCategory(
        _ category: PIICategory,
        snippet: String,
        snippetRange: NSRange,
        contextBuffer: NSString,
        contextRange: NSRange,
        doctype: DoctypeClass?,
        threshold: Double?,
        userTerms: UserTermMatcher?
    ) -> ConsiderationResult {
        let ruleID = Self.defaultRuleID(for: category.piiKind)
        let effectiveThreshold = threshold ?? Self.defaultReverseRationaleThreshold

        // 1. Doctype-gated out.
        if isDoctypeGatedOut(category: category, doctype: doctype) {
            return ConsiderationResult(
                category: category,
                ruleID: ruleID,
                matched: false,
                finalScore: nil,
                threshold: nil,
                reason: .doctypeGated
            )
        }

        // 2. User never-flag suppression.
        if let matcher = userTerms, matcher.shouldSuppress(snippet) != nil {
            return ConsiderationResult(
                category: category,
                ruleID: ruleID,
                matched: false,
                finalScore: nil,
                threshold: effectiveThreshold,
                reason: .suppressedByUserTerm
            )
        }

        // 3. User always-flag promotion.
        if let matcher = userTerms, matcher.matchesAlwaysFlag(snippet) != nil {
            return ConsiderationResult(
                category: category,
                ruleID: ruleID,
                matched: true,
                finalScore: 1.0,
                threshold: effectiveThreshold,
                reason: .matchedAlwaysFlag
            )
        }

        // 4. Detector run.
        let matches = runDetector(
            for: category,
            context: contextBuffer,
            contextRange: contextRange
        )
        guard let match = matches.first(where: {
            NSIntersectionRange($0.range, snippetRange).length > 0
        }) else {
            return ConsiderationResult(
                category: category,
                ruleID: ruleID,
                matched: false,
                finalScore: nil,
                threshold: effectiveThreshold,
                reason: .noMatch
            )
        }

        // 5. Threshold comparison.
        let score = match.rationale?.finalScore ?? match.confidence
        let matched = score >= effectiveThreshold
        return ConsiderationResult(
            category: category,
            ruleID: match.rationale?.ruleID ?? ruleID,
            matched: matched,
            finalScore: score,
            threshold: effectiveThreshold,
            reason: matched ? .aboveThreshold : .belowThreshold
        )
    }

    /// Mirror of the private `runsXxx(doctype:)` gates used by `detect(...)`.
    /// Categories with no doctype rule return `false`. License Plate mirrors
    /// its forward gate so the reverse-rationale popover reports gating
    /// accurately for every doctype-aware category.
    private func isDoctypeGatedOut(
        category: PIICategory, doctype: DoctypeClass?
    ) -> Bool {
        switch category {
        case .dateOfBirth:   return !families.dateOfBirth.runs(doctype: doctype)
        case .npi:           return !Self.runsNPI(doctype: doctype)
        case .dea:           return !Self.runsDEA(doctype: doctype)
        case .account:       return !Self.runsAccount(doctype: doctype)
        case .routingNumber: return !Self.runsRoutingNumber(doctype: doctype)
        case .medicalRecord: return !families.medicalRecord.runs(doctype: doctype)
        case .licensePlate:  return !families.licensePlate.runs(doctype: doctype)
        default:             return false
        }
    }

    /// Dispatch to the private detector for `category` against the supplied
    /// context buffer. Categories with no v1 detector (License Plate, Other)
    /// return an empty array, yielding `.noMatch` in the caller.
    private func runDetector(
        for category: PIICategory,
        context: NSString,
        contextRange: NSRange
    ) -> [PIIMatch] {
        let textString = context as String
        switch category {
        case .ssn:            return families.ssn.detect(in: context, range: contextRange)
        case .creditCard:     return families.creditCard.detect(in: context, range: contextRange)
        case .email:          return families.email.detect(in: context, range: contextRange)
        case .phone:          return families.phone.detect(in: context, range: contextRange)
        case .ein:            return families.ein.detect(in: context, range: contextRange)
        case .address:        return families.address.detect(in: context, range: contextRange)
        case .dateOfBirth:    return families.dateOfBirth.detect(in: context, range: contextRange)
        case .itin:           return families.itin.detect(in: context, range: contextRange)
        case .driversLicense: return families.driversLicense.detect(in: context, range: contextRange)
        case .passport:       return families.passport.detect(in: context, range: contextRange)
        case .medicalRecord:  return families.medicalRecord.detect(in: context, range: contextRange)
        case .npi:            return npiDetector.detect(in: context, range: contextRange)
        case .dea:            return deaDetector.detect(in: context, range: contextRange)
        case .account:        return accountDetector.detect(in: context, range: contextRange)
        case .routingNumber:  return routingNumberDetector.detect(in: context, range: contextRange)
        case .name:           return detectNames(in: textString)
        case .licensePlate:   return families.licensePlate.detect(in: context, range: contextRange)
        }
    }
}
