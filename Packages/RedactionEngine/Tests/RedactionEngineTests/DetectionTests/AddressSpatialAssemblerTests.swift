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
