import Testing
import Foundation
import CoreGraphics
import SwiftUI
@testable import ResectaApp
@testable import RedactionEngine

// The unified row family's adapter contracts: one `FindingRowModel`
// serves BOTH result origins (engine `SearchResult`s and staged
// `DetectionResult`s), carrying each origin's deliberate asymmetries —
// the a11y content policy (detection review rows speak matched text per
// F-7; search rows never do) and the per-origin secondary line.
//
// UXC-45 (D-117): the search row (`SearchResultRow`) went context-first
// and no longer mounts `FindingRow` — the adapter keeps serving its
// page-only a11y string, and the row's own contracts (tier-word
// suppression, the spoken tier, the attributed context window) pin in
// the "Search origin — context-first row" section below. The scan-side
// pins are UNTOUCHED: they are the RB-100 freeze proof for the review
// rows, which still render through `FindingRow`.

@Suite("FindingRow family — adapter contracts")
@MainActor
struct FindingRowFamilyTests {

    private func makeSearchResult(
        matchedText: String = "alpha",
        pageIndex: Int = 2
    ) -> SearchResult {
        SearchResult(
            pageIndex: pageIndex,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: matchedText,
            contextSnippet: "…the \(matchedText) sits here…",
            source: .textLayer,
            term: matchedText
        )
    }

    private func makeDetection(
        kind: DetectionResult.Kind,
        confidence: Double = 0.87,
        matchedText: String? = nil
    ) -> DetectionResult {
        DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.04),
            kind: kind,
            confidence: confidence,
            matchedText: matchedText
        )
    }

    // MARK: - Search origin

    @Test("search adapter — title is matched text, secondary is the context snippet")
    func searchAdapterShape() {
        let result = makeSearchResult()
        let model = FindingRowModel(result: result)
        #expect(model.id == result.id)
        #expect(model.pageIndex == 2)
        #expect(model.title == "alpha")
        #expect(model.titleIsContent)
        #expect(model.secondaryText == result.contextSnippet)
        #expect(model.secondaryIsContent)
        #expect(!model.showsAmbiguousSurnameHint)
    }

    @Test("search adapter — a11y label names the page only, never matched text")
    func searchAdapterAccessibilityPolicy() {
        let model = FindingRowModel(result: makeSearchResult(matchedText: "123-45-6789"))
        #expect(model.accessibilityDescription == "Search match, page 3")
        #expect(!model.accessibilityDescription.contains("123-45-6789"))
    }

    // MARK: - Search origin — context-first row (UXC-45, RB-98..104)

    private func makePIIResult(
        matchedText: String = "123-45-6789",
        snippet: String = "Taxpayer SSN 123-45-6789 on file",
        source: SearchSource = .textLayer,
        confidence: Double = 0.95
    ) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: matchedText,
            contextSnippet: snippet,
            source: source,
            term: "SSN",
            piiCategory: .ssn,
            piiConfidence: confidence,
            rationale: MatchRationale(
                ruleID: "ssn.regex",
                signals: [.regexPattern(name: "ssn")],
                preThresholdScore: confidence,
                finalScore: confidence,
                appliedThreshold: 0.5
            )
        )
    }

    @Test("UXC-45 — search row a11y label: the adapter's page-only string, plus the spoken tier where the meta line shows one")
    func searchRowAccessibilityLabel() {
        let literal = makeSearchResult(matchedText: "123-45-6789")
        #expect(SearchResultRow.accessibilityLabel(for: literal, tier: .high, showsTier: false)
                == "Search match, page 3")

        let pii = makePIIResult()
        let spoken = SearchResultRow.accessibilityLabel(for: pii, tier: .high, showsTier: true)
        #expect(spoken == "Search match, page 1, high confidence")
        // F-7 LAW: never the matched text, never the window.
        #expect(!spoken.contains("123-45-6789"))
        #expect(!spoken.contains("Taxpayer"))
    }

    @Test("UXC-45 (RB-108) — tier word shows on PII and OCR rows, hides on literal text/regex/custom text-layer rows")
    func tierWordSuppression() {
        // PII (absolute bands) → shown, whichever source.
        #expect(SearchResultRow.showsTierWord(for: makePIIResult()))
        #expect(SearchResultRow.showsTierWord(for: makePIIResult(source: .ocr(confidence: 0.8))))
        // OCR source without a PII grade (floor-relative) → shown.
        let ocrLiteral = SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "alpha", contextSnippet: "alpha beta",
            source: .ocr(confidence: 0.8), term: "alpha"
        )
        #expect(SearchResultRow.showsTierWord(for: ocrLiteral))
        // Literal text / regex / custom text-layer hits are `.high` by
        // construction → no tier word (the bar still renders green).
        #expect(!SearchResultRow.showsTierWord(for: makeSearchResult()))
        let custom = SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "alpha", contextSnippet: "alpha beta",
            source: .textLayer, term: "Custom",
            rationale: MatchRationale(
                ruleID: "user.alwaysFlag",
                signals: [.userAlwaysFlag(pattern: "alpha")],
                preThresholdScore: 1.0, finalScore: 1.0, appliedThreshold: nil
            )
        )
        #expect(!SearchResultRow.showsTierWord(for: custom))
        let regex = SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "555-0100", contextSnippet: "Call 555-0100 now",
            source: .textLayer, term: "\\d{3}-\\d{4}",
            rationale: MatchRationale(
                ruleID: "regex", signals: [.regexPattern(name: "phone")],
                preThresholdScore: 1.0, finalScore: 1.0, appliedThreshold: nil
            )
        )
        #expect(!SearchResultRow.showsTierWord(for: regex))
    }

    @Test("UXC-45 — ConfidenceTier.shortLabel is the meta-line word; the descriptor stays the spoken form")
    func tierShortLabel() {
        #expect(SearchResultRow.ConfidenceTier.high.shortLabel == "High")
        #expect(SearchResultRow.ConfidenceTier.medium.shortLabel == "Medium")
        #expect(SearchResultRow.ConfidenceTier.low.shortLabel == "Low")
        #expect(SearchResultRow.ConfidenceTier.high.descriptor == "high confidence")
    }

    @Test("UXC-45 (RB-102) — attributed window from the engine range: mono semibold primary run on the wash, base footnote secondary")
    func attributedWindowFromEngineRange() {
        let match = "d.hartwell@example.net"
        let snippet = "…reach d.hartwell@example.net before the close…"
        let start = snippet.distance(from: snippet.startIndex, to: snippet.range(of: match)!.lowerBound)
        let attributed = SearchResultRow.attributedSnippet(
            snippet, matchRange: start..<(start + match.count), matchedText: match
        )
        let runs = Array(attributed.runs)
        #expect(runs.count == 3)
        guard runs.count == 3 else { return }
        #expect(String(attributed[runs[1].range].characters) == match)
        #expect(runs[1].font == Font.footnote.monospaced().weight(.semibold))
        #expect(runs[1].foregroundColor == Color.primary)
        #expect(runs[1].backgroundColor != nil)
        for base in [runs[0], runs[2]] {
            #expect(base.font == Font.footnote)
            #expect(base.foregroundColor == Color.secondary)
            #expect(base.backgroundColor == nil)
        }
        #expect(String(attributed.characters) == snippet)
    }

    @Test("UXC-45 (RB-102) — nil or out-of-bounds range falls back to the first verbatim occurrence")
    func attributedWindowFallsBackToFirstOccurrence() {
        let snippet = "alpha MATCH beta MATCH"
        for range: Range<Int>? in [nil, 40..<45, -1..<4] {
            let attributed = SearchResultRow.attributedSnippet(snippet, matchRange: range, matchedText: "MATCH")
            let highlighted = attributed.runs.filter { $0.backgroundColor != nil }
            #expect(highlighted.count == 1)
            guard let run = highlighted.first else { continue }
            #expect(String(attributed[run.range].characters) == "MATCH")
            #expect(attributed.characters.distance(from: attributed.startIndex, to: run.range.lowerBound) == 6)
        }
    }

    @Test("UXC-45 (RB-102) — no occurrence returns the plain base: one run, no wash")
    func attributedWindowWithoutOccurrenceIsPlain() {
        let attributed = SearchResultRow.attributedSnippet("alpha beta", matchRange: nil, matchedText: "gamma")
        let runs = Array(attributed.runs)
        #expect(runs.count == 1)
        #expect(runs.first?.backgroundColor == nil)
        #expect(runs.first?.font == Font.footnote)
        #expect(runs.first?.foregroundColor == Color.secondary)
        let empty = SearchResultRow.attributedSnippet("alpha beta", matchRange: nil, matchedText: "")
        #expect(Array(empty.runs).count == 1)
    }

    @Test("RB-113 — the collapsed window clamps to two lines through XXL and three from XXXL up")
    func collapsedLineLimitByTypeSize() {
        #expect(SearchResultRow.collapsedLineLimit(for: .large) == 2)
        #expect(SearchResultRow.collapsedLineLimit(for: .xxLarge) == 2)
        #expect(SearchResultRow.collapsedLineLimit(for: .xxxLarge) == 3)
        #expect(SearchResultRow.collapsedLineLimit(for: .accessibility1) == 3)
        #expect(SearchResultRow.collapsedLineLimit(for: .accessibility5) == 3)
    }

    @Test("UXC-45 — the content column's leading inset is the chassis geometry, not a literal; the applied slot counts only when shown")
    func contentColumnLeadingInset() {
        let base = SearchRowConfidenceBar.width + ResectaTokens.Spacing.xs
            + ResectaTokens.TouchTarget.minimum + ResectaTokens.Spacing.sm
        #expect(SearchResultRow.contentColumnLeadingInset(isApplied: false) == base)
        #expect(SearchResultRow.contentColumnLeadingInset(isApplied: false) == 60)
        #expect(SearchResultRow.contentColumnLeadingInset(isApplied: true)
                == base + SearchResultRow.appliedIndicatorWidth)
        #expect(SearchResultRow.contentColumnLeadingInset(isApplied: true) == 72)
    }

    // MARK: - Detection origin (text kinds)

    @Test("detection adapter — text kind: title is matched text, secondary carries the confidence noun")
    func detectionTextAdapterShape() {
        let det = makeDetection(kind: .pii(.ssn), confidence: 0.97, matchedText: "123-45-6789")
        let model = FindingRowModel(
            page: 0, detection: det, isSelected: false, isAmbiguousSurname: false
        )
        #expect(model.id == det.id)
        #expect(model.title == "123-45-6789")
        #expect(model.titleIsContent)
        // UXC-22 — qualitative descriptor replaces "N% confidence".
        // 0.97 clears the absolute high band (>= 0.9).
        #expect(model.secondaryText == "High confidence")
        #expect(!model.secondaryIsContent)
    }

    @Test("detection adapter — a11y label speaks status, kind, matched text, page, confidence (F-7)")
    func detectionAdapterAccessibilityPolicy() {
        let det = makeDetection(kind: .pii(.ssn), confidence: 0.97, matchedText: "123-45-6789")
        let deselected = FindingRowModel(
            page: 0, detection: det, isSelected: false, isAmbiguousSurname: false
        )
        // F-7 deliberate asymmetry: the review context speaks content.
        // UXC-22 — qualitative descriptor replaces "N% confidence".
        #expect(deselected.accessibilityDescription
                == "Deselected. Social Security Number, 123-45-6789. Page 1. High confidence.")
        let selected = FindingRowModel(
            page: 0, detection: det, isSelected: true, isAmbiguousSurname: false
        )
        #expect(selected.accessibilityDescription.hasPrefix("Selected."))
    }

    @Test("detection adapter — ambiguous-surname hint carries through")
    func detectionAdapterAmbiguousHint() {
        let det = makeDetection(kind: .pii(.name), confidence: 0.71, matchedText: "Avery")
        let model = FindingRowModel(
            page: 0, detection: det, isSelected: false, isAmbiguousSurname: true
        )
        #expect(model.showsAmbiguousSurnameHint)
    }

    // MARK: - Detection origin (non-text kinds)

    @Test("detection adapter — face kind renders its kind name, no content flag")
    func faceAdapterShape() {
        let det = makeDetection(kind: .face, confidence: 0.8, matchedText: nil)
        let model = FindingRowModel(
            page: 1, detection: det, isSelected: false, isAmbiguousSurname: false
        )
        #expect(model.title == DetectionResult.Kind.face.fullName)
        #expect(!model.titleIsContent)
        // UXC-22 — qualitative descriptor replaces "N% confidence".
        // 0.8 sits in the absolute medium band (>= 0.7, < 0.9).
        #expect(model.secondaryText == "Medium confidence")
        // No matched text → the a11y label has no content clause.
        #expect(model.accessibilityDescription
                == "Deselected. \(DetectionResult.Kind.face.fullName). Page 2. Medium confidence.")
    }

    @Test("detection adapter — signature candidate and barcode render their kind names honestly")
    func nonTextKindAdapterShapes() {
        for kind: DetectionResult.Kind in [.pii(.signatureCandidate), .pii(.barcode)] {
            let det = makeDetection(kind: kind, confidence: 0.66, matchedText: nil)
            let model = FindingRowModel(
                page: 0, detection: det, isSelected: false, isAmbiguousSurname: false
            )
            #expect(model.title == kind.fullName)
            #expect(!model.titleIsContent)
            // UXC-22 — qualitative descriptor replaces "N% confidence".
            // 0.66 is below the absolute medium floor (< 0.7).
            #expect(model.secondaryText == "Low confidence")
        }
    }
}
