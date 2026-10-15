import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import RedactionEngine

extension VerificationEngineTests {

    // MARK: - Layer 2: Region-Scoped OCR

    // -- Pure helper units (no Vision) --------------------------------------

    @Test("classifyPageOCR: text only outside regions → textOutsideRegionsOnly")
    func classifyPageOCR_textOutsideRegions() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.05, y: 0.85, width: 0.3, height: 0.08),
            wordBoxes: [], text: "INCOME", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: [])
        #expect(verdict == .textOutsideRegionsOnly)
    }

    @Test("classifyPageOCR: no regions → text is outside (never in-region)")
    func classifyPageOCR_emptyRegions() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1),
            wordBoxes: [], text: "anything", confidence: 0.9)
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [], sensitiveTerms: ["anything"])
        // With no regions the hit can never be IN-region; because its text
        // matches a sensitive term, the out-of-region TERM signal now outranks
        // the generic outside-only verdict (both are "not in-region").
        #expect(verdict == .sensitiveTermOutsideRegions)
    }

    @Test("classifyPageOCR: sensitive term readable outside every region → sensitiveTermOutsideRegions")
    func classifyPageOCR_termOutsideRegion() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.05, y: 0.85, width: 0.3, height: 0.08),
            wordBoxes: [], text: "ACME-SECRET", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: ["acme-secret"])
        #expect(verdict == .sensitiveTermOutsideRegions)
    }

    @Test("classifyPageOCR: out-of-region term below the FAIL confidence gate → generic outside-only")
    func classifyPageOCR_termOutsideRegion_belowConfidence() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.05, y: 0.85, width: 0.3, height: 0.08),
            wordBoxes: [], text: "ACME-SECRET", confidence: 0.3)
        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
        // Same confidence gate as the in-region term FAIL: a low-confidence
        // (likely misread) match must not raise the term-specific signal.
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: ["acme-secret"])
        #expect(verdict == .textOutsideRegionsOnly)
    }

    @Test("classifyPageOCR: in-region text and a sibling out-of-region term both reach the fold")
    func classifyPageOCR_inRegionBesideTermOutside() {
        let region = manualRegion(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3))
        let inRegion = VerificationEngine.OCRHit(
            box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
            wordBoxes: [], text: "leaked", confidence: 0.9)
        let termOutside = VerificationEngine.OCRHit(
            box: CGRect(x: 0.05, y: 0.85, width: 0.3, height: 0.08),
            wordBoxes: [], text: "ACME-SECRET", confidence: 0.9)
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [inRegion, termOutside], pageRegions: [region],
            sensitiveTerms: ["acme-secret"])
        // On a rasterized page the in-region text is a leak (FAIL) and
        // outranks the term; on a Searchable page the in-region WARN is the
        // weaker signal and the term outside every region folds to ATTENTION.
        #expect(VerificationEngine.pageBucket(for: verdict, effectiveMode: .secureRasterization)
                == .textInRegionSecureRaster, "got \(verdict)")
        #expect(VerificationEngine.pageBucket(for: verdict, effectiveMode: .searchableRedaction)
                == .sensitiveTermOutsideRegions, "got \(verdict)")
    }

    @Test("classifyPageOCR: no hits → none")
    func classifyPageOCR_noHits() {
        let region = manualRegion(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        #expect(VerificationEngine.classifyPageOCR(
            hits: [], pageRegions: [region], sensitiveTerms: []) == .none)
    }

    @Test("classifyPageOCR: plain text inside region → textInRegion (no term)")
    func classifyPageOCR_textInRegion() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
            wordBoxes: [], text: "leaked", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.25, y: 0.25, width: 0.4, height: 0.3))
        #expect(VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: []) == .textInRegion)
    }

    @Test("classifyPageOCR: sensitive term inside region → sensitiveTermInRegion")
    func classifyPageOCR_termInRegion() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.1),
            wordBoxes: [], text: "ACME-SECRET", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.3))
        #expect(VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: ["acme-secret"]) == .sensitiveTermInRegion)
    }

    @Test("classifyPageOCR: term match is case-insensitive")
    func classifyPageOCR_caseInsensitiveTerm() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
            wordBoxes: [], text: "SECRET", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3))
        #expect(VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: ["secret"]) == .sensitiveTermInRegion)
    }

    @Test("classifyPageOCR: a FAIL hit beats a sibling WARN hit (priority)")
    func classifyPageOCR_failBeatsWarn() {
        let region = manualRegion(CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        let warnHit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.25, y: 0.25, width: 0.1, height: 0.05),
            wordBoxes: [], text: "ordinary", confidence: 0.9)
        let failHit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.05),
            wordBoxes: [], text: "ssn-token", confidence: 0.9)
        #expect(VerificationEngine.classifyPageOCR(
            hits: [warnHit, failHit], pageRegions: [region],
            sensitiveTerms: ["ssn-token"]) == .sensitiveTermInRegion)
    }

    @Test("classifyPageOCR: terms shorter than 3 chars are filtered (mirrors Layer 3)")
    func classifyPageOCR_shortTermFiltered() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
            wordBoxes: [], text: "ab", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3))
        // "ab" (< 3) is dropped → in-region text without a valid term → WARN, not FAIL.
        #expect(VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: ["ab"]) == .textInRegion)
    }

    @Test("classifyPageOCR: 2-character CJK name is admitted by the term filter")
    func classifyPageOCR_twoCharCJKTermAdmitted() {
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
            wordBoxes: [], text: "\u{674E}\u{660E}", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3))
        // "李明" is 2 characters but a complete full name — shared
        // isSearchableTerm admits it (mirrors Layer 3).
        #expect(VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region],
            sensitiveTerms: ["\u{674E}\u{660E}"]) == .sensitiveTermInRegion)
    }

    @Test("classifyPageOCR: term gate case fold is locale-pinned (POSIX)")
    func classifyPageOCR_termGateLocalePinned() {
        // Direct pin on the replacement for localizedCaseInsensitiveContains:
        // the fold must not follow the device locale. Under Turkish casing
        // rules lowercase "i" does not fold to "I" (dotless-I class); the
        // POSIX-pinned gate must match regardless of device locale.
        #expect(VerificationEngine.containsTermCaseInsensitive("ACCOUNT ID", "id"))
        #expect(VerificationEngine.containsTermCaseInsensitive("Invoice", "INVOICE"))
        #expect(!VerificationEngine.containsTermCaseInsensitive("résumé", "resume"),
                "case-only fold: diacritic-insensitivity must NOT be added")
    }

    @Test("classifyPageOCR: word boxes flanking a region suppress a false FAIL")
    func classifyPageOCR_wordLevelIntersection() {
        // Line box spans the region (the survivors "JOHN"/"DOE" plus the filled
        // middle); word boxes sit entirely OUTSIDE the region. With line-level
        // intersection this FAILs ("JOHN DOE" ∈ terms); with word-level it must not.
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.10, y: 0.45, width: 0.80, height: 0.10),       // spans region
            wordBoxes: [
                CGRect(x: 0.10, y: 0.45, width: 0.18, height: 0.10),        // "JOHN" — left
                CGRect(x: 0.74, y: 0.45, width: 0.16, height: 0.10)         // "DOE"  — right
            ],
            text: "JOHN DOE", confidence: 0.9)
        let region = manualRegion(CGRect(x: 0.40, y: 0.44, width: 0.18, height: 0.12)) // middle gap
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: ["JOHN DOE"])
        #expect(verdict != .sensitiveTermInRegion, "word-level boxes must not false-FAIL on a bisected term")
        // The surviving words sit outside every region and the hit's text
        // matches a term → the term-specific outside signal (never the FAIL).
        #expect(verdict == .sensitiveTermOutsideRegions)
    }

    // -- Meaningful-containment in-region predicate ---------------------------
    // The any-overlap test (`CGRect.intersects`) counted a still-visible word
    // whose box clips a mid-line region's edge by a sliver as in-region; in
    // Secure Rasterization that is the ONLY thing that can ever touch an opaque
    // region, so every mid-line redaction false-FAILed. The coverage predicate
    // (≥ `inRegionCoverageThreshold` of the OCR box inside a region) keeps a
    // real paint miss while dropping an edge sliver.

    @Test("classifyPageOCR: a neighbour word clipping a region edge is not in-region")
    func classifyPageOCR_edgeClipNotInRegion() {
        // The repro: a mid-line redaction (the filled phone number) whose
        // adjacent still-visible lead-in word's box clips the region's left edge
        // by a sliver. Old predicate → textInRegion (false); coverage → outside.
        let region = manualRegion(CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10))
        let neighbour = VerificationEngine.OCRHit(
            box: CGRect(x: 0.30, y: 0.45, width: 0.16, height: 0.10), // ends at 0.46 — 0.01 past the edge
            wordBoxes: [], text: "Telephone us at", confidence: 1.0)
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [neighbour], pageRegions: [region], sensitiveTerms: [])
        #expect(verdict == .textOutsideRegionsOnly, "a sliver edge clip must not count as in-region")
    }

    @Test("classifyPageOCR: glyphs substantially inside a region still FAIL")
    func classifyPageOCR_paintMissStillInRegion() {
        let region = manualRegion(CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20))
        // A readable token centred inside the region (a fill that missed its target).
        let leaked = VerificationEngine.OCRHit(
            box: CGRect(x: 0.45, y: 0.45, width: 0.08, height: 0.06),
            wordBoxes: [], text: "SECRET", confidence: 0.9)
        #expect(VerificationEngine.classifyPageOCR(
            hits: [leaked], pageRegions: [region], sensitiveTerms: ["secret"]) == .sensitiveTermInRegion)
        // Same geometry, non-sensitive text → still in-region (textInRegion).
        let plain = VerificationEngine.OCRHit(
            box: CGRect(x: 0.45, y: 0.45, width: 0.08, height: 0.06),
            wordBoxes: [], text: "ordinary", confidence: 0.9)
        #expect(VerificationEngine.classifyPageOCR(
            hits: [plain], pageRegions: [region], sensitiveTerms: []) == .textInRegion)
    }

    @Test("classifyPageOCR: sensitive text fully outside regions stays out-of-region")
    func classifyPageOCR_sensitiveOutsideRegions() {
        let region = manualRegion(CGRect(x: 0.60, y: 0.10, width: 0.20, height: 0.20))
        let outside = VerificationEngine.OCRHit(
            box: CGRect(x: 0.05, y: 0.85, width: 0.20, height: 0.05),
            wordBoxes: [], text: "SECRET", confidence: 0.9)
        // The term is sensitive but it is not inside any region → never a FAIL.
        // The verdict is now the term-specific out-of-region signal (still a
        // WARN-tier outcome once folded; a rasterized page surfaces its own arm).
        #expect(VerificationEngine.classifyPageOCR(
            hits: [outside], pageRegions: [region], sensitiveTerms: ["secret"]) == .sensitiveTermOutsideRegions)
    }

    @Test("classifyPageOCR: a sensitive neighbour clipping the edge does not FAIL")
    func classifyPageOCR_sensitiveNeighbourClipNoFail() {
        // Like A1 but the clipping neighbour contains a sensitive term. Old
        // predicate → sensitiveTermInRegion (false FAIL); coverage → outside.
        let region = manualRegion(CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10))
        let neighbour = VerificationEngine.OCRHit(
            box: CGRect(x: 0.30, y: 0.45, width: 0.16, height: 0.10), // clips edge by 0.01
            wordBoxes: [], text: "INDN DELIA HARTWELL CO ID", confidence: 1.0)
        let verdict = VerificationEngine.classifyPageOCR(
            hits: [neighbour], pageRegions: [region], sensitiveTerms: ["hartwell"])
        #expect(verdict != .sensitiveTermInRegion, "edge clip must not raise an in-region term FAIL")
        // The clipped neighbour is out-of-region and its text matches a term,
        // so it carries the term-specific outside signal (never the FAIL).
        #expect(verdict == .sensitiveTermOutsideRegions)
    }

    @Test("classifyPageOCR: coverage exactly at the threshold is in-region (inclusive)")
    func classifyPageOCR_coverageAtThresholdInclusive() {
        // Exact-binary geometry: half the OCR box lies inside the region.
        let region = manualRegion(CGRect(x: 0.50, y: 0.0, width: 0.50, height: 1.0))
        let hit = VerificationEngine.OCRHit(
            box: CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.50),   // right half inside R
            wordBoxes: [], text: "ordinary", confidence: 0.9)
        // overlap = 0.25×0.50 = 0.125; box = 0.50×0.50 = 0.25; fraction = 0.5 → in.
        #expect(VerificationEngine.classifyPageOCR(
            hits: [hit], pageRegions: [region], sensitiveTerms: []) == .textInRegion)
    }

    @Test("coverageFraction: half-overlap = 0.5; disjoint and degenerate = 0")
    func coverageFraction_math() {
        let box = CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.50)
        let halfRegion = CGRect(x: 0.50, y: 0.0, width: 0.50, height: 1.0)
        #expect(VerificationEngine.coverageFraction(of: box, inside: halfRegion) == 0.5)
        let disjoint = CGRect(x: 0.90, y: 0.90, width: 0.05, height: 0.05)
        #expect(VerificationEngine.coverageFraction(of: box, inside: disjoint) == 0.0)
        let degenerate = CGRect(x: 0.25, y: 0.25, width: 0.0, height: 0.0)
        #expect(VerificationEngine.coverageFraction(of: degenerate, inside: halfRegion) == 0.0)
    }

    @Test("layer2RegionSnapshot: sub-threshold slivers dropped, survivors clamped")
    func layer2RegionSnapshot_dropsSliversClampsSurvivors() {
        let sliverW = manualRegion(CGRect(x: 0.5, y: 0.5, width: 0.0005, height: 0.2))
        let sliverH = manualRegion(CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.0005))
        let outOfBounds = manualRegion(CGRect(x: -0.1, y: 0.2, width: 0.5, height: 0.3))
        let snapshot = VerificationEngine.layer2RegionSnapshot([sliverW, sliverH, outOfBounds])
        #expect(snapshot.count == 1, "both slivers dropped, one survivor")
        // Survivor is clamped into [0,1] (origin no longer negative).
        #expect(snapshot.first?.normalizedRect.minX ?? -1 >= 0)
    }
}
