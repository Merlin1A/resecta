import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// A re-check from the Run Verification card is handed the regions of the run
// that made the export, as that run burned them: clamped to the page, with
// the size floor applied and with the run's ink strips. It does not read the
// editor's live regions. The run itself already does this
// (`BurnedRegionsVerificationTests`); the re-check reads the regions the run
// inputs keep beside the output. A re-check runs only on an output that is
// not stale, so the live regions differ from the burned ones only in form:
// before the clamp, before the size floor, and without the ink strips.
// `verificationRegionsSeam` observes what the checks receive.

@Suite("A re-check reads the regions the run burned", .serialized, .tags(.coordination))
@MainActor
struct RecheckBurnedRegionsTests {

    enum Case: String, CaseIterable, CustomTestStringConvertible {
        case sameRegionsOnRunAndRecheck
        case sameRowStatusesOnRunAndRecheck
        case clearedOutputKeepsNoRegions
        case noKeptInputsReadsLiveRegions
        var testDescription: String { rawValue }
    }

    @Test("The table holds exactly four cases")
    func tableLength() {
        #expect(Case.allCases.count == 4)
    }

    @Test("Each case", .timeLimit(.minutes(3)), arguments: Case.allCases)
    func each(_ c: Case) async throws {
        switch c {
        case .sameRegionsOnRunAndRecheck: try await sameRegionsOnRunAndRecheck()
        case .sameRowStatusesOnRunAndRecheck: try await sameRowStatusesOnRunAndRecheck()
        case .clearedOutputKeepsNoRegions: try await clearedOutputKeepsNoRegions()
        case .noKeptInputsReadsLiveRegions: try await noKeptInputsReadsLiveRegions()
        }
    }

    // MARK: - The run and its re-check

    struct Observed {
        let regionIDs: (inked: UUID, pastTheEdge: UUID, underTheFloor: UUID)
        let onRun: [Int: [RedactionRegion]]
        let onRecheck: [Int: [RedactionRegion]]
        let runReport: VerificationReport
        let recheckReport: VerificationReport
        let coordinator: PipelineCoordinator
    }

    /// The app's run (Secure Rasterization, the only mode) of the hidden-layer
    /// page of `InkStripRunEntryTests` with three regions: a hand box over a
    /// name; a box that reaches past the page's
    /// right edge, below the text; and a box under the size floor inside a
    /// line of text. Then the Run Verification card's re-check.
    static func runThenRecheck() async throws -> Observed {
        let coord = try InkStripRunEntryTests.coordinator()
        let inked = InkStripRunEntryTests.hand(
            InkStripRunEntryTests.inkRect(line: 5, phrase: "Marisol", through: "Vance-Oduya"))
        let pastTheEdge = InkStripRunEntryTests.hand(CGRect(x: 0.9, y: 0.08, width: 0.2, height: 0.04))
        let line0 = InkStripRunEntryTests.inkRect(line: 0, phrase: "review")
        let underTheFloor = InkStripRunEntryTests.hand(
            CGRect(x: line0.midX, y: line0.midY, width: 0.0005, height: 0.0005))
        for region in [inked, pastTheEdge, underTheFloor] {
            coord.redactionState.addRegion(region, page: 0, undoManager: nil)
        }

        var received: [[Int: [RedactionRegion]]] = []
        coord.verificationRegionsSeam = { received.append($0) }

        coord.runFullPipeline(documentOverride: nil)
        let run = try #require(coord.documentState.activePipelineTask, "the run started")
        await run.value
        guard case .verified(let runReport) = coord.documentState.phase else {
            throw Failure("the run did not end verified: \(coord.documentState.phaseKind)")
        }

        coord.runVerifyOnly()
        let recheck = try #require(coord.documentState.activePipelineTask, "the re-check started")
        await recheck.value
        guard case .verified(let recheckReport) = coord.documentState.phase else {
            throw Failure("the re-check did not end verified: \(coord.documentState.phaseKind)")
        }

        try #require(received.count == 2, "the checks ran on the run and on the re-check: \(received.count)")
        return Observed(
            regionIDs: (inked.id, pastTheEdge.id, underTheFloor.id),
            onRun: received[0], onRecheck: received[1],
            runReport: runReport, recheckReport: recheckReport, coordinator: coord)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func describe(_ regions: [Int: [RedactionRegion]]) -> String {
        regions.keys.sorted().map { page in
            "page \(page): " + (regions[page] ?? []).map {
                "\($0.id.uuidString.prefix(8)) \($0.normalizedRect) strips \($0.inkStripRects.count)"
            }.joined(separator: "; ")
        }.joined(separator: " | ")
    }

    static func statuses(_ report: VerificationReport) -> String {
        report.layers.map { "\($0.name): \($0.status)" }.joined(separator: "; ")
    }

    /// The reproduction. The run hands the checks the clamped box, the
    /// name's box (whole: a Secure run makes no ink plan, so no strips) and
    /// nothing for the box under the floor; the re-check is handed the same.
    func sameRegionsOnRunAndRecheck() async throws {
        let o = try await Self.runThenRecheck()
        let context = ("run: \(Self.describe(o.onRun))\nre-check: \(Self.describe(o.onRecheck))\n"
            + "run rows: \(Self.statuses(o.runReport))\nre-check rows: \(Self.statuses(o.recheckReport))")
        let runPage = try #require(o.onRun[0], "\(context)")
        // The run's own form. A Secure run makes no ink plan, so the
        // comparison below tests the clamp and the size floor.
        #expect(runPage.first { $0.id == o.regionIDs.inked }?.inkStripRects.isEmpty == true,
                "the run burns the name's box whole, with no ink strips\n\(context)")
        #expect(runPage.first { $0.id == o.regionIDs.pastTheEdge }?.normalizedRect.maxX == 1,
                "the run clamps the box past the edge\n\(context)")
        #expect(!runPage.contains { $0.id == o.regionIDs.underTheFloor },
                "the run drops the box under the floor\n\(context)")

        #expect(o.onRecheck == o.onRun, "the re-check is handed the regions as the run burned them\n\(context)")
        #expect(o.onRecheck[0]?.contains { $0.id == o.regionIDs.underTheFloor } == false,
                "the box under the floor reaches neither\n\(context)")
    }

    /// Every row the re-check does not skip by design (the checks that read
    /// the run's own page artifacts) reads as it read on the run.
    func sameRowStatusesOnRunAndRecheck() async throws {
        let o = try await Self.runThenRecheck()
        let context = ("run rows: \(Self.statuses(o.runReport))\n"
            + "re-check rows: \(Self.statuses(o.recheckReport))")
        let onRun = Dictionary(o.runReport.layers.map { ($0.name, $0.status) }, uniquingKeysWith: { a, _ in a })
        var compared = 0
        for layer in o.recheckReport.layers where layer.status != .skipped {
            let before = try #require(onRun[layer.name], "the row \(layer.name) is on the run's report\n\(context)")
            #expect("\(layer.status)" == "\(before)", "the row \(layer.name) reads the same on the re-check\n\(context)")
            compared += 1
        }
        #expect(compared > 0, "the re-check judged at least one row\n\(context)")
    }

    /// The kept regions are cleared with the output, with the rest of the
    /// run inputs.
    func clearedOutputKeepsNoRegions() async throws {
        let o = try await Self.runThenRecheck()
        let state = o.coordinator.redactionState
        #expect(state.lastRunInputs?.burnedRegions == o.onRun, "the run keeps the regions it burned")
        state.clearOutput()
        #expect(state.lastRunInputs?.burnedRegions == nil, "no kept regions remain once the output is cleared")
    }

    /// An export with no kept inputs (only the debug seed and tests make
    /// one): the re-check reads the live regions, as it did before.
    func noKeptInputsReadsLiveRegions() async throws {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeMultiPagePDFDocument(pages: 1)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recheck_live_\(UUID().uuidString).pdf")
        try makeMultiPagePDFData(pages: 1).write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let live = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.9, y: 0.1, width: 0.2, height: 0.05),
                                   source: .manual)
        coord.redactionState.addRegion(live, page: 0, undoManager: nil)
        coord.redactionState.outputURL = outputURL
        coord.redactionState.recordLastRunInputs(.fixture(perPageModes: [.secureRasterization]))
        #expect(coord.redactionState.lastRunInputs?.burnedRegions == nil)
        coord.documentState.lastUsedPipelineMode = .secureRasterization
        coord.documentState.phase = .verified(report: .skipped)

        var received: [Int: [RedactionRegion]]?
        coord.verificationRegionsSeam = { received = $0 }
        coord.runVerifyOnly()
        await coord.documentState.activePipelineTask?.value

        let regions = try #require(received, "the re-check ran its checks")
        #expect(regions == coord.redactionState.regions, "with no kept inputs the re-check reads the live regions")
        #expect(regions[0]?.first?.normalizedRect == live.normalizedRect, "as drawn, not clamped")
    }
}
