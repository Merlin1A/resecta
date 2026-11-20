import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// The finished file read back before it is kept (`MetaReadBack`): the fixed
// values, the identifier derived from the file, and none of the writer's own
// values left in its bytes. The rules are run on made files whose writer
// values are known, then through the production page loop, which refuses to
// keep a file whose read-back did not hold.

@Suite("The finished file is read back before it is kept", .serialized)
struct MetaReadBackTests {

    // MARK: - A made file with known writer values

    static let writerProducer = #"Fake Writer 9.9 \(Build 1A1\) Quartz PDFContext"#
    static let writerDate = "D:20261120142541Z00'00'"
    static let writerID = "0123456789abcdef0123456789abcdef"

    static func madeFile(pageContent: String = "BT /F1 24 Tf 72 700 Td (Hello) Tj ET") -> Data {
        CheckStopTests.pdf(
            [CheckStopTests.Page(content: pageContent)],
            info: "/CreationDate (\(writerDate)) /Producer (\(writerProducer)) /ModDate (\(writerDate))",
            trailer: "/ID [ <\(writerID)> <\(writerID)> ]")
    }

    static func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("readback_\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    /// Writes `bytes` over the file at `offset`, the length unchanged.
    static func overwrite(_ url: URL, at offset: Int, with bytes: Data) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: bytes)
    }

    static func offset(of text: String, in url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let hit = try #require(data.range(of: Data(text.utf8)), "\(text) in the file")
        return hit.lowerBound - data.startIndex
    }

    /// The made file, its originals read, then the rewrites that `steps` names.
    static func made(infoRewrite: Bool = true, identifierRewrite: Bool = true,
                     pageContent: String = "BT /F1 24 Tf 72 700 Td (Hello) Tj ET",
                     between: (URL) throws -> Void = { _ in }) throws -> (URL, MetaReadBack.Originals) {
        let url = try write(madeFile(pageContent: pageContent))
        let originals = MetaReadBack.originals(of: url)
        if infoRewrite { PDFStreamReconstructor.overwriteInfoLiterals(at: url) }
        try between(url)
        if identifierRewrite { PDFStreamReconstructor.overwriteFileIdentifier(at: url) }
        return (url, originals)
    }

    // MARK: - The rules on made files

    @Test("A made file with every value replaced holds")
    func madeFileHolds() throws {
        let (url, originals) = try Self.made()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MetaReadBack.check(url: url, originals: originals) == .held)
    }

    @Test("The writer's values left as written: the values are not the fixed ones")
    func infoNotRewrittenStops() throws {
        let (url, originals) = try Self.made(infoRewrite: false)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MetaReadBack.check(url: url, originals: originals) == .valuesNotFixed)
    }

    @Test("One date written back as the writer wrote it: the values are not the fixed ones")
    func oneDateLeftStops() throws {
        let (url, originals) = try Self.made(between: { url in
            let at = try Self.offset(of: "/ModDate (", in: url) + "/ModDate (".utf8.count
            try Self.overwrite(url, at: at, with: Data(Self.writerDate.utf8))
        })
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MetaReadBack.check(url: url, originals: originals) == .valuesNotFixed)
    }

    @Test("The identifier left as the writer wrote it: not derived from the file")
    func identifierNotRewrittenStops() throws {
        let (url, originals) = try Self.made(identifierRewrite: false)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MetaReadBack.check(url: url, originals: originals) == .identifierNotDerived)
    }

    @Test("The rest of an old producer beside the fixed one: the file is not kept, and the rule reads it")
    func oldBytesAfterTheLiteralStop() throws {
        let (url, originals) = try Self.made(between: { url in
            let at = try Self.offset(of: "(Resecta)", in: url) + "(Resecta)".utf8.count
            try Self.overwrite(url, at: at, with: Data("Quartz".utf8))
        })
        defer { try? FileManager.default.removeItem(at: url) }
        // The system reader may then read the dictionary or give it up; either
        // way the file is not kept.
        #expect(MetaReadBack.check(url: url, originals: originals) != .held)
        let bytes = try Data(contentsOf: url)
        #expect(!MetaReadBack.onlySpaceAfter(key: "Producer", value: PDFStreamReconstructor.fixedProducerValue, in: bytes))
        let clean = Data("<< /Producer (Resecta)      /ModDate (x) >>".utf8)
        #expect(MetaReadBack.onlySpaceAfter(key: "Producer", value: "Resecta", in: clean))
        let left = Data("<< /Producer (Resecta)   Quartz PDFContext) /ModDate (x) >>".utf8)
        #expect(!MetaReadBack.onlySpaceAfter(key: "Producer", value: "Resecta", in: left))
        let absent = Data("<< /Producer (Other) >>".utf8)
        #expect(!MetaReadBack.onlySpaceAfter(key: "Producer", value: "Resecta", in: absent))
    }

    @Test("A whole writer value elsewhere in the file: a writer value is left")
    func originalElsewhereStops() throws {
        let (url, originals) = try Self.made(
            pageContent: "BT /F1 12 Tf 72 700 Td (\(Self.writerProducer)) Tj ET")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MetaReadBack.check(url: url, originals: originals) == .originalLeft)
    }

    @Test("The writer's identifier in hex elsewhere in the file: a writer value is left")
    func originalIdentifierElsewhereStops() throws {
        let (url, originals) = try Self.made(
            pageContent: "BT /F1 12 Tf 72 700 Td (\(Self.writerID.uppercased())) Tj ET")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MetaReadBack.check(url: url, originals: originals) == .originalLeft)
    }

    @Test("A file that cannot be read, or originals not read whole, never holds")
    func unreadableStops() throws {
        let (url, originals) = try Self.made()
        #expect(MetaReadBack.check(url: url, originals: .none) == .unreadable)
        try FileManager.default.removeItem(at: url)
        #expect(MetaReadBack.check(url: url, originals: originals) == .unreadable)
    }

    @Test("The writer's five strings are read whole from a made file")
    func originalsReadWhole() throws {
        let url = try Self.write(Self.madeFile())
        defer { try? FileManager.default.removeItem(at: url) }
        // Read whole, the originals let the rules run: an unchanged file reads
        // as values not fixed, never as unreadable.
        #expect(MetaReadBack.check(url: url, originals: MetaReadBack.originals(of: url)) == .valuesNotFixed)
        let noIdentifier = try Self.write(CheckStopTests.pdf(
            [CheckStopTests.Page(content: "BT /F1 24 Tf 72 700 Td (Hello) Tj ET")],
            info: "/CreationDate (\(Self.writerDate)) /Producer (\(Self.writerProducer)) /ModDate (\(Self.writerDate))"))
        defer { try? FileManager.default.removeItem(at: noIdentifier) }
        #expect(MetaReadBack.check(url: noIdentifier, originals: MetaReadBack.originals(of: noIdentifier)) == .unreadable)
    }

    // MARK: - Through the production page loop

    static func textPages(_ count: Int) -> Data {
        CheckStopTests.pdf((1...count).map {
            CheckStopTests.Page(content: "BT /F1 18 Tf 72 700 Td (Page \($0) of the long document) Tj ET")
        })
    }

    static func expectHeld(_ data: Data, mode: PipelineMode, dpi: Int = 150, label: String) async throws {
        let run = try await TestPipeline.productionRun(data, mode: mode, regions: nil, dpi: dpi)
        defer { try? FileManager.default.removeItem(at: run.url) }
        #expect(run.outcome.produced.metaReadBack == .held, "\(label): \(String(describing: run.outcome.produced.metaReadBack))")
        #expect(FileManager.default.fileExists(atPath: run.url.path), "\(label): kept")
    }

    @Test("A Searchable Redaction export is kept, its read-back held")
    func searchablePasses() async throws {
        try await Self.expectHeld(Self.textPages(3), mode: .searchableRedaction, label: "searchable")
    }

    @Test("A Secure Rasterization export is kept, its read-back held")
    func securePasses() async throws {
        try await Self.expectHeld(Self.textPages(1), mode: .secureRasterization, label: "secure")
    }

    @Test("A 200-page export in each mode is kept, its read-back held")
    func twoHundredPages() async throws {
        for mode in [PipelineMode.secureRasterization, .searchableRedaction] {
            try await Self.expectHeld(Self.textPages(200), mode: mode, dpi: 72, label: "200 \(mode)")
        }
    }

    @Test("Values left as the writer wrote them stop the export before it is kept")
    func loopStopsOnValues() async throws {
        await #expect(throws: PipelineError.self) {
            try await PDFStreamReconstructor.$finalizeSkipsFixedValues.withValue(true) {
                _ = try await TestPipeline.productionRun(Self.textPages(1), mode: .secureRasterization, regions: nil)
            }
        }
    }

    @Test("An identifier left as the writer wrote it stops the export before it is kept")
    func loopStopsOnIdentifier() async throws {
        await #expect(throws: PipelineError.self) {
            try await PDFStreamReconstructor.$finalizeSkipsIdentifier.withValue(true) {
                _ = try await TestPipeline.productionRun(Self.textPages(1), mode: .secureRasterization, regions: nil)
            }
        }
    }

    @Test("A large Chinese Searchable export, its dictionary past the old window, is kept with its read-back held")
    func largeCJKSearchable() async throws {
        let glyphs = (UInt32(0x4E00)..<UInt32(0x4E00 + 6_000)).compactMap { Unicode.Scalar($0).map(Character.init) }
        let lines = stride(from: 0, to: glyphs.count, by: 60).map { String(glyphs[$0..<min($0 + 60, glyphs.count)]) }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7), .foregroundColor: UIColor.black]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 20, y: 20 + CGFloat(i) * 7.5), withAttributes: attrs)
            }
        }
        let run = try await TestPipeline.productionRun(data, mode: .searchableRedaction, regions: nil)
        defer { try? FileManager.default.removeItem(at: run.url) }
        let bytes = try Data(contentsOf: run.url)
        var distance = -1
        if case .found(let found) = PDFTrailerLocator.locate(in: bytes) { distance = bytes.count - found.dictionary.lowerBound }
        print("READBACK cjk bytes=\(bytes.count) infoFromEnd=\(distance) past256KiB=\(distance > 262_144)")
        #expect(run.outcome.produced.metaReadBack == .held)
    }

    // MARK: - The writer's values stay in memory

    @Test("The writer's values are never logged, printed or recorded")
    func originalsNeverLeaveMemory() throws {
        let here = URL(fileURLWithPath: #filePath)
        let source = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/RedactionEngine/Pipeline/MetaReadBack.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for word in ["Logger", "logger", "print(", "os_log", "CustomStringConvertible", "CustomDebugStringConvertible"] {
            #expect(!text.contains(word), "MetaReadBack.swift holds \(word)")
        }
        #expect(text.contains("fileprivate let needles"))
    }
}
