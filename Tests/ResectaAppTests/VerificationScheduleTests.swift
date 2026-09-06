import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// Schedule-by-phase pins. The coordinator derives its verification schedule
// from `VerificationEngine.layers(for:)` grouped by `VerificationLayer.phase`
// (never index arithmetic); the published progress appends results in
// completion order while the REPORT is assembled in canonical order; the
// Search Re-check runs last and, with nothing applied, reports INFO.

@Suite("Verification schedule by phase")
@MainActor
struct VerificationScheduleTests {

    @Test("The phases are the mode's layers grouped by phase; the re-check is last",
          arguments: [PipelineMode.secureRasterization, PipelineMode.searchableRedaction])
    func phaseGrouping(mode: PipelineMode) {
        let layers = VerificationEngine().layers(for: mode)
        let parallel = layers.filter { $0.phase == .parallelBase }
        let catalog = layers.filter { $0.phase == .catalogSequential }
        let sandwich = layers.filter { $0.phase == .sandwichSequential }
        let post = layers.filter { $0.phase == .postSequential }
        #expect(parallel.count + catalog.count + sandwich.count + post.count == layers.count)
        #expect(catalog == [.structureCheck, .metadataCheck])
        #expect(post == [.searchRecheck])
        #expect(layers.last == .searchRecheck)
        switch mode {
        case .secureRasterization:
            #expect(layers.count == 6)
            #expect(parallel == [.textExtraction, .ocrCheck, .binaryStringSearch])
            #expect(sandwich.isEmpty)
        case .searchableRedaction:
            #expect(layers.count == 11)
            #expect(parallel == [.textExtraction, .ocrCheck, .binaryStringSearch, .operatorReExtraction])
            #expect(sandwich == [.spatialVerification, .characterCount, .fontVerification, .characterLineage])
        }
    }

    /// In-process verify-only run on blank pages (the
    /// `VerificationPageCountIntegrityTests` shape) in the given mode.
    private func verifyOnlyReport(mode: PipelineMode, pages: Int = 2) async throws -> VerificationReport {
        let coordinator = makeCoordinator()
        let documentState = coordinator.documentState
        let redactionState = coordinator.redactionState
        documentState.sourceDocument = makeMultiPagePDFDocument(pages: pages)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv_schedule_\(UUID().uuidString).pdf")
        try makeMultiPagePDFData(pages: pages).write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        redactionState.outputURL = outputURL
        documentState.lastUsedPipelineMode = mode
        documentState.phase = .verified(report: .skipped)

        coordinator.runVerifyOnly()
        await documentState.activePipelineTask?.value

        guard case .verified(let report) = documentState.phase else {
            Issue.record("Expected .verified after verify-only; phase = \(documentState.phaseKind)")
            throw ScheduleTestError.notVerified
        }
        return report
    }

    private enum ScheduleTestError: Error { case notVerified }

    @Test("Raster verify-only reports six layers in canonical order, the re-check last as INFO")
    func rasterReportIsCanonical() async throws {
        let report = try await verifyOnlyReport(mode: .secureRasterization)
        let expected = VerificationEngine().layers(for: .secureRasterization)
        #expect(report.layers.count == 6)
        #expect(report.layers.map(\.name) == expected.map(\.name))
        #expect(report.layers.map(\.layer) == expected.map { Optional($0) })
        let last = try #require(report.layers.last)
        #expect(last.layer == .searchRecheck)
        #expect(last.name == "Search Re-check")
        #expect(last.status == .info(""))
        #expect(last.shortDescription == SearchRecheck.infoMessage)
        #expect(!report.layers.contains { $0.status.isSkipped },
                "an idle re-check is a note, never a skipped layer")
    }

    @Test("Searchable verify-only reports eleven layers in canonical order; the parallel-batch layer keeps its ordinal")
    func searchableReportIsCanonical() async throws {
        let report = try await verifyOnlyReport(mode: .searchableRedaction)
        let expected = VerificationEngine().layers(for: .searchableRedaction)
        #expect(report.layers.count == 11)
        #expect(report.layers.map(\.name) == expected.map(\.name))
        // Operator Re-Extraction completes in the parallel base batch but
        // the report places it at its canonical ordinal (index 9).
        #expect(report.layers[9].layer == .operatorReExtraction)
        #expect(report.layers[10].layer == .searchRecheck)
        #expect(report.layers[10].status == .info(""))
    }

    @Test("The idle re-check row reads as an informational note, never a warn or attention row")
    func idleRecheckRowIsNote() {
        let row = LayerResult(
            name: VerificationLayer.searchRecheck.name,
            symbolName: VerificationLayer.searchRecheck.symbolName,
            status: .info(SearchRecheck.infoMessage),
            shortDescription: SearchRecheck.infoMessage,
            detailDescription: "Search Re-check reported informational metadata: \(SearchRecheck.infoMessage)",
            pageReferences: nil, durationSeconds: 0, layer: .searchRecheck)
        // The results view's grouping predicates: NOTES = info; FINDINGS =
        // warn / attention / fail / skipped.
        #expect(row.status.isInfo)
        #expect(!row.status.isWarn && !row.status.isAttention && !row.status.isFail && !row.status.isSkipped)
        #expect(LayerResultRow.rowSubtitleText(layer: row) == SearchRecheck.infoMessage)
        #expect(row.completionAnnouncement(layerNumber: 6)
                == "Layer 6, Search Re-check, \(row.status.layerAccessibilityPhrase) \(SearchRecheck.infoMessage)")
    }
}
