import Testing
import Foundation
import CoreGraphics
import CryptoKit
import PDFKit
@testable import RedactionEngine

// The run's record as the product makes it. The writer records the SHA-256
// of each page's picture as it hands the picture to the draw, and the box
// check locates each page's picture by that digest. Through the production page
// loop, with the record's confirmed part built as the run entry builds it, a
// run whose boxes are painted reads Box Fill Passed; the same record without
// the digests reads Could not verify on every page.

@Suite("Box Fill on a run's own record", .serialized)
struct BoxFillOwnRecordTests {

    struct Run {
        let file: Data
        let document: PDFDocument
        let record: RunRecord
    }

    /// One box on each page of `sources`, the record's confirmed part as the
    /// run entry builds it (each region as drawn, the page's crop box and
    /// turn), then every page through the production page loop.
    static func run(_ sources: [PageDrawingFixtures.Source]) async throws -> Run {
        let source = try #require(PDFDocument(data: PageDrawingFixtures.sourcePDF(sources)))
        var pages: [PDFPageData] = []
        var confirmed: [RunRecord.Page] = []
        for i in 0..<source.pageCount {
            let page = try #require(source.page(at: i))
            let region = RedactionRegion(
                id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05), source: .manual)
            let recorded = RunRecord.Page(
                pageIndex: i, regions: [RunRecord.DrawnRegion(id: region.id, normalizedRect: region.normalizedRect)],
                cropBox: page.bounds(for: .cropBox).size, rotation: page.rotation, switchOn: false)
            confirmed.append(recorded)
            pages.append(PDFPageData(
                page: page, pageIndex: i, regions: [region], fillColor: .black, targetDPI: 300,
                pipelineMode: .secureRasterization, rotation: page.rotation,
                cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef,
                hasText: !(page.string ?? "").isEmpty, confirmedPage: recorded))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("own-record-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try await ProductionPageLoop.runRedaction(pages: pages, outputURL: url)
        let file = try Data(contentsOf: url)
        let record = RunRecord(
            confirmed: .init(fillColor: .black, exportDPI: 300, pages: confirmed), produced: outcome.produced)
        return Run(file: file, document: try #require(PDFDocument(data: file)), record: record)
    }

    static let sources: [PageDrawingFixtures.Source] = [
        .text(PageDrawingFixtures.letter, PageDrawingFixtures.typed),
        .scan(PageDrawingFixtures.a4, gray: false),
        .text(PageDrawingFixtures.letter, PageDrawingFixtures.typed),
    ]

    @Test("Each page's digest is the SHA-256 of the picture the file stores for that page, one per page")
    func digestIsOfTheStoredPicture() async throws {
        let run = try await Self.run(Self.sources)
        let digests = run.record.produced.pageImageDigests
        #expect(digests.keys.sorted() == Array(0..<Self.sources.count))
        let stored = try #require(SystemPageImageSource(fileData: run.file))
        for index in 0..<Self.sources.count {
            let picture = try #require(try? stored.images(onPage: index).get().first, "page \(index + 1)")
            #expect(digests[index] == Data(SHA256.hash(data: picture.bytes)), "page \(index + 1)")
        }
    }

    @Test("A run with its own record reads Box Fill Passed; the same record without the digests, Could not verify on every page")
    func ownRecordPasses() async throws {
        let run = try await Self.run(Self.sources)
        let engine = VerificationEngine()
        func boxFill(_ record: RunRecord) async -> LayerResult {
            await engine.runLayer(.boxFill, outputDocument: SendablePDFDocument(run.document),
                                  sourcePageCount: Self.sources.count, regions: [:], sensitiveTerms: [],
                                  pipelineMode: .secureRasterization,
                                  filterDigests: Array(repeating: nil, count: Self.sources.count),
                                  perPageModes: Array(repeating: .secureRasterization, count: Self.sources.count),
                                  record: record)
        }
        let own = await boxFill(run.record)
        #expect(own.status == .pass, "\(own.status): \(own.shortDescription)")
        #expect(own.couldNotVerify == false)

        var withoutDigests = run.record.produced
        withoutDigests.pageImageDigests = [:]
        let unread = await boxFill(RunRecord(confirmed: run.record.confirmed, produced: withoutDigests))
        #expect(unread.status == .warn(""))
        #expect(unread.couldNotVerify)
        #expect(unread.shortDescription == "3 pages could not be read for this check: 1, 2, 3")
    }
}
