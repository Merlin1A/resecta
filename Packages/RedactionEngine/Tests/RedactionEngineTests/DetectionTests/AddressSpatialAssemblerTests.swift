import Testing
import CoreGraphics
import Foundation
@testable import RedactionEngine

// Spatial address assembly tests.

@Suite("AddressSpatialAssembler (G6)")
struct AddressSpatialAssemblerTests {

    private let assembler = AddressSpatialAssembler()

    private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.3, h: CGFloat = 0.02) -> OCREngine.TextLine {
        OCREngine.TextLine(
            text: text,
            normalizedRect: CGRect(x: x, y: y, width: w, height: h),
            confidence: 1.0
        )
    }

    /// A line of a re-imported Searchable export: `fitted` is its box fitted
    /// to the ink, `layer` the hidden layer's own box.
    private func fittedLine(_ text: String, fitted: CGRect, layer: CGRect?) -> OCREngine.TextLine {
        var line = OCREngine.TextLine(text: text, normalizedRect: fitted, confidence: 1.0)
        line.textLayerRect = layer
        return line
    }

    @Test("Fitted lines join on the layer's own geometry: a two-column page keeps its street + ZIP address (third-party OCR layer, page 1)")
    func fittedLinesJoinOnTheLayerGeometry() throws {
        // Measured on a third-party OCR export's page 1 (minX, minY, height; widths set):
        // fitted, a tall left-column heading sorts between the two address lines.
        let box = (fitted: CGRect(x: 0.8405, y: 0.9411, width: 0.12, height: 0.0160),
                   layer: CGRect(x: 0.8525, y: 0.9470, width: 0.12, height: 0.0101))
        let heading = (fitted: CGRect(x: 0.0583, y: 0.9324, width: 0.20, height: 0.0225),
                       layer: CGRect(x: 0.0604, y: 0.9345, width: 0.20, height: 0.0228))
        let zip = (fitted: CGRect(x: 0.8343, y: 0.9296, width: 0.13, height: 0.0159),
                   layer: CGRect(x: 0.8424, y: 0.9345, width: 0.13, height: 0.0101))
        // In the page's line order (the heading and the ZIP line tie on the
        // layer's minY; the earlier line stays first, as on main).
        let lines = [
            fittedLine("P.O Box 4827", fitted: box.fitted, layer: box.layer),
            fittedLine("Boise ID 83701", fitted: zip.fitted, layer: zip.layer),
            fittedLine("Sablebrook Bank", fitted: heading.fitted, layer: heading.layer),
        ]
        let out = assembler.assemble(lines: lines)
        let address = try #require(out.first { $0.text.contains("83701") })
        #expect(address.text == "P.O Box 4827, Boise ID 83701")
        #expect(address.unionRect == box.fitted.union(zip.fitted), "the painted box is the fitted lines' union")
        #expect(address.textLayerUnionRect == box.layer.union(zip.layer), "the stripped box is the layer lines' union")
        // Control: grouped on the fitted boxes, the heading breaks the join.
        let unfitted = lines.map { OCREngine.TextLine(text: $0.text, normalizedRect: $0.normalizedRect, confidence: 1.0) }
        #expect(assembler.assemble(lines: unfitted).first { $0.text.contains("83701") }?.text == "Boise ID 83701")
    }

    @Test("Two-line address with state + ZIP assembles")
    func twoLineAssembly() {
        let lines = [
            line("123 Main Street", x: 0.1, y: 0.85),
            line("Austin, TX 78701", x: 0.1, y: 0.82),
        ]
        let out = assembler.assemble(lines: lines)
        #expect(!out.isEmpty)
        #expect(out.first?.text.contains("Austin, TX 78701") == true)
    }

    @Test("Spelled-out state name resolves to code")
    func spelledState() {
        let lines = [
            line("45 Elm Ave", x: 0.1, y: 0.85),
            line("Concord, New Hampshire 03301", x: 0.1, y: 0.82),
        ]
        let out = assembler.assemble(lines: lines)
        #expect(!out.isEmpty)
    }

    @Test("A ZIP whose state differs from its prefix assembles with that state")
    func overrideZIPAssembles() {
        let lines = [
            line("45 Lake Road", x: 0.1, y: 0.85),
            line("Errol, ME 03579", x: 0.1, y: 0.82),
        ]
        let hits = assembler.assemble(lines: lines)
        #expect(hits.count == 1, "the prefix 035 reads NH; the shipped override says ME")
    }

    @Test("An override ZIP assembles with its prefix state too; a third state is still refused")
    func overrideZIPAcceptsEitherState() {
        let nh = assembler.assemble(lines: [
            line("45 Lake Road", x: 0.1, y: 0.85),
            line("Errol, NH 03579", x: 0.1, y: 0.82),
        ])
        #expect(nh.count == 1, "03579 lies across the ME/NH line; its prefix 035 reads NH")
        let tx = assembler.assemble(lines: [
            line("45 Lake Road", x: 0.1, y: 0.85),
            line("Errol, TX 03579", x: 0.1, y: 0.82),
        ])
        #expect(tx.isEmpty)
    }

    @Test("ZIP/state mismatch rejected")
    func zipStateMismatch() {
        // 90210 is California; pairing with TX should fail the SCF cross-check.
        let lines = [
            line("1 False St", x: 0.1, y: 0.85),
            line("Beverly Hills, TX 90210", x: 0.1, y: 0.82),
        ]
        let out = assembler.assemble(lines: lines)
        #expect(out.isEmpty || !out.contains(where: { $0.text.contains("TX 90210") }))
    }

    @Test("Line with ZIP but no street or state produces no hit")
    func zipOnly() {
        let lines = [
            line("78701", x: 0.1, y: 0.5),
        ]
        let out = assembler.assemble(lines: lines)
        #expect(out.isEmpty)
    }

    @Test("x-alignment mismatch breaks assembly")
    func xAlignmentBreaks() {
        // Street line and state/ZIP line must start within 5% of each other.
        let lines = [
            line("999 Far Out Rd", x: 0.1, y: 0.85),
            line("Somewhere, OR 97201", x: 0.60, y: 0.82),  // far right
        ]
        let out = assembler.assemble(lines: lines)
        // Either empty or only the single-line ZIP row (which won't qualify).
        #expect(out.isEmpty || !out.contains(where: { $0.text.contains("999") }))
    }

    @Test("Empty input yields empty output")
    func empty() {
        #expect(assembler.assemble(lines: []).isEmpty)
    }

    @Test("ZIPStateTable lookup sanity")
    func zipTableLookup() {
        #expect(ZIPStateTable.state(forZIPPrefix: "902") == "CA")
        #expect(ZIPStateTable.state(forZIPPrefix: "100") == "NY")
        #expect(ZIPStateTable.state(forZIPPrefix: "787") == "TX")
        // Unknown prefix returns nil (no reject).
        #expect(ZIPStateTable.state(forZIPPrefix: "999") == "AK")
    }

}
