import Foundation
import NaturalLanguage
import OSLog

// PII detection: one detector per family behind `DetectorRegistry`. This
// type runs the families for a page, backfills a rationale on every match,
// loads the corpus with diagnostics and explains a snippet through every
// family (the reverse rationale).

/// Detects PII patterns in OCR text. Stateless, runs on cooperative thread pool.
/// Runs the family detectors in registry order (the regex and structured
/// families, then the name passes) and backfills a rationale on every match.
public struct PIIDetector: Sendable {

    // Negative-context gazetteer wired into the three scored
    // detectors (SSN / MRN / LP). nil = no gazetteer suppression (the correct
    // fail-safe: detection continues without negative-context dampening).
    // Header-anchor path is not yet wired here; `suppressionScore(documentHeader:)`
    // is live in the struct but not called here.
    private let negativeContextGazetteer: NegativeContextGazetteer?

    /// The family detectors in evaluation order (`DetectorRegistry.rows`),
    /// keyed by category for the reverse-rationale explainer. Constructed
    /// once from the loaders the initializer receives.
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

    /// Detect all PII in the given text: every family in the registry's
    /// evaluation order, each behind its own doctype gate.
    ///
    /// `doctype` is an optional context hint. `nil` = run every family
    /// (back-compat for callers without one); when non-nil the gated
    /// families (the DOB path, NPI, DEA, account, routing number, MRN,
    /// licence plate) consult their `runs(doctype:)`.
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
        await detect(in: text, categories: Set(PIICategory.allCases),
                     doctype: doctype, documentHeader: documentHeader)
    }

    /// Detect PII, filtering to only the specified categories: the families
    /// whose category is requested run, in registry order; the others are
    /// skipped (their passes never execute).
    ///
    /// `doctype` and `documentHeader` as in the overload above. A nil doctype
    /// runs every requested family unconditionally (the user-search path has
    /// no doctype context).
    @concurrent
    public func detect(
        in text: String,
        categories: Set<PIICategory>,
        doctype: DoctypeClass? = nil,
        documentHeader: String? = nil
    ) async -> [PIIMatch] {
        let context = DetectionContext(
            text: text, doctype: doctype,
            gazetteer: negativeContextGazetteer, documentHeader: documentHeader
        )
        var results: [PIIMatch] = []
        for family in families.rows
        where categories.contains(family.category) && family.runs(doctype: doctype) {
            results.append(contentsOf: withPerPageTimeout(family.telemetryName(doctype: doctype)) {
                family.detect(in: context)
            })
        }
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
                return match.withRationale(existing.appending(.doctypeGate(doctype: doctype)))
            }
            let ruleID = defaultRuleID(for: match.kind)
            var rationale = MatchRationale.Builder(ruleID: ruleID, preThresholdScore: match.confidence)
            rationale.append(.regexPattern(name: ruleID))
            rationale.append(doctype.map { .doctypeGate(doctype: $0) })
            return match.withRationale(rationale.build(finalScore: match.confidence))
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

    // MARK: - NER availability (the loader's probe)

    #if DEBUG
    /// Test seam: base address of the surname Bloom buffer, or nil
    /// when the name gazetteer is absent from the bundle. Lets DocumentSearcher
    /// prove its process-shared detector reuses one Bloom allocation across
    /// instances. Observation only.
    internal var _testNameBloomBufferAddress: Int? {
        families.name.nameGazetteer?.surnameFilter._testBufferBaseAddress
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

    /// Mirror of the forward gates: true when `category`'s family does not
    /// run on `doctype`. A category with no doctype rule reads `false` (its
    /// family inherits `runs(doctype:) == true`).
    private func isDoctypeGatedOut(
        category: PIICategory, doctype: DoctypeClass?
    ) -> Bool {
        !(families[category]?.runs(doctype: doctype) ?? true)
    }

    /// Run `category`'s family against the supplied context buffer with no
    /// doctype, gazetteer or header (the snippet-as-page contract). A
    /// category no row serves returns an empty array, yielding `.noMatch`
    /// in the caller.
    private func runDetector(
        for category: PIICategory,
        context: NSString,
        contextRange: NSRange
    ) -> [PIIMatch] {
        families[category]?.detect(in: DetectionContext(buffer: context, range: contextRange)) ?? []
    }
}
