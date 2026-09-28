import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// The run-entry window. A full run reads its region state — the burned
// `pages`, the sensitive-term set, the deselection snapshot and the
// re-check requests — while the phase is still `.editing` and the canvas
// live; the manual-term capture in that prefix suspends the run. The
// invariant pinned here: every one of those reads comes from ONE region
// state, with no suspension point between the read and the `.redacting`
// transition, so a region drawn while the capture is pending is burned
// (the capture re-runs once when the region version moved); a run whose
// burned version is not the live one leaves the stale flag standing; an
// import is refused and the Home/Done close cancels while a run is pending.

@Suite("Run entry — the pending-run gates", .tags(.coordination))
@MainActor
struct RunEntryPendingRunGateTests {

    @Test("An import is refused while a run is pending, in every phase that otherwise admits one")
    func importRefusedWhileRunPending() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .editing
        #expect(doc.canStartImport == true, "precondition: editing with no run admits an import")
        #expect(doc.canStartImport(with: redaction) == true)

        let pending = Task<Void, Never> { await Task.yield() }
        doc.activePipelineTask = pending
        #expect(doc.canStartImport == false,
                "a run pending in `.editing` (the capture window) must refuse the drop and the pickers")
        #expect(doc.canStartImport(with: redaction) == false)

        doc.activePipelineTask = nil
        #expect(doc.canStartImport == true, "the gate reopens when the run ends")
        _ = await pending.value
    }

    @Test("The phase-only refusal keeps its own answer: a pending run never widens the phase set that admits an import")
    func pendingRunNeverAdmitsABlockedPhase() async {
        let doc = DocumentState()
        let pending = Task<Void, Never> { await Task.yield() }
        for phase in [DocumentState.Phase.importing,
                      .redacting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "s")),
                      .verifying(progress: .init(currentLayer: 1, totalLayers: 1, layerName: "l", completedLayers: [])),
                      .exporting] {
            doc.phase = phase
            doc.activePipelineTask = pending
            #expect(doc.canStartImport == false)
            doc.activePipelineTask = nil
            #expect(doc.canStartImport == false)
        }
        _ = await pending.value
    }

    @Test("Cancelling from `.editing` ends the pending run and leaves the session closable")
    func cancelFromEditingEndsThePendingRun() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .editing
        let started = UUID()
        doc.activeRunId = started
        doc.activePipelineTask = Task<Void, Never> {
            // The capture window: the run holds the task while the
            // detached capture works; nothing else moves.
            while !Task.isCancelled { await Task.yield() }
        }

        doc.cancelActivePipeline(redactionState: redaction)

        #expect(doc.activePipelineTask == nil)
        #expect(doc.phaseKind == .editing, "no phase to recover from — the run never left `.editing`")
        #expect(doc.transition(to: .empty), "the close that follows is a legal transition")
    }

    @Test("Source pin: the Done/Home teardown cancels a pending run before it clears the session")
    func doneCloseCancelsBeforeClearing() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView+Home.swift")
        let body = try #require(source.range(of: "func performDoneCloseSession() {"))
        let tail = source[body.upperBound...]
        let cancel = tail.range(of: "documentState.cancelActivePipeline(redactionState: redactionState)")
        let clear = try #require(tail.range(of: "redactionState.clearAll()"))
        #expect(cancel != nil, "the teardown must cancel a run pending in the capture window")
        if let cancel {
            #expect(cancel.lowerBound < clear.lowerBound,
                    "cancel first, then clear — the order `RedactWorkspace.tearDown()` keeps")
        }
    }

    @Test("Source pin: the capture is awaited first; the snapshot that follows, and the run up to `.redacting`, do not suspend")
    func captureFirstThenNoSuspension() throws {
        let source = try loadRepoFile("Sources/ResectaApp/State/PipelineRunner.swift")
        let start = try #require(source.range(of: "static func captureRunEntry("))
        let body = source[start.upperBound...]
        let end = try #require(body.range(of: "return RunEntry("))
        let function = body[..<end.lowerBound]
        let firstCapture = try #require(function.range(of: "await capture()"))
        let pages = try #require(function.range(of: "buildPDFPageData("))
        #expect(firstCapture.lowerBound < pages.lowerBound,
                "the awaited capture must precede the synchronous region snapshot")
        #expect(!function[pages.upperBound...].contains("await "),
                "no suspension point after the region snapshot")

        let runStart = try #require(source.range(of: "private func runFull("))
        let run = source[runStart.upperBound...]
        let entryCall = try #require(run.range(of: "captureRunEntry("))
        let redacting = try #require(run.range(of: ".redacting("))
        #expect(!run[entryCall.upperBound..<redacting.lowerBound].contains("await "),
                "the full run reaches `.redacting` without another suspension")
    }
}

@Suite("Run entry — one region state", .tags(.coordination))
@MainActor
struct RunEntryCaptureTests {

    private func makeEditingCoordinator() -> PipelineCoordinator {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.documentState.phase = .editing
        coord.redactionState.addRegion(.mock(), page: 0, undoManager: nil)
        return coord
    }

    private func drawRegion(_ coord: PipelineCoordinator, y: CGFloat) {
        coord.redactionState.addRegion(
            .mock(rect: CGRect(x: 0.5, y: y, width: 0.2, height: 0.05)),
            page: 0, undoManager: nil)
    }

    @Test("A region drawn while the capture is pending is in the burned pages, and the capture re-runs once")
    func regionDrawnDuringCaptureIsBurned() async throws {
        let coord = makeEditingCoordinator()
        var captureRuns = 0
        let entry = try await PipelineRunner.captureRunEntry(
            coordinator: coord, effectiveMode: .secureRasterization,
            runSettings: .snapshot(from: coord.settingsState)
        ) {
            captureRuns += 1
            if captureRuns == 1 { drawRegion(coord, y: 0.5) }
            return .empty
        }
        #expect(captureRuns == 2)
        #expect(entry.captureRuns == 2)
        #expect(entry.pages.count == 1)
        #expect(entry.pages[0].regions.count == 2,
                "the region drawn during the capture is in the burned pages")
        #expect(entry.burnedRegionVersion == coord.redactionState.regionVersion)
    }

    @Test("The re-run is bounded: a region drawn during the second capture is still burned; no third capture")
    func reRunIsBounded() async throws {
        let coord = makeEditingCoordinator()
        var captureRuns = 0
        let entry = try await PipelineRunner.captureRunEntry(
            coordinator: coord, effectiveMode: .secureRasterization,
            runSettings: .snapshot(from: coord.settingsState)
        ) {
            captureRuns += 1
            drawRegion(coord, y: 0.3 + 0.1 * CGFloat(captureRuns))
            return .empty
        }
        #expect(captureRuns == 2, "one re-run at most")
        #expect(entry.pages[0].regions.count == 3,
                "the pages are built after the last capture — every region drawn is burned")
        #expect(entry.burnedRegionVersion == coord.redactionState.regionVersion)
    }

    @Test("No region change during the capture: the capture runs once")
    func unchangedRegionsCaptureOnce() async throws {
        let coord = makeEditingCoordinator()
        var captureRuns = 0
        let entry = try await PipelineRunner.captureRunEntry(
            coordinator: coord, effectiveMode: .secureRasterization,
            runSettings: .snapshot(from: coord.settingsState)
        ) {
            captureRuns += 1
            return SensitiveTermSet(terms: [SensitiveTerm(text: "Springfield")])
        }
        #expect(captureRuns == 1)
        #expect(entry.captureRuns == 1)
        #expect(entry.sensitiveTerms.terms.map(\.text) == ["Springfield"])
        #expect(entry.pages[0].regions.count == 1)
    }

    @Test("A run cancelled while the capture is pending ends with CancellationError before it snapshots any state")
    func cancelledDuringCaptureEnds() async {
        let coord = makeEditingCoordinator()
        let run = Task<PipelineRunner.RunEntry, any Error> { @MainActor in
            try await PipelineRunner.captureRunEntry(
                coordinator: coord, effectiveMode: .secureRasterization,
                runSettings: .snapshot(from: coord.settingsState)
            ) {
                // The window: the detached capture works until the run is
                // cancelled from under it.
                while !Task.isCancelled { await Task.yield() }
                return .empty
            }
        }
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
    }
}

@Suite("Verification currency — the burned version", .tags(.coordination))
@MainActor
struct VerificationCurrencyTests {

    private func makeRedactingCoordinator() -> PipelineCoordinator {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.documentState.phase = .editing
        coord.redactionState.addRegion(.mock(), page: 0, undoManager: nil)
        coord.documentState.phase = .redacting(
            progress: .init(currentPage: 0, totalPages: 1, currentStep: "Starting\u{2026}"))
        return coord
    }

    private var report: VerificationReport {
        VerificationReport(layers: [], overallStatus: .pass, durationSeconds: 0)
    }

    @Test("`.verified` clears the stale flag when the burned version is the live one")
    func verifiedClearsForTheBurnedVersion() {
        let coord = makeRedactingCoordinator()
        #expect(coord.redactionState.isVerificationStale, "precondition: a drawn region marks the run stale")
        coord.apply(.verified(report, burnedRegionVersion: coord.redactionState.regionVersion))
        #expect(coord.documentState.phaseKind == .verified)
        #expect(coord.redactionState.isVerificationStale == false)
    }

    @Test("`.verified` keeps the stale flag for a region the run did not burn")
    func verifiedKeepsTheFlagPastTheBurnedVersion() {
        let coord = makeRedactingCoordinator()
        let burned = coord.redactionState.regionVersion
        coord.redactionState.addRegion(
            .mock(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.05)), page: 0, undoManager: nil)
        coord.apply(.verified(report, burnedRegionVersion: burned))
        #expect(coord.documentState.phaseKind == .verified, "the report is still published")
        #expect(coord.redactionState.isVerificationStale,
                "the output does not carry every region on screen — the banner stands")
    }

    @Test("`.verificationSkipped` follows the same rule")
    func skippedFollowsTheSameRule() {
        let cleared = makeRedactingCoordinator()
        cleared.apply(.verificationSkipped(burnedRegionVersion: cleared.redactionState.regionVersion))
        #expect(cleared.documentState.phaseKind == .verified)
        #expect(cleared.redactionState.isVerificationStale == false)

        let kept = makeRedactingCoordinator()
        let burned = kept.redactionState.regionVersion
        kept.redactionState.addRegion(
            .mock(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.05)), page: 0, undoManager: nil)
        kept.apply(.verificationSkipped(burnedRegionVersion: burned))
        #expect(kept.documentState.phaseKind == .verified)
        #expect(kept.redactionState.isVerificationStale)
    }

    @Test("The guard itself: an older or newer burned version leaves the flag; the live one clears it")
    func guardCompares() {
        let redaction = RedactionState()
        redaction.addRegion(.mock(), page: 0, undoManager: nil)
        let live = redaction.regionVersion
        redaction.markVerificationCurrent(burnedRegionVersion: live - 1)
        #expect(redaction.isVerificationStale)
        redaction.markVerificationCurrent(burnedRegionVersion: live + 1)
        #expect(redaction.isVerificationStale)
        redaction.markVerificationCurrent(burnedRegionVersion: live)
        #expect(redaction.isVerificationStale == false)
    }
}

// MARK: - Repo file loader (the house source-pin helper)

@MainActor
private func loadRepoFile(
    _ relativePath: String, from file: StaticString = #filePath
) throws -> String {
    let repoRoot = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()   // Tests/ResectaAppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // <repo root>
    return try String(
        contentsOf: repoRoot.appendingPathComponent(relativePath),
        encoding: .utf8)
}
