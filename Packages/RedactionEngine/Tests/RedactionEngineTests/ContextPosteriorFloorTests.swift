import Foundation
import Testing
@testable import RedactionEngine

// SRCH-S2 — D02-scorer-posterior-F1 (account, P1) + D02-scorer-posterior-F2 (phone, P2).
//
// The learned context scorer (context-scorer.json `fecd89b6`) can drive a
// keyword-confirmed account/phone below the preset gate on a single
// length/separator feature, dropping a structurally-valid match (the
// under-redaction leak). ContextPosteriorFloor re-floors such a match to the raw
// bar it already cleared, sourced from the CONSERVATIVE preset (preset-invariant),
// capped at raw. Raw-bar form (DESIGN-DECISIONS DQ2); pure code — no blob edit.
//
// CORRECTED CUTOFFS: the two member proposals cited account/phone 0.55/0.70/0.85.
// That is WRONG. The SHIPPED `28921a52` preset-thresholds.json is
//   account     aggressive 0.01 / balanced 0.6 / conservative 0.7
//   phone       aggressive 0.55 / balanced 0.7 / conservative 0.75
// so the conservative cutoffs the floor sources are account 0.7 and phone 0.75.
@Suite("ContextPosteriorFloor — under-redaction raw-bar floor")
struct ContextPosteriorFloorTests {

    // MARK: - Wiring constants

    @Test("Floored families are exactly account + phone; the keyword bar is 0.70")
    func wiringConstants() {
        #expect(ContextPosteriorFloor.flooredFamilies == ["account", "phone"])
        #expect(ContextPosteriorFloor.keywordConfirmedRaw == 0.70)
    }

    @Test("Conservative-cutoff resolver reads the shipped 28921a52 conservative vector")
    func conservativeCutoffReadsShippedPreset() {
        // Pins the SHIPPED conservative cutoffs the floor sources (preset-invariant);
        // moves if preset-thresholds.json changes. Corrected values (NOT 0.70/0.85).
        #expect(abs(ContextPosteriorFloor.conservativeCutoff(forWire: "account") - 0.7) < 1e-9)
        #expect(abs(ContextPosteriorFloor.conservativeCutoff(forWire: "phone") - 0.75) < 1e-9)
    }

    // MARK: - Raw-bar arithmetic (the apply helper)

    @Test("Account keyword-confirmed (raw 0.75) floors to conservative 0.7, survives all presets")
    func accountFloorsToConservative() {
        let floored = ContextPosteriorFloor.apply(
            0.0006, family: "account", raw: 0.75,
            conservativeCutoff: ContextPosteriorFloor.conservativeCutoff(forWire: "account"))
        #expect(abs(floored - 0.7) < 1e-9, "min(0.75, 0.7) = 0.7; got \(floored)")
        for cutoff in [0.01, 0.6, 0.7] {   // account aggressive/balanced/conservative
            #expect(floored >= cutoff, "floored account must clear \(cutoff)")
        }
    }

    @Test("Phone keyword-confirmed (raw 0.80) floors to conservative 0.75, survives all presets")
    func phoneFloorsToConservative() {
        let floored = ContextPosteriorFloor.apply(
            0.0006, family: "phone", raw: 0.80,
            conservativeCutoff: ContextPosteriorFloor.conservativeCutoff(forWire: "phone"))
        #expect(abs(floored - 0.75) < 1e-9, "min(0.80, 0.75) = 0.75; got \(floored)")
        for cutoff in [0.55, 0.7, 0.75] {  // phone aggressive/balanced/conservative
            #expect(floored >= cutoff, "floored phone must clear \(cutoff)")
        }
    }

    @Test("A raw below the 0.70 keyword bar does not fire the floor")
    func subBarRawNotFloored() {
        // raw ≈ 0 (a bare digit run the detector did not keyword-confirm): unchanged.
        #expect(ContextPosteriorFloor.apply(0.0006, family: "account", raw: 0.0,
            conservativeCutoff: 0.7) == 0.0006)
        // A bare, no-keyword phone (raw 0.60) is below the bar → stays at its
        // collapsed posterior, NOT re-admitted (the P2 slice the floor closes is
        // the keyword-confirmed separator-less phone, raw 0.80).
        #expect(ContextPosteriorFloor.apply(0.0006, family: "phone", raw: 0.60,
            conservativeCutoff: 0.75) == 0.0006)
    }

    @Test("The floor never lifts a score above the raw bar the detector earned")
    func floorCappedAtRaw() {
        // raw 0.70 (exactly the bar) with conservative 0.75 → capped at raw 0.70.
        let floored = ContextPosteriorFloor.apply(0.1, family: "phone", raw: 0.70,
            conservativeCutoff: 0.75)
        #expect(abs(floored - 0.70) < 1e-9, "capped at raw 0.70, not 0.75; got \(floored)")
    }

    @Test("The floor never lowers an already-higher posterior (no-op max)")
    func floorNoOpWhenPosteriorHigh() {
        // A strong-context / with-separator match already above the floor: unchanged.
        #expect(ContextPosteriorFloor.apply(0.95, family: "account", raw: 0.75,
            conservativeCutoff: 0.7) == 0.95)
        #expect(ContextPosteriorFloor.apply(0.93, family: "phone", raw: 0.80,
            conservativeCutoff: 0.75) == 0.93)
    }

    @Test("Non-floored families (mrn/ein/itin/name/ssn/empty) are returned unchanged")
    func nonFlooredFamiliesUnchanged() {
        for fam in ["mrn", "ein", "itin", "name", "ssn", ""] {
            #expect(ContextPosteriorFloor.apply(0.3, family: fam, raw: 0.95,
                conservativeCutoff: 0.7) == 0.3, "family '\(fam)' is not floored")
        }
    }

    // MARK: - Blob-pinned: the SHIPPED scorer collapses a keyword-confirmed match,
    //         and the floor at the real conservative cutoff re-admits it.

    @Test("Shipped scorer collapses an 8-digit keyword-confirmed account; floor re-admits it")
    func shippedScorerCollapsesAccountThenFloorReadmits() {
        let scorer = ContextScorerWeights.loadFromEngineBundle()
        let calibrated = CalibratedScorer()
        let pageText = "Account #: 12345678"          // 8-digit, keyword-confirmed (raw 0.75)
        let digits = "12345678"
        let range = (pageText as NSString).range(of: digits)
        let match = PIIDetector.PIIMatch(text: digits, range: range, kind: .account, confidence: 0.75)
        let features = contextFeatures(match: match, doctype: .generic,
            effectiveDoctype: .generic, pageText: pageText)
        let contextLogit = scorer.learnedContextLogit(family: "account", features: features)
        let bare = calibrated.posterior(raw: 0.75, priorMean: 0.5, contextLogit: contextLogit)
        // The standardized digit_run_length term collapses the bare posterior below
        // every account preset cutoff (worst case ≈ 0.06 at the closest keyword).
        #expect(bare < 0.7, "bare posterior should be collapsed by the learned term: \(bare)")
        // The floor re-admits it at the conservative cutoff (preset-invariant).
        let floored = ContextPosteriorFloor.apply(bare, family: "account", raw: 0.75,
            conservativeCutoff: ContextPosteriorFloor.conservativeCutoff(forWire: "account"))
        #expect(abs(floored - 0.7) < 1e-9, "re-floored to 0.7; got \(floored)")
        #expect(floored >= bare, "the floor never lowers the posterior")
    }

    @Test("Shipped scorer collapses a separator-less keyword phone; floor re-admits it")
    func shippedScorerCollapsesPhoneThenFloorReadmits() {
        let scorer = ContextScorerWeights.loadFromEngineBundle()
        let calibrated = CalibratedScorer()
        // A separator-less phone next to a phone keyword (raw 0.80, keyword-confirmed).
        let pageText = "Phone: 5551234567"
        let digits = "5551234567"
        let range = (pageText as NSString).range(of: digits)
        let match = PIIDetector.PIIMatch(text: digits, range: range, kind: .phone, confidence: 0.80)
        let features = contextFeatures(match: match, doctype: .generic,
            effectiveDoctype: .generic, pageText: pageText)
        let contextLogit = scorer.learnedContextLogit(family: "phone", features: features)
        let bare = calibrated.posterior(raw: 0.80, priorMean: 0.5, contextLogit: contextLogit)
        // The has_separator penalty collapses the bare posterior below conservative.
        #expect(bare < 0.75, "bare phone posterior should be collapsed: \(bare)")
        let floored = ContextPosteriorFloor.apply(bare, family: "phone", raw: 0.80,
            conservativeCutoff: ContextPosteriorFloor.conservativeCutoff(forWire: "phone"))
        #expect(abs(floored - 0.75) < 1e-9, "re-floored to 0.75; got \(floored)")
        for cutoff in [0.55, 0.7, 0.75] { #expect(floored >= cutoff) }
    }
}
