import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// `LayerResultRow`'s chrome default and its custom-glyph predicate. The
// default is the progress view's look, so `VerificationProgressView`
// passes nothing new.

@Suite("LayerResultRow chrome and glyph", .tags(.display))
@MainActor
struct LayerResultRowStyleTests {

    private func layer(status: VerificationStatus) -> LayerResult {
        LayerResult(name: "L", symbolName: "shield", status: status,
                    shortDescription: "", detailDescription: "",
                    pageReferences: nil, durationSeconds: 0)
    }

    @Test("The default is the card chrome (the progress view's look)")
    func defaultIsCardChrome() {
        let row = LayerResultRow(layer: layer(status: .pass), layerIndex: 1,
                                 isExpanded: false, onTap: {})
        #expect(row.chrome == .card)
    }

    // MARK: - Custom glyph predicate

    // The glyph column draws a custom asset or the stored SF fallback; the
    // predicate is the router's own lookup.
    @Test("isCustom is true exactly for an identity with a custom asset — never for a name alone")
    func isCustomIsTrueExactlyForTheAssetLayers() {
        // No identity (the Page Count gate row's shape): the stored SF
        // symbol, whatever the name says.
        let ocr = LayerResult(
            name: "OCR Check", symbolName: "x", status: .pass, shortDescription: "",
            detailDescription: "", pageReferences: nil, durationSeconds: 0)
        #expect(!VerificationSymbol.isCustom(ocr))
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
}
