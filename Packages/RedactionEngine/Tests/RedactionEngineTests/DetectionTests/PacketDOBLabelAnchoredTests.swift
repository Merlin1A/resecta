import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// S06 -- INV-2 retirement checklist, ROLE 2 of 3.
//
// The packet successor to `RealDocDOBLabelAnchoredTests`. That suite proved the
// label-anchored DOB path (design 01 §1, D4) fires on the retired fixture's
// labeled dates at the fixed 0.85 label-path confidence and clears the balanced
// preset. This suite proves the SAME role on the synthetic Hartwell packet, so
// the retired fixture can be dropped at F28 with no DOB-label coverage gap.
//
// Cross-walk (the role transfers): the predecessor test scans every page at
// `.financial` and asserts (a) totalDOB > 0, (b) every DOB match confidence
// == 0.85 (only the label-anchored path runs at `.financial`), (c) 0.85 clears
// the balanced dob cutoff. This suite asserts the identical three properties on
// the packet. The packet's must-fire textual DOB anchor is `occ_urlab_05`
// ("Born March 14, 1985", URLA-B / page index 1, S05-confirmed must_fire); the
// numeric URLA DOBs reconciled to should_fire at S05 (they miss the text leg on
// `.financial`) and the future-date / tax-year-range negatives are must_not_fire
// (the DOB detector rejects them) -- so every DOB that DOES fire here is a real
// labeled past DOB at 0.85, exactly the predecessor property.
//
// MATCHED-TEXT LOGGING (D31): synthetic, publicly-manifested fixture -- a single
// matched-text diagnostic is permitted; assertions stay counts-only (the retired
// fixture's glyph-only rule is unchanged on its own fixture).

@Suite("Packet DOB label-anchored role (S06 retirement checklist, counts)", .serialized)
struct PacketDOBLabelAnchoredTests {

    @Test("Label-anchored DOB count > 0 on the packet at balanced (realdoc ROLE 2 successor)")
    func labelAnchoredDOBFiresOnPacket() async throws {
        let data = try TestFixtures.loanPacketPDF()
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == TestFixtures.loanPacketPageCount)

        let detector = PIIDetector()
        var totalDOB = 0
        var perPageCounts: [Int: Int] = [:]
        var matchedTexts: [String] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let text = page.string, !text.isEmpty else { continue }
            // Force `.financial` on every page (the financial-doc scenario): the
            // label-anchored path is the only DOB detector that runs there.
            let matches = await detector.detect(in: text, doctype: .financial)
            let dobMatches = matches.filter { $0.kind == .dateOfBirth }
            for match in dobMatches {
                // Label path emits the fixed 0.85 (design 01 §1).
                #expect(match.confidence == 0.85)
                matchedTexts.append(match.text)
            }
            if !dobMatches.isEmpty {
                perPageCounts[pageIndex] = dobMatches.count
                totalDOB += dobMatches.count
            }
        }

        // Counts + page attribution (D31 permits the matched-text line here).
        print("PacketDOBLabelAnchored: per-page label-anchored DOB counts: \(perPageCounts.sorted(by: { $0.key < $1.key }))")
        print("PacketDOBLabelAnchored: total = \(totalDOB) matched=\(matchedTexts)")

        #expect(totalDOB > 0,
                "the label-anchored DOB path found no labeled dates on the packet")

        // The must-fire TEXTUAL anchor occ_urlab_05 ("Born March 14, 1985") sits
        // on URLA-B (page index 1): that page must contribute at least one DOB,
        // pinning the role to the same must-fire occurrence PacketRegressionTests
        // freezes (so retiring the old fixture does not drop the textual-DOB demonstrator).
        #expect((perPageCounts[1] ?? 0) >= 1,
                "the URLA-B page (idx 1, bearing the must-fire textual DOB) must fire a label-anchored DOB")

        // W4 relationship (identical to the predecessor sibling): the fixed 0.85
        // label-path confidence clears the shipped balanced dob cutoff.
        let bundle = PresetThresholdBundle.loadFromEngineBundle()
        let balancedCutoff = try #require(bundle.presets[.balanced]?.threshold(forWireName: "dob"))
        #expect(0.85 > balancedCutoff,
                "balanced dob cutoff \(balancedCutoff) gates the 0.85 label path")
    }
}
