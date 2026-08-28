import Testing
import Foundation
@testable import RedactionEngine

// `PIIDetector.loadWithDiagnostics(bundle:)` is the explicit-degrade
// loader. When any of the gazetteer / context-keywords resources fail
// to initialize, the diagnostics value records the failure and the detector
// falls back to nil-gazetteer pass-through. Non-gazetteer regex detectors
// (SSN state machine, DEA letter check, etc.) MUST keep returning results so
// the user retains some auto-detection even when the corpus is unavailable.
//
// Acceptance check: force-rename `surnames.bloom` in a fixture build,
// run pipeline, observe banner + toast, observe pipeline completes without
// crash.
//
// The SIGNATURE-COVERED loaders are the five the code actually withholds on
// a failed manifest verification: nameGazetteer, dlPatternGazetteer,
// passportPatternGazetteer, contextKeywordsLoader, negativeContextGazetteer.
// Every other tracker is NOT covered by the gazetteer-manifest signature and
// is excluded from the signature-fail loop (membership =
// `GazetteerLoadDiagnostics.outsideManifestSignature`): documentTypeClassifier,
// nerNameModel, the three Classifier/ quality-asset trackers
// (contextScorerWeights / doctypeTemperature / presetThresholds — see
// AssetLoadDiagnosticsTests), and the three JSON reference tables
// (institutionGazetteer / addressComponentsGazetteer / zipStateTableLoader),
// which load through ungated process-lifetime statics a signature failure
// never reaches. So the empty-bundle signature-fail failure count is 5 even
// though `Gazetteer.allCases.count` is larger.

@Suite("PIIDetector init degraded")
struct PIIDetectorInitDegradedTests {

    @Test("Empty bundle: the five signature-gated loaders fail, listed by kind")
    func testCorruptedBloomFileDegradesAndReportsKind() {
        // An empty Bundle() has no `Gazetteers/` subdirectory, so every
        // loader hits `LoaderError.resourceMissing`. This stands in for the
        // "corrupted bloom file" failure mode: from the
        // app's point of view, "resource missing" and "decode failed" both
        // surface through the same `failedGazetteers` array (the wire
        // mechanism is one of three named cases on each loader).
        let (_, diagnostics) = PIIDetector.loadWithDiagnostics(bundle: Bundle())

        #expect(diagnostics.didDegrade)
        #expect(diagnostics.failedGazetteers.contains("NameGazetteer"),
                "NameGazetteer must appear in failure list when its assets are missing")
        #expect(diagnostics.failedGazetteers.contains("DLPatternGazetteer"))
        #expect(diagnostics.failedGazetteers.contains("PassportPatternGazetteer"))
        #expect(diagnostics.failedGazetteers.contains("ContextKeywordsLoader"))
        #expect(diagnostics.failedGazetteers.contains("NegativeContextGazetteer"))
        // Reclassification: the three reference tables load OUTSIDE the
        // manifest signature (ungated statics keep serving on a signature
        // failure), so a signature-fail bundle must never attribute them.
        #expect(!diagnostics.failedGazetteers.contains("InstitutionGazetteer"))
        #expect(!diagnostics.failedGazetteers.contains("AddressComponentsGazetteer"))
        #expect(!diagnostics.failedGazetteers.contains("ZIPStateTableLoader"))

        // Each failure carries a non-empty reason string. We do not assert
        // on the exact wording (the loaders' error types are independent),
        // only that the diagnostic value preserved the information.
        for name in diagnostics.failedGazetteers {
            let reason = diagnostics.failureReasons[name]
            #expect(reason != nil, "every failed loader must have a reason entry")
            #expect(reason?.isEmpty == false, "reason for \(name) must not be empty")
        }
    }

    @Test("All gazetteers fail: non-gazetteer detectors (SSN, DEA, CC, email) still return results")
    func testAllGazetteersFailDegradesGracefully() async {
        // Same empty-bundle path; this time we exercise the resulting
        // detector against a fixture string that hits every non-gazetteer
        // detector. SSN goes through the state-machine + structural
        // validator (no gazetteer dependency). DEA uses its letter-check
        // detector (no gazetteer). Credit card uses Luhn + prefix. Email
        // uses a static regex.
        let (detector, diagnostics) = PIIDetector.loadWithDiagnostics(bundle: Bundle())
        // The five SIGNATURE-COVERED loaders fail with an empty bundle.
        // Non-signature-covered trackers are excluded from the
        // signature-fail loop, so this stays 5 even as
        // `Gazetteer.allCases.count` grows.
        #expect(diagnostics.failedGazetteers.count == 5,
                "fixture precondition: the five signature-covered loaders must fail with empty bundle")

        let text = """
        Patient: Jane Doe
        SSN: 123-45-6789
        DEA Number: AB1234563
        Card: 4111 1111 1111 1111
        Email: jane@example.com
        """
        // Pass nil doctype so every doctype-aware detector runs (matching
        // the legacy back-compat contract that test fixtures rely on).
        let matches = await detector.detect(in: text)

        // SSN through the state machine — purely engine-side, no gazetteer.
        #expect(matches.contains { $0.kind == .ssn },
                "SSN regex/state-machine must keep producing matches when gazetteers are absent")
        // DEA via DEADetector (letter-check, no gazetteer).
        #expect(matches.contains { $0.kind == .dea },
                "DEA letter-check must keep producing matches when gazetteers are absent")
        // Credit card via Luhn — no gazetteer dependency.
        #expect(matches.contains { $0.kind == .creditCard },
                "Credit card detector must keep producing matches when gazetteers are absent")
        // Email regex — no gazetteer dependency.
        #expect(matches.contains { $0.kind == .email },
                "Email regex must keep producing matches when gazetteers are absent")
    }

    @Test("Partial failure: only the failing loader appears in the diagnostic")
    func testPartialFailureRecordsOnlyFailingLoader() {
        // Compose a diagnostic by hand and round-trip through `appending`.
        // This pins the wire shape that `failedGazetteers` keys are stable
        // (used by `PipelineCoordinator.surfaceGazetteerLoadDiagnostics` and
        // by an eventual audit-log sign-manifest row).
        let diag = GazetteerLoadDiagnostics()
            .appending(.dlPatternGazetteer, reason: "schemaInvariantViolation")

        #expect(diag.didDegrade)
        #expect(diag.failedGazetteers == ["DLPatternGazetteer"])
        #expect(diag.failureReasons["DLPatternGazetteer"] == "schemaInvariantViolation")
        #expect(diag.failureReasons["NameGazetteer"] == nil,
                "non-failing loaders must NOT appear in failureReasons")
    }

    // MARK: - NER name-model availability

    @Test("Appending .nerNameModel flips didDegrade and lists NERNameModel (wiring)")
    func testNERNameModelAppendDrivesDegrade() {
        // Environment-independent proof: the degraded-detection banner fires off `didDegrade`,
        // so appending the NER tracker flips it through the SAME path a corpus
        // failure uses — no new banner, no PipelineCoordinator change.
        let diag = GazetteerLoadDiagnostics()
            .appending(.nerNameModel, reason: "NER name model unavailable")
        #expect(diag.didDegrade)
        #expect(diag.failedGazetteers.contains("NERNameModel"))
        #expect(diag.failureReasons["NERNameModel"] == "NER name model unavailable")
    }

    @Test("Signature-fail path does NOT attribute the NER model")
    func testSignatureFailDoesNotAttributeNER() {
        // The empty bundle short-circuits BEFORE the NER probe runs, and the
        // signature-fail loop excludes .nerNameModel — so regardless of NER
        // availability it must not appear in the failure list. No override needed.
        let (_, diagnostics) = PIIDetector.loadWithDiagnostics(bundle: Bundle())
        #expect(diagnostics.didDegrade, "signature-covered loaders still fail on empty bundle")
        #expect(!diagnostics.failedGazetteers.contains("NERNameModel"),
                "the OS-provisioned NER model is not signature-covered — never attributed to a signature failure")
    }

    @Test("NER absent (override=false) surfaces .nerNameModel via the signature-valid path")
    func testNERAbsentOverrideAppendsViaValidPath() {
        // Uses the no-arg loader (engine `.module`, signature-valid in the test
        // bundle) so execution reaches the point where the probe runs. The task-local
        // binding forces absence within this call; the loader must fold in the NER
        // tracker. (Binding is task-scoped — no concurrent test observes it.)
        let (_, diagnostics) = PIIDetector.$_nerAvailabilityOverride.withValue(false) {
            PIIDetector.loadWithDiagnostics()
        }
        #expect(diagnostics.didDegrade)
        #expect(diagnostics.failedGazetteers.contains("NERNameModel"),
                "override=false must surface the NER model as failed on the signature-valid path")
    }
}
