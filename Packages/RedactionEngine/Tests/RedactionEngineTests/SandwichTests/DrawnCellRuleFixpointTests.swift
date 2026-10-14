import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// The drawn-cell rule re-flows the surviving set until no drawn cell is
// centred inside a region, up to a pass limit. A set the limit leaves
// unsettled must not reach the writer as it stands: the rule reports it and
// the page is written without a text layer.

@Suite("Drawn-cell rule: the re-flow limit")
struct DrawnCellRuleFixpointTests {

    /// A narrow-font label beside a redacted value box and a wide-font group
    /// further along the band: the band's sum-matched pitch is wider than
    /// the label's glyphs, so the label's trailing colon is drawn inside the
    /// box although its source box clears the filter's halo. One pass of the
    /// rule settles it.
    private static func narrowLabelBand() -> (entries: [CharacterInfo], shapes: [RegionShape]) {
        var entries: [CharacterInfo] = []
        for (i, ch) in "Name:".enumerated() {
            entries.append(CharacterInfo(
                character: String(ch),
                bounds: CGRect(x: 100 + Double(i) * 2.2, y: 500, width: 2.2, height: 10),
                stringIndex: i))
        }
        for (i, ch) in "WIDE".enumerated() {
            entries.append(CharacterInfo(
                character: String(ch),
                bounds: CGRect(x: 300 + Double(i) * 6, y: 500, width: 6, height: 10),
                stringIndex: 10 + i))
        }
        let region = CGRect(x: 115, y: 500, width: 45, height: 10)
        let shapes = [RegionShape(
            expandedBounds: region.insetBy(dx: -safetyMarginPoints, dy: -safetyMarginPoints),
            polygonVertices: nil, bounds: region)]
        return (entries, shapes)
    }

    @Test("A set the pass limit leaves unsettled carries no survivor drawn inside a region")
    func unsettledSetCarriesNoInRegionSurvivor() {
        let (entries, shapes) = Self.narrowLabelBand()
        #expect(TextLayerReconstructor.inRegionDrawnGlyphIndices(
            entries: entries, pageWidth: 612, regionShapes: shapes) == IndexSet(integer: 4),
            "the fixture's colon is drawn inside the box before any pass")
        let filtered = FilterResult(surviving: entries, totalCharacters: 20, excludedCount: 11)
        // No pass may run: the colon stays where the limit left it.
        let v = TextLayerReconstructor.validateSurvivors(
            filtered, regionShapes: shapes, frame: .unrotated(width: 612), passLimit: 0)
        #expect(TextLayerReconstructor.inRegionDrawnGlyphIndices(
            entries: v.result.surviving, pageWidth: 612, regionShapes: shapes).isEmpty,
            "no survivor is drawn inside a region, whatever the pass limit; got \(v.result.surviving.map(\.character))")
        #expect(!v.settled, "the limit left the colon inside the box: the set is reported unsettled")
        #expect(v.dropped == 1 && v.result.excludedCount == 12 && v.result.surviving.count == 8,
                "the colon is dropped and counted even so")
    }

    @Test("A set one pass settles is reported settled, with the pass's drop counted")
    func settledSetIsReportedSettled() {
        let (entries, shapes) = Self.narrowLabelBand()
        let filtered = FilterResult(surviving: entries, totalCharacters: 20, excludedCount: 11)
        let v = TextLayerReconstructor.validateSurvivors(
            filtered, regionShapes: shapes, frame: .unrotated(width: 612))
        #expect(v.settled)
        #expect(v.dropped == 1 && v.result.surviving.count == 8)
        // A set with nothing to drop is settled at once, nothing counted.
        let clean = TextLayerReconstructor.validateSurvivors(
            FilterResult(surviving: Array(entries[5...]), totalCharacters: 20, excludedCount: 16),
            regionShapes: shapes, frame: .unrotated(width: 612), passLimit: 0)
        #expect(clean.settled && clean.dropped == 0 && clean.result.surviving.count == 4)
    }
}
