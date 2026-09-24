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

    // MARK: - Custom glyph predicate

    // The icon column sets a custom asset at its optical size (23 pt, the
    // stopgap until the sources are retuned) and an SF fallback at
    // `.title3`; the predicate is the router's own lookup.
    @Test("isCustom is true exactly for a layer with a custom asset (identity first, then the stored name)")
    func isCustomIsTrueExactlyForTheAssetLayers() {
        let ocr = LayerResult(
            name: "OCR Check", symbolName: "x", status: .pass, shortDescription: "",
            detailDescription: "", pageReferences: nil, durationSeconds: 0)
        #expect(VerificationSymbol.isCustom(ocr))
        let stamped = LayerResult(
            name: "Legacy Name", symbolName: "x", status: .pass, shortDescription: "",
            detailDescription: "", pageReferences: nil, durationSeconds: 0, layer: .ocrCheck)
        #expect(VerificationSymbol.isCustom(stamped))
        let recheck = LayerResult(
            name: VerificationLayer.searchRecheck.name,
            symbolName: VerificationLayer.searchRecheck.symbolName,
            status: .pass, shortDescription: "", detailDescription: "",
            pageReferences: nil, durationSeconds: 0, layer: .searchRecheck)
        #expect(!VerificationSymbol.isCustom(recheck))
        #expect(!VerificationSymbol.isCustom(layer(status: .pass)))
    }

    // MARK: - Source pin: the section picks the row style

    // The compact ledger row exists only if the section computes the style
    // per row and passes it; the row's default stays `.full` for the
    // progress view.
    @Test("Source pin: VerificationDetailsSection passes rowStyle(for:) to every layer row")
    func detailsSectionPassesTheRowStylePerRow() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/VerificationDetailsSection.swift")
        #expect(source.contains("style: LayerResultRow.rowStyle(for: layer)"),
                "the section must compute the row style per row and pass it")
    }

    private func loadRepoFile(
        _ relativePath: String, from file: StaticString = #filePath
    ) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()  // ResectaAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
