import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// `LayerResultRow`'s row style, chrome and expandability seams: a clean
// pass is the compact ledger row; every other row is a full row; a row
// is expandable only when the expanded block would carry a payload
// (detail, query lines or page references — the timing line alone is
// not a payload). The defaults are today's look, so
// `VerificationProgressView` passes nothing new.

@Suite("LayerResultRow style and payload", .tags(.display))
@MainActor
struct LayerResultRowStyleTests {

    private func layer(
        status: VerificationStatus, detail: String = "",
        queryLines: [SearchRecheckQueryLine]? = nil, pages: [Int]? = nil
    ) -> LayerResult {
        LayerResult(name: "L", symbolName: "shield", status: status,
                    shortDescription: "", detailDescription: detail,
                    pageReferences: pages, durationSeconds: 0,
                    queryLines: queryLines)
    }

    /// One applied-query line, the shape the Search Re-check row carries.
    private func oneLine() -> SearchRecheckQueryLine {
        SearchRecheckQueryLine(
            label: "\u{201C}Delia\u{201D}", foundCount: 2, foundHitCap: false,
            appliedCount: 2, remainingCount: 0, route: .textLayer)
    }

    @Test("rowStyle(for:) is compact only for a pass with nothing to expand",
          arguments: [
            (VerificationStatus.pass, "", false, false, LayerResultRow.Style.compact),
            (VerificationStatus.pass, "x", false, false, LayerResultRow.Style.full),
            (VerificationStatus.pass, "", true, false, LayerResultRow.Style.full),
            (VerificationStatus.pass, "", false, true, LayerResultRow.Style.full),
            (VerificationStatus.warn("w"), "", false, false, LayerResultRow.Style.full),
            (VerificationStatus.skipped, "Skipped detail", false, false, LayerResultRow.Style.full),
          ])
    func rowStyleIsCompactOnlyForACleanPass(
        status: VerificationStatus, detail: String,
        withQueryLines: Bool, withPages: Bool, expected: LayerResultRow.Style
    ) {
        let row = layer(status: status, detail: detail,
                        queryLines: withQueryLines ? [oneLine()] : nil,
                        pages: withPages ? [0] : nil)
        #expect(LayerResultRow.rowStyle(for: row) == expected)
    }

    @Test("hasExpandedPayload is detail, or query lines, or page references — never an empty array",
          arguments: [
            ("", nil as Int?, nil as Int?, false),
            ("x", nil as Int?, nil as Int?, true),
            ("", 0 as Int?, nil as Int?, false),
            ("", 1 as Int?, nil as Int?, true),
            ("", nil as Int?, 0 as Int?, false),
            ("", nil as Int?, 1 as Int?, true),
          ])
    func hasExpandedPayloadIsDetailOrQueryLinesOrPages(
        detail: String, queryLineCount: Int?, pageCount: Int?, expected: Bool
    ) {
        // nil → nil; 0 → an empty array; 1 → one element.
        let lines: [SearchRecheckQueryLine]? = queryLineCount.map { $0 == 0 ? [] : [oneLine()] }
        let pages: [Int]? = pageCount.map { $0 == 0 ? [] : [2] }
        let row = layer(status: .pass, detail: detail, queryLines: lines, pages: pages)
        #expect(LayerResultRow.hasExpandedPayload(layer: row) == expected)
    }

    @Test("The defaults are the full style and the card chrome (the progress view's look)")
    func defaultsAreFullStyleAndCardChrome() {
        let row = LayerResultRow(layer: layer(status: .pass), layerIndex: 1,
                                 isExpanded: false, onTap: {})
        #expect(row.style == .full)
        #expect(row.chrome == .card)
    }
}
