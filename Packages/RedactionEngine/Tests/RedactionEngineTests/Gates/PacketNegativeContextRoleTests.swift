import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// S06 -- INV-2 retirement checklist, ROLE 3 of 3.
//
// The packet successor to the full-document SWEEP half of
// `NegativeContextBeforeAfterGateTests`. That suite sweeps a document twice --
// nil negative-context gazetteer (BEFORE / current production) vs the wired
// gazetteer (AFTER / suppression active) -- and emits per-category surfaced /
// suppressed / dropped counts, asserting non-trivial output. This suite proves
// the SAME role on the synthetic Hartwell packet so the retired fixture can be
// dropped at F28 with no negative-context coverage gap.
//
// Scope (what transfers vs what stays): the predecessor test has TWO parts -- Part A
// (the full-document sweep) and Part B (the G8 corpus TP/FP/FN scoring). Only Part A
// is fixture-specific; the G8 corpus part is fixture-INDEPENDENT and survives
// F28 untouched. This suite is the packet analog of Part A.
//
// The negative program this exercises: the packet carries 31 must_not_fire
// occurrences (post-S05 reconciliation) across categories ssn/routingNumber/
// ein/itin/creditCard/account/phone/dob/driversLicense/licensePlate/passport --
// the precision program. The LIVE per-occurrence freeze (no must_not_fire fires
// as its own category) is `PacketRegressionTests.mustNotFirePrecisionFreeze`;
// this suite adds the BEFORE/AFTER gazetteer dimension that the freeze does not
// cover, asserting the negative-context mechanism is suppress-only (monotonic).
//
// Deterministic TEXT leg (no Vision) -- `page.string` + `PIIDetector.detect`.
// MATCHED-TEXT LOGGING (D31): synthetic fixture; this suite logs counts only.

@Suite("Packet negative-context before/after role (S06 retirement checklist)", .serialized)
struct PacketNegativeContextRoleTests {

    /// Per-category surfaced/suppressed/dropped accumulators for one config.
    struct Sweep {
        var surfaced: [String: Int] = [:]
        var suppressed: [String: Int] = [:]
        var dropped: [String: Int] = [:]
        var totalSurfaced = 0
    }

    /// Sweep the whole packet at `.financial` (the financial-doc scenario) under one
    /// gazetteer configuration -- mirrors `NegativeContextBeforeAfterGateTests`'
    /// full-document surfaced/suppressed/dropped bookkeeping exactly.
    private func sweepPacket(gazetteer: NegativeContextGazetteer?) async throws -> (Sweep, Int) {
        let data = try TestFixtures.loanPacketPDF()
        let document = try #require(PDFDocument(data: data))
        let detector = PIIDetector(negativeContextGazetteer: gazetteer)
        var s = Sweep()
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let text = page.string, !text.isEmpty else { continue }
            let matches = await detector.detect(in: text, doctype: .financial)
            for match in matches {
                guard let cat = match.category else { continue }
                let key = cat.rawValue
                let suppressed = isNegativeContextSuppressed(match)
                let cutoff = balancedCutoff(for: match.kind)
                let surfaced = cutoff.map { match.confidence >= $0 } ?? true
                let dropped = !surfaced && !suppressed
                if surfaced { s.surfaced[key, default: 0] += 1; s.totalSurfaced += 1 }
                if suppressed { s.suppressed[key, default: 0] += 1 }
                if dropped { s.dropped[key, default: 0] += 1 }
            }
        }
        return (s, document.pageCount)
    }

    @Test("Packet before/after gazetteer sweep is suppress-only (realdoc ROLE 3 successor)")
    func packetNegativeContextSweep() async throws {
        // BEFORE: nil gazetteer (current production baseline).
        let (before, pageCount) = try await sweepPacket(gazetteer: nil)
        // AFTER: the bundled negative-context gazetteer (suppression active).
        let gazetteer = try? NegativeContextGazetteer()
        let (after, _) = try await sweepPacket(gazetteer: gazetteer)

        #expect(pageCount == TestFixtures.loanPacketPageCount,
                "the packet sweep must cover all 12 pages")
        #expect(before.totalSurfaced > 0,
                "the before-sweep must produce non-trivial surfaced output (mirrors realdoc page_count>0)")

        print("[PKT-NEGCTX] gazetteer wired=\(gazetteer != nil)")
        let cats = Set(before.surfaced.keys).union(after.surfaced.keys).sorted()
        for key in cats {
            let bS = before.surfaced[key] ?? 0, aS = after.surfaced[key] ?? 0
            let aSup = after.suppressed[key] ?? 0, aDr = after.dropped[key] ?? 0
            print("[PKT-NEGCTX]   \(key): surfaced before=\(bS) after=\(aS) "
                + "suppressed=\(aSup) dropped=\(aDr)")
            // The negative-context mechanism is SUPPRESS-ONLY: wiring the
            // gazetteer can only remove surfaced detections, never add them.
            #expect(aS <= bS,
                    "\(key): wiring the gazetteer raised surfaced \(bS)->\(aS) (must be suppress-only)")
        }
        let totalSuppressed = after.suppressed.values.reduce(0, +)
        print("[PKT-NEGCTX] before.totalSurfaced=\(before.totalSurfaced) "
            + "after.totalSurfaced=\(after.totalSurfaced) "
            + "after.totalSuppressed=\(totalSuppressed)")
    }
}
