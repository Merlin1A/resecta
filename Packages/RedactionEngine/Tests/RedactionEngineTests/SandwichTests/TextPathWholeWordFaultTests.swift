import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// A fault in the extract step, the filter, the paint marks or the
// whole-word closure never writes more text. Each step faults three ways (it throws, it returns
// nothing, it cannot read its input) on the first, the middle or the last
// page of a three-page file: that page is a picture with the fault's reason
// and the others are written as before. No step has a time limit of its own,
// so there is no time-limit row. A step that is cancelled offers no file: one
// row a step. All text is invented.

@Suite("A fault in the extract step, the filter, the paint marks or the closure makes its page a picture", .serialized)
struct TextPathWholeWordFaultTests {

    enum Step: String, CaseIterable, Sendable { case extract, filter, paintMarks, closure }
    enum Fault: String, CaseIterable, Sendable { case throwsError, returnsNothing, cannotReadItsInput }

    struct Row: Sendable, CustomTestStringConvertible {
        let step: Step
        let fault: Fault
        let page: Int
        var testDescription: String { "\(step.rawValue), \(fault.rawValue), page \(page + 1) of 3" }
    }

    struct StepFailed: Error {}
    struct InputUnreadable: Error {}

    /// The one word each page holds and no other does.
    static let markers = ["Northern", "Central", "Southern"]

    static let rows: [Row] = Step.allCases.flatMap { step in
        Fault.allCases.flatMap { fault in (0..<3).map { Row(step: step, fault: fault, page: $0) } }
    }

    @Test("The fault rows are thirty-six")
    func rowCount() {
        #expect(Self.rows.count == 36)
    }

    /// Three pages, each its own invented line, drawn by the system at test
    /// time and never stored.
    static func threePages() throws -> Data {
        TestFixtures.textPagesPDF(markers.map { "\($0) depot stock count" })
    }

    static func onPage(_ entries: [CharacterInfo], _ page: Int) -> Bool {
        entries.map(\.character).joined().contains(markers[page])
    }

    static func faulting(_ step: Step, page: Int, _ fault: @escaping @Sendable () throws -> Void) -> PageTextPath.Steps {
        var steps = PageTextPath.Steps.live
        switch step {
        case .extract:
            steps.extract = { data in
                if (data.page.string ?? "").contains(markers[page]) { try fault(); return nil }
                return try await TextLayerExtractor().extractCharacters(from: data.page, hasHiddenOCG: data.hasHiddenOCG)
            }
        case .filter:
            steps.filter = { entries, rectangles, frame in
                if onPage(entries, page) { try fault(); return nil }
                return try await TextPathFilter.filter(entries, rectangles, frame: frame)
            }
        case .paintMarks:
            steps.paintMarks = { survivors, painted, frame in
                if onPage(survivors, page) { try fault(); return nil }
                return TextPathPaintMarks.marks(survivors, painted: painted, frame: frame)
            }
        case .closure:
            steps.closure = { result, marked in
                if onPage(result.surviving, page) { try fault(); return nil }
                return PageTextPath.closeOverMarkedWords(result, marked: marked)
            }
        }
        return steps
    }

    @Test("A faulting step makes its page a picture with the fault's reason; the other pages are written", arguments: rows)
    func faultRow(_ row: Row) async throws {
        let data = try Self.threePages()
        let fault: @Sendable () throws -> Void
        switch row.fault {
        case .throwsError: fault = { throw StepFailed() }
        case .returnsNothing: fault = {}
        case .cannotReadItsInput: fault = { throw InputUnreadable() }
        }
        let steps = Self.faulting(row.step, page: row.page, fault)
        let run = try await PageTextPath.$steps.withValue(steps) {
            try await TestPipeline.productionRun(data, mode: .searchableRedaction, regions: [0: [], 1: [], 2: []])
        }
        defer { try? FileManager.default.removeItem(at: run.url) }
        let modes = (0..<3).map { $0 == row.page ? PipelineMode.secureRasterization : .searchableRedaction }
        let reasons = (0..<3).map { $0 == row.page ? TextLayerDetector.FallbackReason.extractionFailed : nil }
        #expect(run.outcome.perPageModes == modes, "\(row)")
        #expect(run.outcome.perPageFallbackReasons == reasons, "\(row): \(run.outcome.perPageFallbackReasons)")
        let document = try #require(PDFDocument(url: run.url))
        #expect(document.pageCount == 3)
        for index in 0..<3 {
            let text = document.page(at: index)?.string ?? ""
            if index == row.page {
                #expect(text.isEmpty, "\(row): the picture page holds no text")
            } else {
                #expect(text.contains(Self.markers[index]), "\(row): page \(index + 1) reads \(text.debugDescription)")
            }
        }
    }

    @Test("A step cancelled offers no file", arguments: Step.allCases)
    func cancelRow(_ step: Step) async throws {
        let data = try Self.threePages()
        let steps = Self.faulting(step, page: 1) {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        let task = Task {
            try await PageTextPath.$steps.withValue(steps) {
                try await TestPipeline.productionRun(data, mode: .searchableRedaction, regions: [0: [], 1: [], 2: []])
            }
        }
        switch await task.result {
        case .success(let run):
            try? FileManager.default.removeItem(at: run.url)
            Issue.record("\(step.rawValue): a cancelled run offered a file")
        case .failure(let error):
            #expect(error is CancellationError, "\(step.rawValue): \(error)")
        }
    }
}
