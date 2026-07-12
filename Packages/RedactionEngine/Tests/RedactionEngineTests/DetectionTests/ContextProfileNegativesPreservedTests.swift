import Testing
import Foundation
@testable import RedactionEngine

// W-N — V1 negative-keyword preservation regression guard.
//
// Per Q3 DECIDED 2026-04-30 / STRAT §1.5 row 14: the W-N V1 ship is
// positive-only mechanical lift. Only `positiveKeywords:` becomes
// loader-driven (via `ContextKeywordsLoader` → A21); `negativeKeywords:`
// stays engine-side as a `let` constant on each
// `*ContextKeywords.profile`. If a future cleanup PR removes the
// negative arrays without paired A5 expansion (V1.1+),
// `ContextWindowScorer` silently degrades — losing the FP suppression
// that was Agent-2-validated for SSN's 57-entry list. This file is the
// regression guard.
//
// Sunset: when V1.1+ lands A5 absorption per STRAT §1.5 row 14, this
// file is deleted in the same PR that strips the negative arrays.

@Suite("Context profile negatives preserved engine-side (W-N V1 partial-retire scope)")
struct ContextProfileNegativesPreservedTests {

    @Test("V1 negative-keyword arrays remain populated engine-side")
    func negativeArraysStillEngineSide() {
        // Thresholds: verified counts (57 / 11 / 5 / 6 per STRAT §5.1
        // read targets) minus a small slack for benign edits (e.g.
        // single-row dedupe). When V1.1+ A5 absorption lands, this test
        // is deleted, not relaxed.
        #expect(SSNContextKeywords.profile.negativeKeywords.count >= 50,
                "SSN negatives count dropped below 50 — A5 absorption (V1.1+) not landed but negatives removed?")
        #expect(MRNContextKeywords.profile.negativeKeywords.count >= 8,
                "MRN negatives count dropped below 8 — A5 absorption check needed")
        #expect(LicensePlateContextKeywords.profile.negativeKeywords.count >= 4,
                "LP negatives count dropped below 4 — A5 absorption check needed")
    }

    @Test("V1 window/confidence/floor constants remain engine-side on each profile")
    func thresholdConstantsStillEngineSide() {
        // The 4 *ContextKeywords.profile values are KeywordProfile
        // structs; only the `positiveKeywords:` field becomes loader-
        // driven in V1. The remaining fields stay as engine-side
        // constants per Q3 — a future PR that swaps them out without
        // paired calibration will trip this test before it lands.
        for profile in [
            SSNContextKeywords.profile,
            MRNContextKeywords.profile,
            LicensePlateContextKeywords.profile,
        ] {
            #expect(profile.windowRadius == 5,
                    "Per-A1 window radius (±5 tokens) regressed on a *ContextKeywords.profile")
            #expect(profile.baseConfidence > 0.0)
            #expect(profile.boostedConfidence > profile.baseConfidence)
            #expect(profile.floor > 0.0 && profile.floor < profile.baseConfidence)
        }
    }
}
