import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// `VerificationLayerPartition` — the one enumeration behind the details
// disclosure's grouping (FINDINGS → clean → NOTES) and the summary line's
// counts. Indices are engine positions, so the rows' `layerResult_N`
// identifiers and the spoken "Layer N" stay stable across grouping.

@Suite("Verification layer partition", .tags(.display))
@MainActor
struct VerificationLayerPartitionTests {

    private func layer(_ status: VerificationStatus) -> LayerResult {
        LayerResult(name: "L", symbolName: "shield", status: status,
                    shortDescription: "", detailDescription: "",
                    pageReferences: nil, durationSeconds: 0)
    }

    @Test("A wholly clean run has no findings and no notes")
    func whollyCleanPartitionHasNoFindingsOrNotes() {
        let p = VerificationLayerPartition(layers: [layer(.pass), layer(.pass)])
        #expect(p.findings == [])
        #expect(p.passed == [0, 1])
        #expect(p.notes == [])
        #expect(p.total == 2)
        #expect(p.passedCount == 2)
        #expect(p.infoCount == 0)
        #expect(p.skippedCount == 0)
        #expect(p.warnCount == 0)
        #expect(p.attentionCount == 0)
        #expect(p.failCount == 0)
        #expect(p.completedCount == 2)
        #expect(p.isWhollyClean == true)
    }

    @Test("Findings keep engine order across kinds; pass and info both count as passed")
    func mixedStatusPartitionOrdersByEngineIndexNotGroup() {
        // Engine indices 0–6: pass, warn, info, attention, fail, skipped, pass.
        let p = VerificationLayerPartition(layers: [
            layer(.pass), layer(.warn("w")), layer(.info("i")),
            layer(.attention("a")), layer(.fail("f")), layer(.skipped),
            layer(.pass),
        ])
        // warn, attention, fail, skipped — engine order, not grouped by kind.
        #expect(p.findings == [1, 3, 4, 5])
        #expect(p.passed == [0, 6])
        #expect(p.notes == [2])
        #expect(p.total == 7)
        // 2 pass + 1 info.
        #expect(p.passedCount == 3)
        #expect(p.infoCount == 1)
        #expect(p.skippedCount == 1)
        #expect(p.warnCount == 1)
        #expect(p.attentionCount == 1)
        #expect(p.failCount == 1)
        // total − skipped.
        #expect(p.completedCount == 6)
        #expect(p.isWhollyClean == false)
    }

    @Test("INFO-only rows ride notes, so a pass-with-notes run is never wholly clean")
    func isWhollyCleanIsFalseWhenOnlyNotesArePresent() {
        let p = VerificationLayerPartition(layers: [
            layer(.pass), layer(.pass), layer(.info("a")), layer(.info("b")),
        ])
        #expect(p.findings == [])
        #expect(p.notes == [2, 3])
        #expect(p.passedCount == 4)
        #expect(p.infoCount == 2)
        #expect(p.isWhollyClean == false)
    }

    @Test("The counts match the attention-shape fixture behind the summary pin")
    func countsMatchTheAttentionShapeFixture() {
        // The exact 10-layer shape `detailsSummaryAttentionShape` pins as
        // "7 of 10 checks passed · 2 need review · 1 note · 3 informational notes".
        let p = VerificationLayerPartition(layers: [
            layer(.pass), layer(.pass), layer(.pass), layer(.pass),
            layer(.info("a")), layer(.info("b")), layer(.info("c")),
            layer(.attention("r1")), layer(.attention("r2")),
            layer(.warn("n")),
        ])
        #expect(p.total == 10)
        #expect(p.passedCount == 7)
        #expect(p.infoCount == 3)
        #expect(p.attentionCount == 2)
        #expect(p.warnCount == 1)
        #expect(p.failCount == 0)
        #expect(p.skippedCount == 0)
        #expect(p.completedCount == 10)
    }
}
