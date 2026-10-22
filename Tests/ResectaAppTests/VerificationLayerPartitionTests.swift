import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// `VerificationLayerPartition` — the one enumeration behind the details
// disclosure's grouping (Findings → Could not verify → Notes → Nothing to
// check → the pass cluster) and the summary line's counts. Indices are engine positions, so
// the rows' `layerResult_N` identifiers stay stable across grouping.

@Suite("Verification layer partition", .tags(.display))
@MainActor
struct VerificationLayerPartitionTests {

    private func layer(_ status: VerificationStatus) -> LayerResult {
        LayerResult(name: "L", symbolName: "shield", status: status,
                    shortDescription: "", detailDescription: "",
                    pageReferences: nil, durationSeconds: 0)
    }

    @Test("A wholly clean run is one open cluster")
    func whollyCleanPartitionIsTheCluster() {
        let p = VerificationLayerPartition(layers: [layer(.pass), layer(.pass)], perPageModes: [])
        #expect(p.findings == [])
        #expect(p.couldNotVerify == [])
        #expect(p.notes == [])
        #expect(p.cluster == [0, 1])
        #expect(p.total == 2)
        #expect(p.passedCount == 2)
        #expect(p.clusterNoteCount == 0)
        #expect(p.isWhollyClean == true)
        #expect(p.clusterTitle == "2 checks passed")
    }

    @Test("Groups keep engine order; a skipped check could not verify; only a pass counts as passed")
    func mixedStatusPartitionOrdersByEngineIndexInEachGroup() {
        // Engine indices 0–6: pass, warn, info, attention, fail, skipped, pass.
        let p = VerificationLayerPartition(layers: [
            layer(.pass), layer(.warn("w")), layer(.info("i")),
            layer(.attention("a")), layer(.fail("f")), layer(.skipped),
            layer(.pass),
        ], perPageModes: [])
        // warn (no could-not-verify flag), attention, fail — engine order.
        #expect(p.findings == [1, 3, 4])
        #expect(p.couldNotVerify == [5])
        #expect(p.notes == [])
        // An info without identity is a note with nothing remaining.
        #expect(p.cluster == [0, 2, 6])
        #expect(p.total == 7)
        #expect(p.passedCount == 2)
        let counts: [Int] = [p.count(.note), p.count(.warning), p.count(.needsReview), p.count(.failed),
                             p.count(.couldNotVerify), p.count(.nothingToCheck)]
        #expect(counts == [1, 1, 1, 1, 1, 0])
        #expect(p.isWhollyClean == false)
    }

    @Test("Notes with nothing remaining ride the cluster, which then opens by default")
    func notesWithNothingRemainingRideTheCluster() {
        let p = VerificationLayerPartition(layers: [
            layer(.pass), layer(.pass), layer(.info("a")), layer(.info("b")),
        ], perPageModes: [])
        #expect(p.findings == [])
        #expect(p.notes == [])
        #expect(p.cluster == [0, 1, 2, 3])
        #expect(p.passedCount == 2)
        #expect(p.clusterNoteCount == 2)
        #expect(p.isWhollyClean == true)
        #expect(p.clusterTitle == "2 checks passed · 2\u{00A0}notes")
    }

    @Test("The counts match the attention-shape fixture behind the summary pin")
    func countsMatchTheAttentionShapeFixture() {
        // The exact 10-layer shape `detailsSummaryAttentionShape` pins as
        // "4 of 10 checks passed · 2 need review · 1 warning · 3 notes".
        let p = VerificationLayerPartition(layers: [
            layer(.pass), layer(.pass), layer(.pass), layer(.pass),
            layer(.info("a")), layer(.info("b")), layer(.info("c")),
            layer(.attention("r1")), layer(.attention("r2")),
            layer(.warn("n")),
        ], perPageModes: [])
        #expect(p.findings == [7, 8, 9])
        #expect(p.cluster == [0, 1, 2, 3, 4, 5, 6])
        #expect(p.total == 10)
        #expect(p.passedCount == 4)
        #expect(p.count(.note) == 3)
        #expect(p.count(.needsReview) == 2)
        #expect(p.count(.warning) == 1)
        #expect(p.clusterTitle == "4 checks passed · 3\u{00A0}notes")
    }

    @Test("A sweep note with items sits in Notes; the cluster title counts one passing check alone")
    func sweepNoteWithItemsSitsAboveTheCluster() {
        let line = SearchRecheckQueryLine(label: "Scan (17 detectors)", foundCount: 0, foundHitCap: false,
                                          appliedCount: 0, remainingCount: 3, route: .ocr)
        let sweep = LayerResult(name: "Detection Sweep", symbolName: "shield", status: .info("x"),
                                shortDescription: "", detailDescription: "", pageReferences: [0],
                                durationSeconds: 0, layer: .detectionSweep, queryLines: [line])
        let p = VerificationLayerPartition(layers: [layer(.pass), sweep], perPageModes: [])
        #expect(p.notes == [1])
        #expect(p.cluster == [0])
        #expect(p.isWhollyClean == false)
        #expect(p.clusterTitle == "1 check passed")
    }

    @Test("Nothing-to-check rows have their own group; the headers carry counts, spoken with a comma")
    func nothingToCheckGroupAndHeaders() {
        let idle = LayerResult(name: "Search Re-check", symbolName: "shield", status: .notApplicable("x"),
                               shortDescription: "", detailDescription: "", pageReferences: nil,
                               durationSeconds: 0, layer: .searchRecheck)
        let p = VerificationLayerPartition(layers: [layer(.pass), idle], perPageModes: [])
        #expect(p.nothingToCheck == [1])
        #expect(p.notes == [])
        #expect(p.isWhollyClean == false)
        #expect(p.summaryLine1 == "1 of 2 checks passed")
        #expect(p.summaryLine2 == "1\u{00A0}had nothing to check")
        #expect(VerificationLayerPartition.sectionHeader("Nothing to check", count: 3) == "Nothing to check · 3")
        #expect(VerificationLayerPartition.sectionHeaderSpoken("Findings", count: 3) == "Findings, 3.")
        let one = VerificationLayerPartition(layers: [layer(.fail("f"))], perPageModes: [])
        #expect(one.summaryLine1 == "0 of 1 check passed")
        let riding = VerificationLayerPartition(layers: [layer(.pass), layer(.info("i"))], perPageModes: [])
        #expect(riding.clusterSpokenLabel == "1 check passed, 1\u{00A0}note")
    }
}
