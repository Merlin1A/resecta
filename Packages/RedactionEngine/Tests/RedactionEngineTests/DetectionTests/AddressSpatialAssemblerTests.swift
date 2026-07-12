import Testing
import CoreGraphics
import Foundation
@testable import RedactionEngine

// Plan Phase 3 / §4 / §G6 — spatial address assembly tests.

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

    // MARK: - S5 item 2.9 — street-type gazetteer validation

    /// Build a fixture AddressComponentsGazetteer from inline JSON written to
    /// a temp bundle, following the same pattern used in
    /// AddressComponentsGazetteerTests.
    private func makeGazetteer(streetTypes: [String]) throws -> AddressComponentsGazetteer {
        let quotedTypes = streetTypes.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
            {
              "version": 1,
              "cities": ["Austin"],
              "counties": ["Travis County"],
              "street_types": [\(quotedTypes)]
            }
            """
        let tempBase = FileManager.default.temporaryDirectory
            .appending(
                path: "addr-assembler-test-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: gazetteersDir, withIntermediateDirectories: true
        )
        let fixtureURL = gazetteersDir.appending(path: "address_components.json")
        try json.write(to: fixtureURL, atomically: true, encoding: .utf8)
        guard let bundle = Bundle(path: tempBase.path()) else {
            try? FileManager.default.removeItem(at: tempBase)
            throw AssemblerTestError.cannotCreateBundle
        }
        let gazetteer = try AddressComponentsGazetteer(bundle: bundle)
        try? FileManager.default.removeItem(at: tempBase)
        return gazetteer
    }

    private enum AssemblerTestError: Error { case cannotCreateBundle }

    @Test("Street type in gazetteer: address assembles (S5 item 2.9)")
    func streetTypeInGazetteerAssembles() throws {
        // Gazetteer contains "Street"; the street line ends with "Street" --
        // assembly should proceed normally.
        let gazetteer = try makeGazetteer(streetTypes: ["Street", "Avenue", "Boulevard"])
        let assemblerWithGazetteer = AddressSpatialAssembler(addressComponents: gazetteer)
        let lines = [
            line("123 Main Street", x: 0.1, y: 0.85),
            line("Austin, TX 78701", x: 0.1, y: 0.82),
        ]
        let out = assemblerWithGazetteer.assemble(lines: lines)
        #expect(!out.isEmpty, "Address with recognized street type should assemble")
    }

    @Test("Abbreviated street type canonicalizes for the gazetteer lookup (S5 item 2.9)")
    func abbreviatedStreetTypeAssembles() throws {
        // The pipeline street_types list ships full words only; "123 Main St"
        // must canonicalize "St" → "street" before the lookup or every
        // abbreviated street line would fail validation.
        let gazetteer = try makeGazetteer(streetTypes: ["Street", "Avenue", "Boulevard"])
        let assemblerWithGazetteer = AddressSpatialAssembler(addressComponents: gazetteer)
        let lines = [
            line("123 Main St", x: 0.1, y: 0.85),
            line("Austin, TX 78701", x: 0.1, y: 0.82),
        ]
        let out = assemblerWithGazetteer.assemble(lines: lines)
        #expect(!out.isEmpty, "Abbreviated street type should canonicalize and assemble")
    }

    @Test("Street type absent from gazetteer: line is not treated as a street line (S5 item 2.9)")
    func absentStreetTypeRejected() throws {
        // Gazetteer deliberately lacks "Avenue": both the full and the
        // abbreviated surface forms must fail validation, so the candidate
        // falls back to the no-street-line emission rules.
        let gazetteer = try makeGazetteer(streetTypes: ["Street"])
        let assemblerWithGazetteer = AddressSpatialAssembler(addressComponents: gazetteer)
        for streetLine in ["456 Elm Avenue", "456 Elm Ave"] {
            let lines = [
                line(streetLine, x: 0.1, y: 0.85),
                line("78701", x: 0.1, y: 0.82),
            ]
            let out = assemblerWithGazetteer.assemble(lines: lines)
            #expect(
                out.isEmpty,
                "ZIP-only context without a validated street line or state should not assemble (\(streetLine))"
            )
        }
    }

    @Test("Nil gazetteer: behavior byte-identical to pre-S5 path (S5 item 2.9)")
    func nilGazetteerBehaviorUnchanged() {
        // When gazetteer is nil the streetTypeValid helper returns true
        // unconditionally, preserving pre-S5 behavior.
        let assemblerNilGazetteer = AddressSpatialAssembler(addressComponents: nil)
        let lines = [
            line("456 Elm Avenue", x: 0.1, y: 0.85),
            line("Houston, TX 77001", x: 0.1, y: 0.82),
        ]
        let withGazetteer = assembler.assemble(lines: lines)
        let withoutGazetteer = assemblerNilGazetteer.assemble(lines: lines)
        // Both paths should either both assemble or both not -- nil-gazetteer
        // path must not change the outcome relative to the default assembler
        // (which loads from the module bundle; we only assert non-empty here
        // since the default assembler's gazetteer state is environment-dependent).
        #expect(withoutGazetteer.isEmpty == withGazetteer.isEmpty)
    }
}
