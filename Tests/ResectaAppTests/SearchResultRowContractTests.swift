import Testing
import Foundation
import CoreGraphics
import SwiftUI
@testable import ResectaApp
@testable import RedactionEngine

// The search row's (`SearchResultRow`) own contracts: tier-word
// suppression, the spoken tier with its page-only a11y string (search
// rows never speak matched text), and the attributed context window.

@Suite("Search result row — contracts")
@MainActor
struct SearchResultRowContractTests {

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

    // MARK: - Search origin — context-first row

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

    @Test("Search row a11y label: the category word (or the adapter's page-only string), the page, the spoken tier where the row is graded, and 'applied' once marked — never the text")
    func searchRowAccessibilityLabel() {
        let literal = makeSearchResult(matchedText: "123-45-6789")
        #expect(SearchResultRow.accessibilityLabel(for: literal, tier: .high, showsTier: false)
                == "Search match, page 3")
        #expect(SearchResultRow.accessibilityLabel(for: literal, tier: .high, showsTier: false, isApplied: true)
                == "Search match, page 3, applied")

        let pii = makePIIResult()
        let spoken = SearchResultRow.accessibilityLabel(for: pii, tier: .high, showsTier: true)
        #expect(spoken == "SSN, page 1, high confidence")
        #expect(SearchResultRow.accessibilityLabel(for: pii, tier: .high, showsTier: true, isApplied: true)
                == "SSN, page 1, high confidence, applied")
        // Never the matched text, never the window.
        #expect(!spoken.contains("123-45-6789"))
        #expect(!spoken.contains("Taxpayer"))
    }

    @Test("The spoken tier gates on for PII and OCR rows, off for literal text/regex/custom text-layer rows")
    func tierWordSuppression() {
        // PII (absolute bands) → spoken, whichever source.
        #expect(SearchResultRow.showsTierWord(for: makePIIResult()))
        #expect(SearchResultRow.showsTierWord(for: makePIIResult(source: .ocr(confidence: 0.8))))
        // OCR source without a PII grade (floor-relative) → spoken.
        let ocrLiteral = SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "alpha", contextSnippet: "alpha beta",
            source: .ocr(confidence: 0.8), term: "alpha"
        )
        #expect(SearchResultRow.showsTierWord(for: ocrLiteral))
        // Literal text / regex / custom text-layer hits are `.high` by
        // construction → no spoken tier (the bar still renders green).
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

    @Test("Attributed window from the engine range: mono semibold primary run on the wash, base footnote secondary")
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

    @Test("Nil or out-of-bounds range falls back to the first verbatim occurrence")
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

    @Test("No occurrence returns the plain base: one run, no wash")
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

    @Test("The collapsed window clamps to two lines through XXL and three from XXXL up")
    func collapsedLineLimitByTypeSize() {
        #expect(SearchResultRow.collapsedLineLimit(for: .large) == 2)
        #expect(SearchResultRow.collapsedLineLimit(for: .xxLarge) == 2)
        #expect(SearchResultRow.collapsedLineLimit(for: .xxxLarge) == 3)
        #expect(SearchResultRow.collapsedLineLimit(for: .accessibility1) == 3)
        #expect(SearchResultRow.collapsedLineLimit(for: .accessibility5) == 3)
    }

    @Test("The content column's leading inset is the chassis geometry, not a literal; the applied slot counts only when shown")
    func contentColumnLeadingInset() {
        let base = SearchRowConfidenceBar.width + ResectaTokens.Spacing.xs
            + ResectaTokens.TouchTarget.minimum + ResectaTokens.Spacing.sm
        #expect(SearchResultRow.contentColumnLeadingInset(isApplied: false) == base)
        #expect(SearchResultRow.contentColumnLeadingInset(isApplied: false) == 60)
        #expect(SearchResultRow.contentColumnLeadingInset(isApplied: true)
                == base + SearchResultRow.appliedIndicatorWidth)
        #expect(SearchResultRow.contentColumnLeadingInset(isApplied: true) == 72)
    }
}
