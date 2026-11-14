import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// A row whose check found something and also could not read part of its
// input: the caption under the title, and the Share sheet's lines. Each
// report holds the row as the engine returns it (the engine's case table
// pins the row); these cases pin what the app makes of it.

@Suite("A row's could-not-read part on the results screen and the Share sheet")
struct VerificationRowPartTests {

    static let nbsp = "\u{00A0}"
    static let unread2 = "Page 2 could not be read for this check"

    static func row(_ status: VerificationStatus, _ identity: VerificationLayer, pages: [Int]?,
                    terms: [String]? = nil, lines: [SearchRecheckQueryLine]? = nil, couldNotVerify: Bool = false,
                    part: String? = nil, partPages: [Int]? = nil) -> LayerResult {
        let sentence: String = switch status {
        case .warn(let m), .info(let m), .attention(let m), .fail(let m), .notApplicable(let m): m
        case .pass, .skipped: ""
        }
        return LayerResult(name: identity.rawValue, symbolName: "doc", status: status, shortDescription: sentence,
                           detailDescription: sentence, pageReferences: pages, durationSeconds: 0,
                           reviewTermTexts: terms, layer: identity, queryLines: lines, couldNotVerify: couldNotVerify,
                           couldNotVerifyPart: part, couldNotVerifyPartPages: part == nil ? nil : (partPages ?? []))
    }

    static func report(_ layers: [LayerResult]) -> VerificationReport {
        VerificationReport(layers: layers, overallStatus: .fail("x"), durationSeconds: 0)
    }

    static func caption(_ layer: LayerResult) -> String? {
        VerificationRowModel.caption(for: layer, outcome: VerificationRowModel.outcome(for: layer, perPageModes: []))
    }

    // MARK: - The two cases beside the engine table

    @Test("a row whose page did not open, an edge graze on another page: the Share line names the unopened page and no other")
    func shareLineNamesTheUnopenedPage() {
        let layer = Self.row(.warn(Self.unread2), .spatialVerification, pages: [1], couldNotVerify: true)
        #expect(DocumentEditorView.couldNotVerifyItemLines(report: Self.report([layer]))
                == ["Character Positions: could not verify on\(Self.nbsp)page\(Self.nbsp)2"])
    }

    @Test("a joined row with no page list: the Share line reads could not verify, with no page")
    func shareLineJoinedRowNoPage() {
        let layer = Self.row(.warn("1 term too short to check; Possible sensitive term fragment in output PDF structural data (1 match(es))"),
                             .binaryStringSearch, pages: nil, couldNotVerify: true)
        #expect(DocumentEditorView.couldNotVerifyItemLines(report: Self.report([layer]))
                == ["Terms in Text & Bytes: could not verify"])
    }

    // MARK: - The caption

    @Test("a failed row with the part: the engine's sentence, \"; \", the part")
    func failedCaptionCarriesThePart() {
        let layer = Self.row(.fail("Annotations found on page 1"), .textExtraction, pages: [0],
                             part: Self.unread2, partPages: [1])
        let caption = Self.caption(layer)
        #expect(caption == "Annotations found on page 1; Page 2 could not be read for this check")
        #expect(caption?.count == 68)
    }

    @Test("a needs-review term row with the part: the composed sentence, its final stop dropped at the join, then the part")
    func termCaptionCarriesThePart() {
        let layer = Self.row(.attention("Sensitive term found in decoded text on page 1"), .binaryStringSearch, pages: [0],
                             terms: ["Acme"], part: Self.unread2, partPages: [1])
        let caption = Self.caption(layer)
        #expect(caption == "\u{201C}Acme\u{201D} is still readable on\(Self.nbsp)page\(Self.nbsp)1; Page 2 could not be read for this check")
        #expect(caption?.count == 75)
    }

    @Test("a Search Re-check needs-review row with the part: the composed sentence, then the part")
    func recheckCaptionCarriesThePart() {
        let line = SearchRecheckQueryLine(label: "\u{201C}Delia\u{201D}", foundCount: 2, foundHitCap: false,
                                          appliedCount: 1, remainingCount: 1, route: .textLayer)
        let layer = Self.row(.attention("Re-ran 1 search — 1 match remains on page 1, 1 page could not be checked: 2"),
                             .searchRecheck, pages: [0], terms: ["Delia"], lines: [line],
                             part: "1 page could not be checked: 2", partPages: [1])
        #expect(Self.caption(layer)
                == "Your search \u{201C}Delia\u{201D} still has 1 match on\(Self.nbsp)page\(Self.nbsp)1; 1 page could not be checked: 2")
    }

    @Test("a part that ends in a full stop: the stop stays at the end, and there is none before \"; \"")
    func partKeepsItsFinalStop() {
        let layer = Self.row(.fail("Page 1: a box covers a word whose hidden copy is still in the text layer"), .hiddenWordInk,
                             pages: [0], part: "Page 2: the hidden text could not be matched to the printed words, so its boxes were not checked.",
                             partPages: [1])
        let caption = Self.caption(layer)
        #expect(caption == "Page 1: a box covers a word whose hidden copy is still in the text layer; Page 2: the hidden text could not be matched to the printed words, so its boxes were not checked.")
        #expect(caption?.count == 171)
        #expect(caption?.contains(".;") == false)
    }

    // MARK: - The Share sheet

    @Test("the Share sheet for a failed row with the part: the issue's line, then a could-not-verify line from the part's pages")
    func shareLinesForAFailedRowWithThePart() {
        let layer = Self.row(.fail("Annotations found on page 1"), .textExtraction, pages: [0],
                             part: Self.unread2, partPages: [1])
        #expect(DocumentEditorView.atRiskItemLines(report: Self.report([layer]))
                == ["Text & Annotations in the Redacted PDF: failed on\(Self.nbsp)page\(Self.nbsp)1",
                    "Text & Annotations in the Redacted PDF: could not verify on\(Self.nbsp)page\(Self.nbsp)2"])
    }

    @Test("the Share sheet for a needs-review row whose part names no page: could not verify, with no page")
    func shareLinesForAPartWithNoPage() {
        let layer = Self.row(.attention("Sensitive term found in decoded text on page 1"), .binaryStringSearch, pages: [0],
                             terms: ["Acme"], part: "1 term too short to check", partPages: [])
        #expect(DocumentEditorView.atRiskItemLines(report: Self.report([layer]))
                == ["Terms in Text & Bytes: needs review on\(Self.nbsp)page\(Self.nbsp)1",
                    "Terms in Text & Bytes: could not verify"])
    }

    // MARK: - The pin

    @Test("an issue with no part: the caption and the Share sheet's lines exactly as today")
    func findWithNoPartIsUnchanged() {
        let failed = Self.row(.fail("Annotations found on page 1"), .textExtraction, pages: [0])
        #expect(Self.caption(failed) == "Annotations found on page 1")
        let review = Self.row(.attention("Sensitive term found in decoded text on page 1"), .binaryStringSearch, pages: [0],
                              terms: ["Acme"])
        #expect(Self.caption(review) == "\u{201C}Acme\u{201D} is still readable on\(Self.nbsp)page\(Self.nbsp)1.")
        #expect(DocumentEditorView.atRiskItemLines(report: Self.report([failed, review]))
                == ["Text & Annotations in the Redacted PDF: failed on\(Self.nbsp)page\(Self.nbsp)1",
                    "Terms in Text & Bytes: needs review on\(Self.nbsp)page\(Self.nbsp)1"])
        #expect(DocumentEditorView.couldNotVerifyItemLines(report: Self.report([failed, review])).isEmpty)
    }
}
