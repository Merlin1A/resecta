import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// The run's record, kept beside the export. Before the writer runs, the run
// entry records what the user confirmed: every region as drawn, before the
// clamp to the page and the size floor, the fill colour and the quality.
// What the producer says it did is kept beside it. The record is one field of
// the run inputs that are stored with the output, kept for a re-check of the
// same session and cleared with the output by `clearOutput()`. It is a value
// in memory only and is not encodable. A session holding an output with no
// run inputs has no record, and none is made from the live regions.

@Suite("The run's record beside the export", .serialized, .tags(.coordination))
@MainActor
struct RunRecordTests {

    enum Case: String, CaseIterable, CustomTestStringConvertible {
        case regionsAsDrawn
        case oneRegionStateAtEntry
        case recheckKeepsTheRecord
        case clearedWithTheOutput
        case notEncodableAndWrittenNowhere
        case noInputsNoRecord
        case boxFillReadsTheRunsOwnRecord
        var testDescription: String { rawValue }
    }

    @Test("The table holds exactly seven cases")
    func tableLength() {
        #expect(Case.allCases.count == 7)
    }

    @Test("Each case", .timeLimit(.minutes(3)), arguments: Case.allCases)
    func each(_ c: Case) async throws {
        switch c {
        case .regionsAsDrawn: try await regionsAsDrawn()
        case .oneRegionStateAtEntry: try await oneRegionStateAtEntry()
        case .recheckKeepsTheRecord: try await recheckKeepsTheRecord()
        case .clearedWithTheOutput: try await clearedWithTheOutput()
        case .notEncodableAndWrittenNowhere: try notEncodableAndWrittenNowhere()
        case .noInputsNoRecord: try await noInputsNoRecord()
        case .boxFillReadsTheRunsOwnRecord: try await boxFillReadsTheRunsOwnRecord()
        }
    }

    // MARK: - Helpers

    private func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }

    private func loadRepoFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    static func region(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }

    static func editingCoordinator() -> PipelineCoordinator {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.documentState.phase = .editing
        return coord
    }

    static func entry(_ coord: PipelineCoordinator,
                      capture: @MainActor () async -> SensitiveTermSet = { .empty }) async throws -> PipelineRunner.RunEntry {
        try await PipelineRunner.captureRunEntry(
            coordinator: coord, effectiveMode: .secureRasterization,
            runSettings: .snapshot(from: coord.settingsState), capture: capture)
    }

    static func drawn(_ regions: [RedactionRegion]) -> [RunRecord.DrawnRegion] {
        regions.map { RunRecord.DrawnRegion(region: $0) }
    }

    /// A finished run of one page with one box, verified, its inputs kept.
    static func finishedRun() async throws -> PipelineCoordinator {
        let coord = makeLoadedCoordinator()
        coord.redactionState.addRegion(region(CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.05)),
                                       page: 0, undoManager: nil)
        coord.runFullPipeline(documentOverride: .secureRasterization)
        let run = try #require(coord.documentState.activePipelineTask, "the run started")
        await run.value
        try #require(coord.redactionState.outputURL != nil, "the run made an output: \(coord.documentState.phaseKind)")
        return coord
    }

    // MARK: - Cases

    /// A region that reaches past the page's edge, one 0.0005 of the page
    /// high, one wholly off the right and one wholly off the left: the record
    /// holds all four as drawn; the pages hold the first clamped, not the
    /// second, and nothing for the one off the right.
    func regionsAsDrawn() async throws {
        let coord = Self.editingCoordinator()
        let pastTheEdge = Self.region(CGRect(x: 0.8, y: 0.5, width: 0.4, height: 0.05))
        let thin = Self.region(CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.0005))
        let offRight = Self.region(CGRect(x: 1.2, y: 0.6, width: 0.3, height: 0.05))
        let offLeft = Self.region(CGRect(x: -0.5, y: 0.7, width: 0.3, height: 0.05))
        let all = [pastTheEdge, thin, offRight, offLeft]
        for r in all { coord.redactionState.addRegion(r, page: 0, undoManager: nil) }

        let entry = try await Self.entry(coord)
        let record = try #require(entry.confirmed.pages.first)
        #expect(entry.confirmed.pages.map(\.pageIndex) == [0])
        #expect(record.regions == Self.drawn(all), "the record holds every region as drawn: \(record.regions)")
        #expect(record.regions.first { $0.id == offLeft.id }?.normalizedRect.minX == -0.5,
                "the region off the left is held with its start before the page")
        #expect(entry.confirmed.fillColor == coord.settingsState.fillColor)
        #expect(entry.confirmed.exportDPI == coord.settingsState.exportDPI)

        let page = try #require(entry.pages.first?.regions)
        let clamped = try #require(page.first { $0.id == pastTheEdge.id }, "the pages hold the box past the edge")
        #expect(clamped.normalizedRect.maxX == 1, "the pages hold it clamped: \(clamped.normalizedRect)")
        #expect(!page.contains { $0.id == thin.id }, "the pages drop the box under the floor")
        #expect(!page.contains { $0.id == offRight.id }, "the pages hold nothing for the box off the right")
    }

    /// A region drawn while the run entry's capture is pending: the record and
    /// the pages describe the same region state.
    func oneRegionStateAtEntry() async throws {
        let coord = Self.editingCoordinator()
        coord.redactionState.addRegion(.mock(), page: 0, undoManager: nil)
        var captureRuns = 0
        let entry = try await Self.entry(coord) {
            captureRuns += 1
            if captureRuns == 1 {
                coord.redactionState.addRegion(.mock(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.05)),
                                               page: 0, undoManager: nil)
            }
            return .empty
        }
        let recordIDs = entry.confirmed.pages.flatMap { $0.regions.map(\.id) }
        let pageIDs = entry.pages.flatMap { $0.regions.map(\.id) }
        #expect(recordIDs.count == 2, "the region drawn during the capture is in the record")
        #expect(recordIDs == pageIDs, "the record and the pages describe one region state")
        #expect(entry.confirmed.pages.first?.regions == Self.drawn(coord.redactionState.regions[0] ?? []))
    }

    /// A finished run, then a re-check in the same session: the re-check
    /// keeps the run's record, part 2 included; it neither drops nor remakes it.
    func recheckKeepsTheRecord() async throws {
        let coord = try await Self.finishedRun()
        let record = try #require(coord.redactionState.lastRunInputs?.record, "the run keeps its record")
        #expect(record.confirmed.pages.first?.regions == Self.drawn(coord.redactionState.regions[0] ?? []))

        coord.runVerifyOnly()
        let recheck = try #require(coord.documentState.activePipelineTask, "the re-check started")
        await recheck.value
        #expect(coord.redactionState.lastRunInputs?.record == record,
                "the re-check is given the same record, its producer's part included")
    }

    /// A finished run, then each way the output is cleared: no record remains.
    func clearedWithTheOutput() async throws {
        let coord = try await Self.finishedRun()
        let state = coord.redactionState
        let kept = try #require(state.lastRunInputs, "the run keeps its inputs")
        try #require(kept.record != nil)

        let ways: [(String, () -> Void)] = [
            ("the output discarded", { state.clearOutput() }),
            ("a region edited", { state.markRegionsModified() }),
            ("a new document", { state.clearForNewDocument() }),
            ("a run cancelled while redacting", {
                coord.documentState.phase = .redacting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "s"))
                coord.documentState.cancelActivePipeline(redactionState: state)
            }),
        ]
        for (name, clear) in ways {
            state.recordLastRunInputs(kept)
            #expect(state.lastRunInputs?.record != nil, "\(name): the record is kept before the clear")
            clear()
            #expect(state.lastRunInputs?.record == nil, "\(name): no record remains")
        }
    }

    /// The type is not encodable, and nothing in its file writes it anywhere.
    func notEncodableAndWrittenNowhere() throws {
        let types: [(String, Any.Type)] = [
            ("RunRecord", RunRecord.self), ("Confirmed", RunRecord.Confirmed.self),
            ("Page", RunRecord.Page.self), ("DrawnRegion", RunRecord.DrawnRegion.self),
            ("Produced", RunRecord.Produced.self),
        ]
        for (name, type) in types {
            #expect(!(type is any Encodable.Type), "\(name) must not be encodable")
        }
        let source = try loadRepoFile("Packages/RedactionEngine/Sources/RedactionEngine/Models/RunRecord.swift")
        for word in ["Codable", "Encodable", "Encoder", "FileManager", "write(", "UserDefaults", "Logger", "os_log", "print(", "NSLog"] {
            #expect(!source.contains(word), "the record's file must not name \(word)")
        }
    }

    /// An output with no run inputs (only the debug seed and tests make one):
    /// there is no record, and a re-check makes none from the live regions.
    func noInputsNoRecord() async throws {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeMultiPagePDFDocument(pages: 1)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("record_none_\(UUID().uuidString).pdf")
        try makeMultiPagePDFData(pages: 1).write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        coord.redactionState.addRegion(Self.region(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)),
                                       page: 0, undoManager: nil)
        coord.redactionState.outputURL = outputURL
        coord.documentState.lastUsedPipelineMode = .secureRasterization
        coord.documentState.phase = .verified(report: .skipped)
        #expect(coord.redactionState.lastRunInputs == nil)

        coord.runVerifyOnly()
        await coord.documentState.activePipelineTask?.value
        #expect(coord.redactionState.lastRunInputs?.record == nil, "no record is built from the live regions")
    }

    /// A finished run, verified against its own record: the writer recorded
    /// each page's picture as it went to the file, so the box check reads
    /// every page and the Box Fill row reads Passed.
    func boxFillReadsTheRunsOwnRecord() async throws {
        let coord = try await Self.finishedRun()
        #expect(coord.redactionState.lastRunInputs?.record != nil, "the run keeps its record")
        guard case .verified(let report) = coord.documentState.phase else {
            Issue.record("the run was not verified: \(coord.documentState.phaseKind)")
            return
        }
        let row = try #require(report.layers.first { $0.layer == .boxFill }, "the report has a Box Fill row")
        #expect(row.status == .pass, "\(row.status): \(row.shortDescription)")
        #expect(row.couldNotVerify == false)
    }
}
