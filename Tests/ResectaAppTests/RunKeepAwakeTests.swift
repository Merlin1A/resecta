import Testing
import Foundation
import CoreGraphics
import PDFKit
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// The screen stays awake while a run works — redacting or checking — so the device's auto-lock cannot cut a long run short, and it
// may lock again the moment the run ends, however it ends: success, Stop, a
// failure, a thrown error, leaving the app or closing the document. The
// tests read the flag through the keep-awake seam, never `UIApplication`.

/// Records every write the keep-awake owner makes to the idle-timer flag.
@MainActor
final class IdleTimerRecorder {
    private(set) var writes: [Bool] = []
    /// The flag as the system would hold it: off until the first write.
    var isIdleTimerDisabled: Bool { writes.last ?? false }

    func makeKeepAwake() -> RunKeepAwake {
        RunKeepAwake(setIdleTimerDisabled: { [self] in writes.append($0) })
    }
}

@Suite("A run keeps the screen awake, and every way out lets it lock", .tags(.coordination))
@MainActor
struct RunKeepAwakeTests {

    private static let redacting = DocumentState.Phase.redacting(
        progress: .init(currentPage: 0, totalPages: 1, currentStep: "s"))
    private static let verifying = DocumentState.Phase.verifying(
        progress: .init(currentLayer: 1, totalLayers: 5, layerName: "Layer 1", completedLayers: []))

    /// The run phases production enters (`.detecting` has no writer).
    enum RunPhase: String, CaseIterable, CustomTestStringConvertible {
        case redacting, verifying
        var testDescription: String { rawValue }
    }

    /// A document in the editor whose idle-timer writes the recorder sees,
    /// moved into `run` by the legal path a run takes.
    private func document(in run: RunPhase, recorder: IdleTimerRecorder) -> (DocumentState, RedactionState) {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.sourceDocument = makeTestPDFDocument()
        doc.phase = .editing
        doc.keepAwake = recorder.makeKeepAwake()
        enter(run, doc)
        return (doc, redaction)
    }

    /// Move an editing document into `run` by the legal path a run takes.
    private func enter(_ run: RunPhase, _ doc: DocumentState) {
        switch run {
        case .redacting:
            doc.transition(to: Self.redacting)
        case .verifying:
            doc.transition(to: Self.redacting)
            doc.transition(to: Self.verifying)
        }
    }

    private func addRegion(to coord: PipelineCoordinator) {
        coord.redactionState.addRegion(
            RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
                            source: .manual),
            page: 0, undoManager: nil)
    }

    // MARK: - On while a run works

    @Test("Each run phase keeps the screen awake", arguments: RunPhase.allCases)
    func eachRunPhaseKeepsTheScreenAwake(run: RunPhase) {
        let recorder = IdleTimerRecorder()
        let (doc, _) = document(in: run, recorder: recorder)
        #expect(recorder.isIdleTimerDisabled, "\(doc.phaseKind) must keep the screen awake")
        #expect(recorder.writes == [true], "one write on the way in, none on the hand-off to the next run phase")
    }

    @Test("Progress ticks write nothing more")
    func progressTicksWriteNothing() {
        let recorder = IdleTimerRecorder()
        let (doc, _) = document(in: .verifying, recorder: recorder)
        doc.transition(to: .verifying(progress: .init(
            currentLayer: 2, totalLayers: 5, layerName: "Layer 2", completedLayers: [])))
        #expect(recorder.writes == [true])
    }

    @Test("Outside a run the screen may lock",
          arguments: [DocumentState.Phase.empty, .importing, .editing, .verified(report: .skipped),
                      .exporting])
    func outsideARunTheScreenMayLock(phase: DocumentState.Phase) {
        let recorder = IdleTimerRecorder()
        let doc = DocumentState()
        doc.keepAwake = recorder.makeKeepAwake()
        doc.phase = phase
        #expect(recorder.isIdleTimerDisabled == false)
        #expect(!recorder.writes.contains(true), "\(doc.phaseKind) never keeps the screen awake")
    }

    // MARK: - Every way out lets it lock

    @Test("Finishing the checks lets the screen lock")
    func successReleases() {
        let recorder = IdleTimerRecorder()
        let (doc, _) = document(in: .verifying, recorder: recorder)
        doc.transition(to: .verified(report: VerificationReport(
            layers: [], overallStatus: .pass, durationSeconds: 0.1)))
        #expect(recorder.isIdleTimerDisabled == false)
        #expect(recorder.writes == [true, false])
    }

    @Test("A run with the checks off lets the screen lock when it lands on the results")
    func skippedChecksRelease() {
        let recorder = IdleTimerRecorder()
        let (doc, _) = document(in: .redacting, recorder: recorder)
        doc.transition(to: .verified(report: .skipped(reason: .autoVerifyOff)))
        #expect(recorder.writes == [true, false])
    }

    @Test("Stop lets the screen lock", arguments: RunPhase.allCases)
    func stopReleases(run: RunPhase) {
        let recorder = IdleTimerRecorder()
        let (doc, redaction) = document(in: run, recorder: recorder)
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(recorder.isIdleTimerDisabled == false, "Stop from \(run) left the screen awake")
        #expect(recorder.writes == [true, false])
    }

    @Test("A failure lets the screen lock", arguments: RunPhase.allCases)
    func failureReleases(run: RunPhase) {
        let recorder = IdleTimerRecorder()
        let (doc, _) = document(in: run, recorder: recorder)
        doc.transition(to: .failed(error: .redactionError(.reconstructionFailed), returnPhase: .editing))
        #expect(recorder.isIdleTimerDisabled == false, "a failure from \(run) left the screen awake")
        #expect(recorder.writes == [true, false])
    }

    @Test("Leaving the app lets the screen lock", arguments: RunPhase.allCases)
    func backgroundReleases(run: RunPhase) {
        let recorder = IdleTimerRecorder()
        let (doc, redaction) = document(in: run, recorder: recorder)
        ContentView.cancelForBackground(documentState: doc, redactionState: redaction)
        #expect(recorder.isIdleTimerDisabled == false, "leaving the app from \(run) left the screen awake")
        #expect(recorder.writes == [true, false])
    }

    @Test("Closing the document mid-run lets the screen lock", arguments: RunPhase.allCases)
    func documentCloseReleases(run: RunPhase) {
        let recorder = IdleTimerRecorder()
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = RedactWorkspace(
            settingsState: SettingsState(defaults: defaults),
            userTermsStore: UserTermsStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("keep-awake-\(UUID().uuidString).json"),
                legacyDefaults: defaults))
        let doc = workspace.documentState
        doc.sourceDocument = makeTestPDFDocument()
        doc.phase = .editing
        doc.keepAwake = recorder.makeKeepAwake()
        enter(run, doc)
        #expect(recorder.isIdleTimerDisabled)

        workspace.tearDown()

        #expect(recorder.isIdleTimerDisabled == false, "closing the document from \(run) left the screen awake")
    }

    @Test("A keep-awake owner that goes away mid-run lets the screen lock")
    func droppedOwnerReleases() {
        let recorder = IdleTimerRecorder()
        var keepAwake: RunKeepAwake? = recorder.makeKeepAwake()
        keepAwake?.update(for: .verifying)
        #expect(recorder.isIdleTimerDisabled)
        keepAwake = nil
        #expect(recorder.isIdleTimerDisabled == false)
    }

    // MARK: - Real runs

    @Test("A real run keeps the screen awake while it works and lets it lock when it ends",
          .timeLimit(.minutes(2)))
    func realRunReleasesAtItsEnd() async throws {
        let recorder = IdleTimerRecorder()
        let coord = makeLoadedCoordinator()
        coord.documentState.keepAwake = recorder.makeKeepAwake()
        addRegion(to: coord)
        var awakeDuringTheChecks = false
        coord.beforeVerificationLoadsSeam = { awakeDuringTheChecks = recorder.isIdleTimerDisabled }

        coord.runFullPipeline(documentOverride: .secureRasterization)
        let task = try #require(coord.documentState.activePipelineTask, "the run started")
        await task.value

        #expect(recorder.writes.first == true, "the run kept the screen awake")
        #expect(awakeDuringTheChecks, "awake as the checks start (else the run failed earlier: simulator resources)")
        #expect(recorder.isIdleTimerDisabled == false,
                "the run ended on \(coord.documentState.phaseKind) and left the screen awake")
        #expect(recorder.writes.last == false)
    }

    @Test("An error thrown mid-run lets the screen lock", .timeLimit(.minutes(1)))
    func thrownErrorMidRunReleases() async throws {
        let recorder = IdleTimerRecorder()
        // A page past the 5,000-pt cap: the rasterizer's pre-flight throws
        // once the run is redacting.
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 5200, height: 300))
        let data = renderer.pdfData { ctx in ctx.beginPage() }
        let coord = makeLoadedCoordinator(document: try #require(PDFDocument(data: data)))
        coord.documentState.keepAwake = recorder.makeKeepAwake()
        addRegion(to: coord)

        coord.runFullPipeline(documentOverride: .secureRasterization)
        let task = try #require(coord.documentState.activePipelineTask, "the run started")
        await task.value

        guard case .failed = coord.documentState.phase else {
            Issue.record("expected the oversized page to fail the run, got \(coord.documentState.phaseKind)")
            return
        }
        #expect(recorder.writes == [true, false], "awake while redacting, then free to lock")
    }

    @Test("A real run cut by leaving the app as its checks start lets the screen lock",
          .timeLimit(.minutes(2)))
    func realRunBackgroundedReleases() async throws {
        let recorder = IdleTimerRecorder()
        let coord = makeLoadedCoordinator()
        coord.documentState.keepAwake = recorder.makeKeepAwake()
        addRegion(to: coord)
        coord.beforeVerificationLoadsSeam = { [weak coord] in
            guard let coord else { return }
            ContentView.cancelForBackground(
                documentState: coord.documentState, redactionState: coord.redactionState)
        }

        coord.runFullPipeline(documentOverride: .secureRasterization)
        let task = try #require(coord.documentState.activePipelineTask, "the run started")
        await task.value

        #expect(recorder.writes == [true, false])
        #expect(coord.documentState.phaseKind == .editing)
    }
}
