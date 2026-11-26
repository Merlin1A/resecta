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

    @Test("Nothing-to-check rows are counted in the list row's title; the headers carry counts, spoken with a comma")
    func nothingToCheckGroupAndHeaders() {
        let idle = LayerResult(name: "Search Re-check", symbolName: "shield", status: .notApplicable("x"),
                               shortDescription: "", detailDescription: "", pageReferences: nil,
                               durationSeconds: 0, layer: .searchRecheck)
        let p = VerificationLayerPartition(layers: [layer(.pass), idle], perPageModes: [])
        #expect(p.nothingToCheck == [1])
        #expect(p.notes == [])
        #expect(p.isWhollyClean == false)
        #expect(p.summaryLine1 == "1 of 1 check passed")
        #expect(p.summaryLine2 == "1\u{00A0}had nothing to check")
        #expect(p.clusterTitle == "1 check passed · 1\u{00A0}had nothing to check")
        #expect(p.clusterSpokenLabel == "1 check passed, 1\u{00A0}had nothing to check")
        #expect(p.clusterTitleBase == "1 check passed")
        #expect(p.clusterTitleClauses == ["1\u{00A0}had nothing to check"])
        // Passes, a riding note and an idle check: both clauses, notes first.
        let both = VerificationLayerPartition(layers: [layer(.pass), layer(.info("i")), idle, layer(.pass)],
                                              perPageModes: [])
        #expect(both.clusterTitle == "2 checks passed · 1\u{00A0}note · 1\u{00A0}had nothing to check")
        #expect(both.clusterSpokenLabel == "2 checks passed, 1\u{00A0}note, 1\u{00A0}had nothing to check")
        #expect(VerificationLayerPartition.sectionHeader("Notes", count: 3) == "Notes · 3")
        #expect(VerificationLayerPartition.sectionHeaderSpoken("Findings", count: 3) == "Findings, 3.")
        let one = VerificationLayerPartition(layers: [layer(.fail("f"))], perPageModes: [])
        #expect(one.summaryLine1 == "0 of 1 check passed")
        let riding = VerificationLayerPartition(layers: [layer(.pass), layer(.info("i"))], perPageModes: [])
        #expect(riding.clusterSpokenLabel == "1 check passed, 1\u{00A0}note")
    }

    // MARK: - The list row's members

    private func idle(_ identity: VerificationLayer) -> LayerResult {
        LayerResult(name: identity.name, symbolName: "shield", status: .notApplicable("x"),
                    shortDescription: "", detailDescription: "", pageReferences: nil,
                    durationSeconds: 0, layer: identity)
    }

    @Test("Checks that had nothing to check join the list row, in the checks' own order, on every run")
    func idleChecksJoinTheList() {
        typealias Section = VerificationDetailsSection
        // (layers, expected members, "Nothing to check" drawn as a group)
        let rows: [([LayerResult], [Int], Bool)] = [
            // 10 passed, 3 idle, the idle ones last.
            (Array(repeating: layer(.pass), count: 10) + [idle(.searchRecheck), idle(.binaryStringSearch),
                                                           idle(.characterCount)],
             Array(0..<13), false),
            // Passes, a riding note and an idle check.
            ([layer(.pass), layer(.info("i")), idle(.searchRecheck)], [0, 1, 2], false),
            // No pass and no riding note: the row still holds every check.
            ([layer(.fail("f")), idle(.searchRecheck)], [0, 1], false),
            // No idle check.
            ([layer(.pass), layer(.pass)], [0, 1], false),
            // An idle check between two passed ones sits between them.
            ([layer(.pass), idle(.searchRecheck), layer(.pass)], [0, 1, 2], false),
        ]
        var ran = 0
        for (layers, members, group) in rows {
            let p = VerificationLayerPartition(layers: layers, perPageModes: [])
            #expect(Section.listRowMembers(p) == members, "row \(ran)")
            #expect(Section.groups(p).contains { $0.header == "Nothing to check" } == group, "row \(ran)")
            ran += 1
        }
        print("[idle-checks] built reports \(ran)")
        #expect(ran == 5)
        // Over the seeded reports: every check is in exactly one drawn group
        // or in the list row, never two and never none.
        var seeded = 0
        for (name, report) in VerificationDebugFixtures.all {
            let p = VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
            let placed = Section.groups(p).flatMap(\.indices) + Section.listRowMembers(p)
            #expect(placed.sorted() == Array(report.layers.indices), "\(name)")
            seeded += 1
        }
        print("[idle-checks] seeded reports \(seeded)")
        #expect(seeded == 18)
    }

    @Test("A run with idle checks and a riding note arrives with the list closed")
    func aRunWithIdleChecksArrivesClosed() {
        let p = VerificationLayerPartition(layers: [layer(.pass), layer(.info("i")), idle(.searchRecheck)],
                                           perPageModes: [])
        #expect(!VerificationDetailsSection.clusterOpensByDefault(p))
        #expect(VerificationResultsView.visibleNoteCount(p) == 0)
        #expect(p.isWhollyClean == false)
    }

    @Test("Closing the list closes its open member, of any kind; other open items stay")
    func closingTheListClosesItsOpenMember() {
        typealias Open = VerificationDetailsSection.OpenItem
        // A passed check, a riding note, an idle check and a failed check in
        // the row; a plain warning in its card above; the failed check also
        // behind a Findings row.
        let p = VerificationLayerPartition(layers: [layer(.pass), layer(.info("i")), idle(.searchRecheck),
                                                    layer(.fail("f")), layer(.warn("w"))], perPageModes: [])
        #expect(VerificationDetailsSection.listRowMembers(p) == [0, 1, 2, 3])
        // (open before, expected after closing)
        let rows: [(Open?, Open?)] = [
            (.layer(2), nil),          // an open idle member closes
            (.layer(0), nil),          // an open passed member closes
            (.layer(3), nil),          // an open failed member closes
            (.layer(4), .layer(4)),    // the warning's row above stays open
            (.problem("failedCheck-3"), .problem("failedCheck-3")),  // a Findings row stays open
            (.pageModes, .pageModes),  // Page Modes stays open
            (nil, nil),                // nothing open
        ]
        for (before, after) in rows {
            #expect(VerificationDetailsSection.openItemAfterTogglingList(isOpen: true, openItem: before,
                                                                         partition: p) == after)
        }
        #expect(rows.count == 7)
        // Opening the list closes nothing.
        #expect(VerificationDetailsSection.openItemAfterTogglingList(isOpen: false, openItem: .layer(2),
                                                                     partition: p) == .layer(2))
    }

    @Test("Members keep their rows: a passed check no mark; a note and an idle check their mark and reason")
    func memberRowsKeepTheirReasons() {
        #expect(VerificationDetailsSection.memberLayout(.passed) == .member)
        #expect(VerificationDetailsSection.memberLayout(.note) == .lead)
        #expect(VerificationDetailsSection.memberLayout(.nothingToCheck) == .lead)
        let identities: [VerificationLayer] = [.searchRecheck, .detectionSweep, .binaryStringSearch,
                                               .characterCount, .hiddenWordInk]
        for identity in identities {
            let reason = VerificationRowModel.nothingToCheckReason(for: identity)
            #expect(reason != nil, "\(identity)")
            #expect(VerificationRowModel.caption(for: idle(identity), outcome: .nothingToCheck) == reason,
                    "\(identity)")
        }
        #expect(identities.count == 5)
    }
}
