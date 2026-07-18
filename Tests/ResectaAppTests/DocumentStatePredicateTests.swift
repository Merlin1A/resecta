import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// Pkg D — uniform phase-gating predicates.
// Covers `canStartImport`, `canStartPipeline(_:)`, and `canMutateRegions`
// across every PhaseKind, plus the entry-point gates that read them.

@Suite("DocumentState gating predicates", .tags(.coordination))
@MainActor
struct DocumentStatePredicateTests {

    // MARK: - canStartImport

    @Test("canStartImport is true for empty, editing, verified, failed")
    func canStartImportPermittedPhases() {
        let permitted: [(String, () -> DocumentState.Phase)] = [
            ("empty", { .empty }),
            ("editing", { .editing }),
            ("verified", { .verified(report: Self.makePassingReport()) }),
            ("failed", { .failed(error: .importError(.corrupt), returnPhase: .empty) }),
        ]
        for (label, makePhase) in permitted {
            let doc = DocumentState()
            doc.phase = makePhase()
            #expect(doc.canStartImport, "Expected canStartImport == true for phase \(label)")
        }
    }

    @Test("canStartImport is false for importing, detecting, redacting, verifying, exporting")
    func canStartImportBlockedPhases() {
        let blocked: [(String, () -> DocumentState.Phase)] = [
            ("importing", { .importing }),
            ("detecting", { .detecting(progress: Self.detectingProgress()) }),
            ("redacting", { .redacting(progress: Self.redactingProgress()) }),
            ("verifying", { .verifying(progress: Self.verifyingProgress()) }),
            ("exporting", { .exporting }),
        ]
        for (label, makePhase) in blocked {
            let doc = DocumentState()
            doc.phase = makePhase()
            #expect(!doc.canStartImport, "Expected canStartImport == false for phase \(label)")
        }
    }

    // MARK: - canStartPipeline

    @Test("canStartPipeline requires editing phase")
    func canStartPipelineRequiresEditing() {
        let doc = DocumentState()
        doc.phase = .editing
        #expect(doc.canStartPipeline)

        doc.phase = .empty
        #expect(!doc.canStartPipeline)

        doc.phase = .verified(report: Self.makePassingReport())
        #expect(!doc.canStartPipeline)

        doc.phase = .detecting(progress: Self.detectingProgress())
        #expect(!doc.canStartPipeline)
    }

    @Test("canStartPipeline is false when an activePipelineTask is set")
    func canStartPipelineBlockedByActiveTask() {
        let doc = DocumentState()
        doc.phase = .editing
        #expect(doc.canStartPipeline)

        doc.activePipelineTask = Task {}
        #expect(!doc.canStartPipeline)

        doc.activePipelineTask?.cancel()
        doc.activePipelineTask = nil
        #expect(doc.canStartPipeline)
    }

    @Test("canStartPipeline(with:) returns false while triage is pending")
    func canStartPipelineWithBlockedByTriage() {
        let doc = DocumentState()
        let red = RedactionState()
        doc.phase = .editing

        #expect(doc.canStartPipeline(with: red))

        red.pendingTriage = [0: [DetectionResult.mock()]]
        #expect(!doc.canStartPipeline(with: red))

        red.pendingTriage = nil
        #expect(doc.canStartPipeline(with: red))
    }

    // MARK: - canMutateRegions

    @Test("canMutateRegions is true for empty, editing, importing, verified, failed")
    func canMutateRegionsPermittedPhases() {
        let permitted: [(String, () -> DocumentState.Phase)] = [
            ("empty", { .empty }),
            ("editing", { .editing }),
            ("importing", { .importing }),
            ("verified", { .verified(report: Self.makePassingReport()) }),
            ("failed", { .failed(error: .importError(.corrupt), returnPhase: .empty) }),
        ]
        for (label, makePhase) in permitted {
            let doc = DocumentState()
            doc.phase = makePhase()
            #expect(doc.canMutateRegions, "Expected canMutateRegions == true for phase \(label)")
        }
    }

    @Test("canMutateRegions is false for detecting, redacting, verifying, exporting")
    func canMutateRegionsBlockedPhases() {
        let blocked: [(String, () -> DocumentState.Phase)] = [
            ("detecting", { .detecting(progress: Self.detectingProgress()) }),
            ("redacting", { .redacting(progress: Self.redactingProgress()) }),
            ("verifying", { .verifying(progress: Self.verifyingProgress()) }),
            ("exporting", { .exporting }),
        ]
        for (label, makePhase) in blocked {
            let doc = DocumentState()
            doc.phase = makePhase()
            #expect(!doc.canMutateRegions, "Expected canMutateRegions == false for phase \(label)")
        }
    }

    // MARK: - Toast Copy

    @Test("Import-blocked toast copy matches the locked S2 string")
    func importBlockedToastCopyIsLocked() {
        // The exact string is part of the user-facing contract documented
        // in `04-implementer-handoff.md`. If this fails, update the spec.
        #expect(DocumentState.importBlockedDuringPipelineMessage
                == "Cannot import while processing. Try again after the current step finishes.")
    }

    // MARK: - Entry-point gating

    @Test("ImportService rejects when canStartImport is false")
    func importServiceRespectsCanStartImport() async {
        let doc = DocumentState()
        let red = RedactionState()
        // Force phase into .detecting so canStartImport is false.
        doc.phase = .editing
        doc.transition(to: .detecting(progress: Self.detectingProgress()))
        #expect(!doc.canStartImport)
        let phaseBefore = doc.phaseKind

        await ImportService.importDocument(
            data: makeTestPDFData(), suggestedType: "pdf",
            documentState: doc, redactionState: red
        )

        // The defensive precondition returns before any state mutation,
        // so the phase stays exactly where it was. No clearForNewDocument
        // call, no sourceDocument assignment.
        #expect(doc.phaseKind == phaseBefore)
        #expect(doc.sourceDocument == nil)
    }

    @Test("applyFindings returns nil when documentState is in pipeline-owning phase")
    func applySearchResultsRespectsCanMutateRegions() async {
        let doc = DocumentState()
        let red = RedactionState()
        doc.phase = .editing
        doc.transition(to: .detecting(progress: Self.detectingProgress()))
        #expect(!doc.canMutateRegions)

        // Activate a synthetic search session with one selected result.
        let search = SearchState()
        search.results = [
            SearchResult(
                id: UUID(),
                pageIndex: 0,
                normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05),
                matchedText: "Secret",
                contextSnippet: "context",
                source: .textLayer,
                term: "Secret",
                isSelected: true
            )
        ]
        red.activeSearch = search

        let result = await red.applyFindings(
            .selectedSearchResults, undoManager: nil, documentState: doc)
        #expect(result == nil, "applyFindings should refuse to mutate during pipeline phases")
        // No regions should have been created.
        #expect(red.regions.isEmpty || red.regions.values.allSatisfy { $0.isEmpty })
    }

    // MARK: - Helpers

    private static func detectingProgress() -> DocumentState.DetectionProgress {
        .init(currentPage: 0, totalPages: 1, currentStep: "Starting")
    }

    private static func redactingProgress() -> DocumentState.RedactionProgress {
        .init(currentPage: 0, totalPages: 1, currentStep: "Starting")
    }

    private static func verifyingProgress() -> DocumentState.VerificationProgress {
        .init(currentLayer: 1, totalLayers: 5,
              layerName: "Layer 1", completedLayers: [])
    }

    private static func makePassingReport() -> VerificationReport {
        VerificationReport(
            layers: [],
            overallStatus: .pass,
            durationSeconds: 0
        )
    }
}
