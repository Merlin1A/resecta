import Foundation
import PDFKit
import Testing
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

/// The open document's page reads: read once per document, by page index,
/// emptied when another document opens, and handed to the run's record.
@Suite("Document page reads")
@MainActor
struct DocumentPageReadsTests {

    /// Pages that each carry their own typed line.
    static func document(_ lines: [String]) -> PDFDocument { PDFDocument(data: data(lines))! }

    static func data(_ lines: [String]) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            for line in lines {
                ctx.beginPage()
                (line as NSString).draw(at: CGPoint(x: 72, y: 72),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
        return data
    }

    /// One page's read, from a document of its own made from `data`.
    static func read(_ data: Data, page: Int) async -> RunRecord.PageRead? {
        await RunRecord.PageRead.reads(of: SendablePDFDocument(PDFDocument(data: data)!), pages: [page],
                                       hasHiddenOCG: false)[page]
    }

    @Test("A fill reads only the listed pages, each as the engine reads that page, and keeps what it read")
    func fillReadsTheListedPages() async throws {
        let coord = makeCoordinator()
        let lines = ["Ann Lee", "Roe Park", "Sam Hill"]
        coord.documentState.sourceDocument = Self.document(lines)
        await coord.documentState.fillPageReads(for: [0, 2])
        #expect(Set(coord.documentState.pageReads.keys) == [0, 2])
        let first = try #require(await Self.read(Self.data(lines), page: 2))
        #expect(coord.documentState.pageReads[2] == first)
        #expect(coord.documentState.pageReads[0] != coord.documentState.pageReads[2], "each page its own read")
        await coord.documentState.fillPageReads(for: [1])
        #expect(Set(coord.documentState.pageReads.keys) == [0, 1, 2])
    }

    @Test("Another document empties the reads, and a fill then reads the new document's pages")
    func newDocumentEmptiesTheReads() async throws {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = Self.document(["Ann Lee"])
        await coord.documentState.fillPageReads(for: [0])
        let old = try #require(coord.documentState.pageReads[0])
        coord.documentState.sourceDocument = Self.document(["Roe Park"])
        #expect(coord.documentState.pageReads.isEmpty)
        await coord.documentState.fillPageReads(for: [0])
        let read = try #require(coord.documentState.pageReads[0])
        #expect(read != old)
        #expect(read == (await Self.read(Self.data(["Roe Park"]), page: 0)))
    }

    @Test("With no document, a fill keeps nothing")
    func noDocumentNoReads() async {
        let coord = makeCoordinator()
        await coord.documentState.fillPageReads(for: [0])
        #expect(coord.documentState.pageReads.isEmpty)
    }

    @Test("Source pin: the record hands each page the read held for that page, and the run fills the reads only while the plan reads words")
    func runHandsEachPageItsRead() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        func file(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let inputs = try file("Sources/ResectaApp/State/RunInputs.swift")
        #expect(inputs.contains("switchOn: snapshot.boxesAcrossColumn, read: reads[page],"))
        #expect(inputs.components(separatedBy: "reads[").count == 2, "one read handed, by the page's own index")
        let runner = try file("Sources/ResectaApp/State/PipelineRunner.swift")
        let start = try #require(runner.range(of: "static func captureRunEntry("))
        let body = runner[start.upperBound...]
        let fill = try #require(body.range(of: "fillPageReads("))
        let guardLine = try #require(body.range(of: "if RunRecord.planReadsWords {"))
        let record = try #require(body.range(of: "let confirmed = RunInputs.confirmedRecord("))
        #expect(guardLine.lowerBound < fill.lowerBound && fill.lowerBound < record.lowerBound)
        #expect(body[record.upperBound...].hasPrefix("\n            pageCount:"))
        #expect(runner.contains("reads: coordinator.documentState.pageReads, settings: runSettings)"))
    }

    @Test("Source pin: the editor keeps each page's plan with the user's switch and the page's read, as the run's entry makes it")
    func keptPlanTakesTheReadAndTheSwitch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinator = try String(contentsOf: root.appendingPathComponent("Sources/ResectaApp/Overlay/PDFViewCoordinator.swift"),
                                     encoding: .utf8)
        let start = try #require(coordinator.range(of: "func noteDrawn("))
        let body = coordinator[start.upperBound...]
        #expect(body.contains("let read = documentState.pageReads[pageIndex]"))
        #expect(body.contains("if RunRecord.planReadsWords, read == nil, !regions.isEmpty {"))
        #expect(body.contains("switchOn: settings.boxesAcrossColumn,"))
        #expect(body.contains("fillColor: settings.fillColor, read: read)"))
    }

    @Test("The plan reads the page's words, so the run reads each page that holds a box at entry: one text read per such page per run")
    func planReadsWordsSoTheRunReads() {
        #expect(RunRecord.planReadsWords)
    }
}
