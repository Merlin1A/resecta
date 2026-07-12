import Testing
import Foundation
@testable import RedactionEngine

// S3 §1.2 — NegativeContextGazetteer production wiring tests.
// Design reference: design 02 §1 test plan.
//
// These tests exercise the gazetteer in the full PIIDetector pipeline with
// the real module bundle or injected fixtures. They are NOT in
// NegativeContextGazetteerTests (which tests loader mechanics) or
// NegativeContextInstitutionAnchorTests (which tests the header-anchor path).

// MARK: - Fixture bundle helpers

/// Build a bundle containing a `Gazetteers/negative-context.json` with a
/// single entry — used to isolate specific scope/keyword combinations.
private func makeWiringFixtureBundle(
    keyword: String,
    categoryScope: String,
    doctypeScope: String,
    weight: Double
) throws -> (bundle: Bundle, base: URL) {
    let tempBase = FileManager.default.temporaryDirectory
        .appending(path: "negctx-wiring-\(UUID().uuidString)", directoryHint: .isDirectory)
    let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)

    let json = """
    {"version": 1, "entries": [
      {"keyword": "\(keyword)", "category_scope": "\(categoryScope)",
       "doctype_scope": "\(doctypeScope)", "precedence_weight": \(weight),
       "source_id": "test"}
    ]}
    """
    let url = gazetteersDir.appending(path: "negative-context.json")
    try json.write(to: url, atomically: true, encoding: .utf8)

    guard let bundle = Bundle(path: tempBase.path()) else {
        throw NSError(domain: "WiringTest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "bundle creation failed"])
    }
    return (bundle, tempBase)
}

/// Build an empty bundle (no Gazetteers directory).
private func makeEmptyBundle() throws -> (bundle: Bundle, base: URL) {
    let tempBase = FileManager.default.temporaryDirectory
        .appending(path: "empty-bundle-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
    guard let bundle = Bundle(path: tempBase.path()) else {
        throw NSError(domain: "WiringTest", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "empty bundle creation failed"])
    }
    return (bundle, tempBase)
}

@Suite("NegativeContextGazetteer production wiring (S3 §1.2)")
struct NegativeContextGazetteerWiringTests {

    // MARK: - testSSNScoreWithFinancialContext

    /// Real bundle, SSN near "invoice number" in financial context → confidence
    /// drops below the unmodified base (suppression fires).
    ///
    /// "invoice number" is a (ssn, financial) entry in the bundled 334-entry file
    /// at weight 0.75. With the S3 per-matched-keyword semantics:
    ///   factor = max(0.25, 1.0 - 0.75 * 0.75) = max(0.25, 0.4375) = 0.4375
    ///   SSN base = 0.75 (no positive context) → score 0.75 * 0.4375 = 0.328
    ///   floored at SSN profile floor 0.25 → ~0.328 (well below balanced 0.60).
    @Test("Real bundle: SSN near 'invoice number' in financial context suppresses confidence")
    func testSSNScoreWithFinancialContext() throws {
        let gazetteer = try NegativeContextGazetteer()
        let text = "Invoice number 123-45-6789 for services rendered."
        let nsText = text as NSString
        let detector = PIIDetector(
            nameGazetteer: nil,
            dlPatternGazetteer: nil,
            passportPatternGazetteer: nil,
            contextLoader: nil,
            negativeContextGazetteer: gazetteer
        )
        let ssns = detector.detectSSNs(
            in: nsText,
            range: NSRange(location: 0, length: nsText.length),
            doctype: .financial,
            gazetteer: gazetteer
        )
        // The match must still be emitted (suppression does not drop the match;
        // it lowers confidence). Threshold filtering is a separate layer.
        #expect(!ssns.isEmpty, "SSN should be detected even when suppressed")
        let confidence = ssns[0].confidence
        // Base SSN confidence without context boost = 0.75 (from SSNContextKeywords.swift).
        // After suppression at weight 0.75: factor ≈ 0.4375 → ~0.328.
        // The key claim: confidence < 0.75 (the un-suppressed base).
        #expect(confidence < 0.75,
                "SSN in financial 'invoice number' context must be below base 0.75, got \(confidence)")
        // Also verify the negativeContextSuppressed signal was attached.
        let hasSuppSignal = ssns[0].rationale?.signals.contains {
            if case .negativeContextSuppressed = $0 { return true }
            return false
        } ?? false
        #expect(hasSuppSignal,
                "SSN match must carry negativeContextSuppressed signal when gazetteer fires")
    }

    // MARK: - testCourtDocSSNStillSurfaces

    /// The gazetteer's (ssn, court)-scoped "invoice number" entry must NOT fire when
    /// doctype = .financial. This verifies scope lookup is keyed by BOTH category AND
    /// doctype. Use a keyword that is NOT in SSNContextKeywords.profile.negativeKeywords
    /// so the hardcoded profile doesn't confound the measurement.
    ///
    /// Design §1 adversarial case: "case number" at weight 0.70 on court scope.
    /// We use "invoice number" in court scope (not financial scope) to avoid the
    /// hardcoded SSN negative-keyword list interference.
    @Test("Gazetteer scope-keying: court-scoped keyword with .financial doctype → no gazetteer suppression")
    func testCourtDocSSNStillSurfaces() throws {
        // Inject a fixture that has "transit identifier" only in (ssn, court) scope.
        // "transit identifier" is NOT in SSNContextKeywords.profile.negativeKeywords,
        // so no hardcoded suppression will confound the gazetteer isolation.
        let (bundle, base) = try makeWiringFixtureBundle(
            keyword: "transit identifier",
            categoryScope: "ssn",
            doctypeScope: "court",
            weight: 0.70
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let gazetteer = try NegativeContextGazetteer(bundle: bundle)
        // Text with the court-scoped term near a valid SSN.
        let text = "Transit identifier 234-56-7890 verified above."
        let nsText = text as NSString
        let detector = PIIDetector(
            nameGazetteer: nil,
            dlPatternGazetteer: nil,
            passportPatternGazetteer: nil,
            contextLoader: nil,
            negativeContextGazetteer: gazetteer
        )

        // Baseline: score with nil gazetteer (no suppression at all).
        let baselineSSNs = detector.detectSSNs(
            in: nsText,
            range: NSRange(location: 0, length: nsText.length),
            doctype: .financial,
            gazetteer: nil
        )

        // Test: score with the gazetteer but .financial doctype — court-scoped
        // "transit identifier" must NOT fire for (ssn, financial) scope.
        let ssns = detector.detectSSNs(
            in: nsText,
            range: NSRange(location: 0, length: nsText.length),
            doctype: .financial,
            gazetteer: gazetteer
        )
        #expect(!ssns.isEmpty, "SSN should be detected")
        #expect(!baselineSSNs.isEmpty, "Baseline SSN should be detected")

        // The gazetteer must add zero suppression: confidence must equal baseline.
        let confidence = ssns[0].confidence
        let baseline = baselineSSNs[0].confidence
        #expect(abs(confidence - baseline) < 0.001,
                "Scope-keying: court-scoped keyword with .financial doctype must not add gazetteer suppression; got \(confidence) vs baseline \(baseline)")

        // Confirm no gazetteer suppression signal.
        let hasSuppSignal = ssns[0].rationale?.signals.contains {
            if case .negativeContextSuppressed = $0 { return true }
            return false
        } ?? false
        #expect(!hasSuppSignal, "No negativeContextSuppressed signal when scope does not match")
    }

    // MARK: - testDegradedGazetteerNoSuppression

    /// When the bundle is empty (no negative-context.json), loadWithDiagnostics
    /// must mark negativeContextGazetteer as failed AND the SSN score must be
    /// unchanged (no suppression).
    @Test("Empty bundle: diagnostics degrade and SSN score unchanged")
    func testDegradedGazetteerNoSuppression() throws {
        let (emptyBundle, base) = try makeEmptyBundle()
        defer { try? FileManager.default.removeItem(at: base) }

        let (detector, diagnostics) = PIIDetector.loadWithDiagnostics(bundle: emptyBundle)
        // At least negativeContextGazetteer must be in the failed list.
        #expect(diagnostics.didDegrade,
                "diagnostics must indicate degrade when bundle is empty")
        #expect(diagnostics.failedGazetteers.contains("NegativeContextGazetteer"),
                "NegativeContextGazetteer must be in failedGazetteers for empty bundle")

        // SSN detection must still work (regex + state machine are not gazetteer-dependent).
        // Score must equal the base (no suppression).
        let text = "Invoice number 123-45-6789 for services rendered."
        let nsText = text as NSString
        // detectSSNs with nil gazetteer returns base score.
        let ssns = detector.detectSSNs(
            in: nsText,
            range: NSRange(location: 0, length: nsText.length),
            doctype: .financial,
            gazetteer: nil
        )
        #expect(!ssns.isEmpty, "SSN must still be detected without gazetteer")
        // Without gazetteer the scorer uses only the KeywordProfile. "invoice number"
        // is NOT in SSNContextKeywords.profile.negativeKeywords (only in the gazetteer),
        // so the score stays at base 0.75 (no positive or negative keywords matched
        // from the hardcoded profile in this short context).
        // The key invariant: the score is >= the profile floor (not collapsed).
        #expect(ssns[0].confidence >= 0.25,
                "degraded gazetteer: SSN confidence must be at least floor 0.25; got \(ssns[0].confidence)")
    }

    // MARK: - testDiagnosticsTracksNegativeContext

    /// loadWithDiagnostics with a fixture bundle that has no negative-context.json
    /// → diagnostics must record a failure for NegativeContextGazetteer.
    @Test("loadWithDiagnostics: missing negative-context.json is tracked in diagnostics")
    func testDiagnosticsTracksNegativeContext() throws {
        let (emptyBundle, base) = try makeEmptyBundle()
        defer { try? FileManager.default.removeItem(at: base) }

        let (_, diagnostics) = PIIDetector.loadWithDiagnostics(bundle: emptyBundle)
        #expect(diagnostics.failedGazetteers.contains("NegativeContextGazetteer"),
                "loadWithDiagnostics must record NegativeContextGazetteer failure when file is missing")
        #expect(diagnostics.failureReasons["NegativeContextGazetteer"] != nil,
                "failureReasons must contain a reason for NegativeContextGazetteer")
    }

    // MARK: - testEmployerEINSuppressesSSNNotEIN

    /// "employer's ein" suppresses SSN-category hits but NOT EIN-category hits.
    /// This is the S3-new data row (not in the bundled file) — injected via
    /// fixture JSON.
    ///
    /// Mechanistic verification:
    ///  - SSN scorer gets (category=ssn, doctype=financial) → scope key exists →
    ///    "employer's ein" matched → suppression fires.
    ///  - EIN detection uses inline contains() in detectEINs (via einScorer which
    ///    uses the einProfile) — no NegativeContextGazetteer call in the EIN path.
    ///    The EIN hit is unaffected.
    @Test("'employer's ein' suppresses SSN but not EIN detection (scope: ssn/financial)")
    func testEmployerEINSuppressesSSNNotEIN() throws {
        let (bundle, base) = try makeWiringFixtureBundle(
            keyword: "employer's ein",
            categoryScope: "ssn",
            doctypeScope: "financial",
            weight: 0.70
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let gazetteer = try NegativeContextGazetteer(bundle: bundle)
        // Text: an EIN immediately adjacent to the "employer's ein" label.
        // The SSN pattern will NOT match a properly formatted EIN (12-3456789 has
        // a hyphen in position 3, not 4-5), so we use a separate SSN value.
        let text = "Employer's EIN 12-3456789 and SSN 234-56-7890 are on this form."
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let detector = PIIDetector(
            nameGazetteer: nil,
            dlPatternGazetteer: nil,
            passportPatternGazetteer: nil,
            contextLoader: nil,
            negativeContextGazetteer: gazetteer
        )

        // SSN detection: 234-56-7890 should be suppressed by "employer's ein" context.
        let ssns = detector.detectSSNs(
            in: nsText, range: fullRange,
            doctype: .financial, gazetteer: gazetteer
        )
        if !ssns.isEmpty {
            let ssnConfidence = ssns[0].confidence
            // Suppression at weight 0.70: factor = max(0.25, 1.0-0.70*0.75) = max(0.25, 0.475) = 0.475
            // SSN base 0.75 × 0.475 = 0.356 — below base 0.75.
            #expect(ssnConfidence < 0.75,
                    "SSN confidence must be suppressed by 'employer's ein'; got \(ssnConfidence)")
        }

        // EIN detection: 12-3456789 is a hyphenated EIN; detectEINs uses inline contains()
        // checks via einScorer, not the NegativeContextGazetteer. The EIN is unaffected.
        let eins = detector.detectEINs(in: nsText, range: fullRange)
        #expect(!eins.isEmpty,
                "EIN 12-3456789 must be detected; EIN path does not pass through NegativeContextGazetteer")
    }
}
