import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// ENGINE §6 — Layer-2 OCR-side term-matching boundary discipline (SV-F).
// The per-term boundary flag the byte layers already honor
// (`SensitiveTermAutomaton.tokenFilteredMatches`) applies to the OCR gate
// too, via the String-space mirror `containsTerm`: a boundary-required name
// term cannot substring-match inside an unrelated word read off a raster
// (the "POS inside Deposits" class), while a standalone occurrence still
// raises the term signals. Bare-string terms keep substring semantics.

@Suite("Layer 2 term boundary discipline")
struct Layer2TermBoundaryTests {
    private static func region(_ r: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: r, source: .manual)
    }

    private static func hit(_ text: String, box: CGRect) -> VerificationEngine.OCRHit {
        VerificationEngine.OCRHit(box: box, wordBoxes: [], text: text, confidence: 0.9)
    }

    // Region in the bottom-right; hits placed top-left sit fully outside it.
    private static let pageRegion = region(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
    private static let outsideBox = CGRect(x: 0.05, y: 0.7, width: 0.4, height: 0.05)
    private static let insideBox = CGRect(x: 0.65, y: 0.10, width: 0.2, height: 0.1)

    @Test("containsTerm boundary matrix")
    func containsTermMatrix() {
        let pos = SensitiveTerm(text: "POS", requiresTokenBoundary: true)
        // Embedded in an alphanumeric run — no match, any case.
        #expect(!VerificationEngine.containsTerm("Deposits and Other Credits", pos))
        #expect(!VerificationEngine.containsTerm("a deposit has posted", pos))
        #expect(!VerificationEngine.containsTerm("REPOS", pos))
        #expect(!VerificationEngine.containsTerm("POS1", pos))
        // Bounded occurrences — whitespace, punctuation, text edges, non-ASCII.
        #expect(VerificationEngine.containsTerm("POS PURCHASE PARKVIEW", pos))
        #expect(VerificationEngine.containsTerm("pos purchase", pos))
        #expect(VerificationEngine.containsTerm("POS", pos))
        #expect(VerificationEngine.containsTerm("(POS)", pos))
        #expect(VerificationEngine.containsTerm("éPOS", pos))
        // A later bounded occurrence is found past an embedded one.
        #expect(VerificationEngine.containsTerm("Deposits POS", pos))
        // Substring terms keep the pre-model semantics.
        let phone = SensitiveTerm(text: "800-555-0199")
        #expect(VerificationEngine.containsTerm("call 1-800-555-0199 now", phone))
    }

    @Test("out-of-region embedded match stays quiet; standalone still signals")
    func outOfRegion_boundaryGate() {
        let terms = [SensitiveTerm(text: "POS", requiresTokenBoundary: true)]

        let embedded = VerificationEngine.classifyPageOCR(
            hits: [Self.hit("Deposits and Other Credits", box: Self.outsideBox)],
            pageRegions: [Self.pageRegion], sensitiveTerms: terms)
        #expect(embedded == .textOutsideRegionsOnly,
                "an embedded case-variant must not raise the term-outside signal — got \(embedded)")

        let standalone = VerificationEngine.classifyPageOCR(
            hits: [Self.hit("POS PURCHASE PARKVIEW CINEMA", box: Self.outsideBox)],
            pageRegions: [Self.pageRegion], sensitiveTerms: terms)
        #expect(standalone == .sensitiveTermOutsideRegions,
                "a bounded occurrence keeps the term-outside signal — got \(standalone)")
    }

    @Test("in-region FAIL arm honors the boundary too")
    func inRegion_boundaryGate() {
        let terms = [SensitiveTerm(text: "POS", requiresTokenBoundary: true)]

        let embedded = VerificationEngine.classifyPageOCR(
            hits: [Self.hit("Deposits", box: Self.insideBox)],
            pageRegions: [Self.pageRegion], sensitiveTerms: terms)
        #expect(embedded == .textInRegion,
                "embedded case-variant in-region stays the generic in-region signal — got \(embedded)")

        let standalone = VerificationEngine.classifyPageOCR(
            hits: [Self.hit("POS", box: Self.insideBox)],
            pageRegions: [Self.pageRegion], sensitiveTerms: terms)
        #expect(standalone == .sensitiveTermInRegion,
                "a bounded in-region occurrence still FAILs — got \(standalone)")
    }

    @Test("[String] compatibility overload keeps substring semantics")
    func stringOverload_substringSemantics() {
        let legacy = VerificationEngine.classifyPageOCR(
            hits: [Self.hit("Deposits and Other Credits", box: Self.outsideBox)],
            pageRegions: [Self.pageRegion], sensitiveTerms: ["POS"])
        #expect(legacy == .sensitiveTermOutsideRegions,
                "bare-string terms keep the pre-model substring behavior — got \(legacy)")
    }
}
