import Testing
import Foundation
import CoreGraphics
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// The information dictionary found through the file's own index.
//
// After the system writer closes the file, the producer rewrites three values
// of the information dictionary to fixed ones. It looks for the dictionary in
// two ways, in this order: through the file's index (the last `startxref`, the
// classic table, the trailer's `/Info` reference, that object's entry, the
// object at its offset), and, only where that way refuses, by the search of
// the file's last 262,144 bytes that it used before. The run records which way
// it was. The Document Metadata check judges the file, never the record: a
// field that is not the fixed value, or is missing, and an identifier that
// was not derived from the file read Needs review; a file without the
// dictionary or the identifier could not be verified.
//
// Every case prints one `INFODICT <case> ...` line to the run's log.

@Suite("The information dictionary is found through the file's own index", .serialized)
struct InfoDictionaryThroughIndexTests {

    // MARK: - The table

    struct Case: Sendable, CustomTestStringConvertible {
        let id: Int
        let title: String
        var testDescription: String { "case \(id): \(title)" }
    }

    static let cases: [Case] = [
        Case(id: 1, title: "exports of the fixture set, in both modes, are rewritten by the index and pass"),
        Case(id: 2, title: "a CJK Searchable export whose dictionary lies before the tail window is rewritten by the index"),
        Case(id: 3, title: "a 200-page export in each mode is rewritten by the index"),
        Case(id: 4, title: "a dictionary 300 KB before the end is rewritten; a look-alike in the tail is untouched"),
        Case(id: 5, title: "a literal ending in an escaped parenthesis next to the dictionary's end is rewritten whole"),
        Case(id: 6, title: "a cross-reference stream: the tail rewrites, the record names the refusal, the row passes"),
        Case(id: 7, title: "a cross-reference stream with the dictionary 300 KB before the end: neither way, Needs review"),
        Case(id: 8, title: "a dictionary holding /Producer twice: that field is left, Needs review"),
        Case(id: 9, title: "a trailer with no /Info: the output is what the tail search alone gives"),
        Case(id: 10, title: "an /Info entry marked free, and one of another generation: each output is the tail search's"),
        Case(id: 11, title: "an /Info entry whose offset lands inside a stream: the output is the tail search's"),
        Case(id: 12, title: "a file with no information dictionary could not be verified"),
        Case(id: 13, title: "a fixed field that is absent, and one that is a name, each read Needs review"),
        Case(id: 14, title: "a file with no identifier in its trailer could not be verified"),
        Case(id: 15, title: "an identifier of one string, and two strings that are not the recomputed one, each read Needs review"),
        Case(id: 16, title: "an I/O error before the index way reads the file: the tail search runs, and the record names the error"),
        Case(id: 17, title: "an I/O error at the index way's second write: the tail search runs, and the output is the tail search's"),
        Case(id: 18, title: "a dictionary the index names whose every literal declines: nothing is rewritten, the record says so, Needs review"),
        Case(id: 19, title: "a trailer with no pair in the writer's shape and one in the tail: located in the tail; a pair that cannot be located could not be verified"),
    ]

    @Test("The table holds nineteen cases")
    func tableLength() {
        #expect(Self.cases.count == 19)
        #expect(Set(Self.cases.map(\.id)) == Set(1...19))
    }

    @Test("Each case", arguments: InfoDictionaryThroughIndexTests.cases)
    func row(_ c: Case) async throws {
        switch c.id {
        case 1: try await Self.fixtureSetBothModes()
        case 2: try await Self.cjkSearchable()
        case 3: try await Self.twoHundredPages()
        case 4: try Self.dictionaryBeforeTheWindowWithLookAlike()
        case 5: try Self.escapedParenthesisAtTheEnd()
        case 6: try await Self.crossReferenceStreamInsideTheWindow()
        case 7: try await Self.crossReferenceStreamBeforeTheWindow()
        case 8: try await Self.producerTwice()
        case 9: try Self.sameAsTheTailSearch(MadeInfoFile(infoInTrailer: false), refusal: .noInfoEntry, label: "9")
        case 10:
            try Self.sameAsTheTailSearch(MadeInfoFile(infoEntry: .free), refusal: .entryNotInUse, label: "10 free")
            try Self.sameAsTheTailSearch(MadeInfoFile(infoEntry: .inUse(generation: 1)), refusal: .wrongObjectHeader,
                                         label: "10 generation")
        case 11: try Self.sameAsTheTailSearch(MadeInfoFile(infoEntry: .intoStream), refusal: .wrongObjectHeader, label: "11")
        case 12: try await Self.noDictionary()
        case 13: try await Self.fieldAbsentOrNotAString()
        case 14: try await Self.noIdentifier()
        case 15: try await Self.identifierNotDerived()
        case 16:
            try PDFStreamReconstructor.$indexWayFault.withValue(.read) {
                try Self.sameAsTheTailSearch(MadeInfoFile(), refusal: .readOrWriteFailed, label: "16")
            }
        case 17:
            try PDFStreamReconstructor.$indexWayFault.withValue(.secondWrite) {
                try Self.sameAsTheTailSearch(MadeInfoFile(), refusal: .readOrWriteFailed, label: "17")
            }
        case 18: try await Self.everyLiteralDeclines()
        case 19: try await Self.identifierInTheTail()
        default: Issue.record("no case \(c.id)")
        }
    }

    /// An index that cannot be read at all is refused with that reason, and
    /// the tail search still runs.
    enum Damage: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case noStartxref = "no startxref near the end"
        case offsetPastTheEnd = "a startxref offset past the end"
        case entriesDoNotParse = "a table entry that does not parse"
        case trailerNotClosed = "a trailer that does not close"
        var testDescription: String { rawValue }
    }

    @Test("An index that cannot be read is refused as unreadable, and the tail search runs",
          arguments: Damage.allCases)
    func unreadableIndex(_ damage: Damage) throws {
        try Self.sameAsTheTailSearch(MadeInfoFile(damage: damage), refusal: .indexUnreadable, label: "unreadable \(damage)")
    }

    // MARK: - Exports

    static let window = 262_144

    /// The fixture set: the text, CJK, PII, rotated and image-only pages.
    static func fixtureSet() -> [(String, Data)] {
        [("text", TestFixtures.textLayerPDF()),
         ("cjk", TestFixtures.cjkTextPDF()),
         ("pii", TestFixtures.documentWithPII(terms: ["Quillfeather", "555-12-3456"])),
         ("rotated", TestFixtures.rotatedTextPDF()),
         ("image-only", TestFixtures.imageOnlyPDF())]
    }

    static func fixtureSetBothModes() async throws {
        for (name, data) in fixtureSet() {
            for mode in [PipelineMode.secureRasterization, .searchableRedaction] {
                try await expectRewrittenByIndex(data, mode: mode, label: "1 \(name) \(mode)")
            }
        }
    }

    static func cjkSearchable() async throws {
        // Many distinct glyphs, so the embedded font of the Searchable
        // layer lies between the dictionary and the end of the file.
        let glyphs = (UInt32(0x4E00)..<UInt32(0x4E00 + 6_000)).compactMap { Unicode.Scalar($0).map(Character.init) }
        let lines = stride(from: 0, to: glyphs.count, by: 60).map { String(glyphs[$0..<min($0 + 60, glyphs.count)]) }
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { context in
            context.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7), .foregroundColor: UIColor.black]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 20, y: 20 + CGFloat(i) * 7.5), withAttributes: attrs)
            }
        }
        // Where the dictionary lies in this export depends on the runtime's
        // writer: the log line says how far before the end. A dictionary
        // before the tail window is made directly in case 4.
        try await expectRewrittenByIndex(data, mode: .searchableRedaction, label: "2")
    }

    static func twoHundredPages() async throws {
        let pageRect = CGRect(x: 0, y: 0, width: 300, height: 400)
        let data = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { context in
            for page in 1...200 {
                context.beginPage()
                ("Page \(page) of the long document" as NSString).draw(
                    at: CGPoint(x: 20, y: 40),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.black])
            }
        }
        for mode in [PipelineMode.secureRasterization, .searchableRedaction] {
            try await expectRewrittenByIndex(data, mode: mode, dpi: 72, label: "3 \(mode)")
        }
    }

    /// Exports `data` through the production page loop and expects the
    /// record to name the index, the three fixed values and a passing row.
    /// Returns how far before the end the dictionary lies.
    @discardableResult
    static func expectRewrittenByIndex(_ data: Data, mode: PipelineMode, dpi: Int = 150,
                                       label: String) async throws -> Int {
        let run = try await TestPipeline.productionRun(data, mode: mode, regions: nil, dpi: dpi)
        defer { try? FileManager.default.removeItem(at: run.url) }
        let bytes = try Data(contentsOf: run.url)
        let way = run.outcome.produced.infoDictionary
        #expect(way == .byIndex, "\(label): the record says \(String(describing: way))")
        #expect(fields(bytes) == fixedFields, "\(label): \(fields(bytes))")
        // The writer's file holds one information dictionary: a second one
        // (whose values the index way would leave) is a stop for this beta.
        var producerKeys = 0, from = bytes.startIndex
        while let hit = bytes.range(of: Data("/Producer".utf8), in: from..<bytes.endIndex) {
            producerKeys += 1; from = hit.upperBound
        }
        #expect(producerKeys == 1, "\(label): \(producerKeys) /Producer keys in the file")
        var distance = -1
        if case .found(let found) = PDFTrailerLocator.locate(in: bytes) {
            distance = bytes.count - found.dictionary.lowerBound
        }
        let row = try await metadataRow(run.url)
        #expect(name(row.status) == "pass", "\(label): \(row.status)")
        print("INFODICT \(label) way=\(String(describing: way)) distance=\(distance) bytes=\(bytes.count) row=\(row.status)")
        return distance
    }

    // MARK: - Made files

    static func dictionaryBeforeTheWindowWithLookAlike() throws {
        let made = MadeInfoFile(padding: 300_000, lookAlike: true)
        let (before, offsets) = made.build()
        let url = try write(before)
        defer { try? FileManager.default.removeItem(at: url) }
        let way = PDFStreamReconstructor.overwriteInfoLiterals(at: url)
        let after = try Data(contentsOf: url)
        #expect(way == .byIndex, "\(way)")
        #expect(after.count == before.count)
        let trueDictionary = String(decoding: after[offsets[5]!..<offsets[6]!], as: UTF8.self)
        #expect(trueDictionary.contains("(\(PDFStreamReconstructor.fixedProducerValue))"), "\(trueDictionary)")
        #expect(!trueDictionary.contains(MadeInfoFile.date) && !trueDictionary.contains("Quartz"), "\(trueDictionary)")
        #expect(after[offsets[7]!...] == before[offsets[7]!...], "the look-alike in the tail is untouched")
        #expect(before.count - offsets[5]! > window)
        print("INFODICT 4 way=\(way) distance=\(before.count - offsets[5]!)")
    }

    static func escapedParenthesisAtTheEnd() throws {
        let value = "Quartz PDFContext \\)"
        let made = MadeInfoFile(dictionary: "<< /CreationDate (\(MadeInfoFile.date)) /ModDate (\(MadeInfoFile.date)) /Producer (\(value))>>")
        let (before, offsets) = made.build()
        let url = try write(before)
        defer { try? FileManager.default.removeItem(at: url) }
        let way = PDFStreamReconstructor.overwriteInfoLiterals(at: url)
        let after = try Data(contentsOf: url)
        #expect(way == .byIndex, "\(way)")
        let fixedDate = PDFStreamReconstructor.fixedDateValue
        let fixedProducer = PDFStreamReconstructor.fixedProducerValue
        let expected = "<< /CreationDate (\(fixedDate)) /ModDate (\(fixedDate)) /Producer (\(fixedProducer))"
            + String(repeating: " ", count: value.utf8.count - fixedProducer.utf8.count) + ">>"
        let dictionary = String(decoding: after[offsets[5]!...].prefix(expected.utf8.count + 12), as: UTF8.self)
        #expect(dictionary.contains(expected), "\(dictionary)")
        print("INFODICT 5 way=\(way)")
    }

    static func crossReferenceStreamInsideTheWindow() async throws {
        let (url, way) = try produce(MadeInfoFile(crossReferenceStream: true))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(way == .byTail(indexRefused: .crossReferenceStream), "\(way)")
        #expect(fields(try Data(contentsOf: url)) == fixedFields)
        let row = try await metadataRow(url)
        #expect(name(row.status) == "pass", "no issue: \(row.status)")
        print("INFODICT 6 way=\(way) row=\(row.status)")
    }

    static func crossReferenceStreamBeforeTheWindow() async throws {
        let (url, way) = try produce(MadeInfoFile(padding: 300_000, crossReferenceStream: true))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(way == .neither(indexRefused: .crossReferenceStream), "\(way)")
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data(MadeInfoFile.date.utf8)) != nil, "the real dates stay in the file")
        let row = try await metadataRow(url)
        expectNeedsReview(row, "Producer or timestamp fields were not rewritten to the fixed values", label: "7")
        print("INFODICT 7 way=\(way) row=\(row.status)")
    }

    static func producerTwice() async throws {
        let real = "Quartz PDFContext"
        let made = MadeInfoFile(dictionary: "<< /Producer (\(real)) /CreationDate (\(MadeInfoFile.date)) /ModDate (\(MadeInfoFile.date)) /Producer (\(real)) >>")
        let (url, way) = try produce(made)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(way == .byTail(indexRefused: .repeatedKey), "\(way)")
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(text.components(separatedBy: "/Producer (\(real))").count - 1 == 2, "neither way rewrites the producer")
        let row = try await metadataRow(url)
        expectNeedsReview(row, "Producer or timestamp fields were not rewritten to the fixed values", label: "8")
        print("INFODICT 8 way=\(way) row=\(row.status)")
    }

    /// The index refuses with `refusal`; the file's output is byte for byte
    /// what the tail search alone gives on it.
    static func sameAsTheTailSearch(_ made: MadeInfoFile, refusal: RunRecord.IndexRefusal, label: String) throws {
        let (before, _) = made.build()
        let url = try write(before)
        let tailOnly = try write(before)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: tailOnly)
        }
        let way = PDFStreamReconstructor.overwriteInfoLiterals(at: url)
        let tailRewrote = PDFStreamReconstructor.overwriteInfoLiteralsInTail(at: tailOnly)
        #expect(tailRewrote, "\(label): the tail search rewrites this file")
        #expect(way == .byTail(indexRefused: refusal), "\(label): \(way)")
        #expect(try Data(contentsOf: url) == Data(contentsOf: tailOnly), "\(label): the output is the tail search's")
        #expect(try Data(contentsOf: url) != before, "\(label): the file was rewritten")
        print("INFODICT \(label) way=\(way)")
    }

    // MARK: - The check's four rows

    static func noDictionary() async throws {
        let (url, way) = try produce(MadeInfoFile(dictionary: nil, infoInTrailer: false))
        defer { try? FileManager.default.removeItem(at: url) }
        let row = try await metadataRow(url)
        expectCouldNotVerify(row, label: "12")
        print("INFODICT 12 way=\(way) row=\(row.status) mark=\(row.couldNotVerify)")
    }

    static func fieldAbsentOrNotAString() async throws {
        let fixed = PDFStreamReconstructor.fixedDateValue
        for (label, dictionary) in [
            ("13 absent", "<< /Producer (Quartz PDFContext) /CreationDate (\(MadeInfoFile.date)) >>"),
            ("13 name", "<< /Producer (Quartz PDFContext) /CreationDate (\(MadeInfoFile.date)) /ModDate /D\(fixed.dropFirst(2).prefix(14)) >>"),
        ] {
            let (url, way) = try produce(MadeInfoFile(dictionary: dictionary))
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(way == .byIndex, "\(label): \(way)")
            let row = try await metadataRow(url)
            expectNeedsReview(row, "Producer or timestamp fields were not rewritten to the fixed values", label: label)
            print("INFODICT \(label) way=\(way) row=\(row.status)")
        }
    }

    static func noIdentifier() async throws {
        let (url, way) = try produce(MadeInfoFile(id: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(way == .byIndex, "\(way)")
        let row = try await metadataRow(url)
        expectCouldNotVerify(row, label: "14")
        print("INFODICT 14 way=\(way) row=\(row.status) mark=\(row.couldNotVerify)")
    }

    static func identifierNotDerived() async throws {
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
        for (label, id, rewriteIdentifier) in [("15 one string", "[<\(a)>]", true),
                                               ("15 not recomputed", "[<\(a)> <\(b)>]", false)] {
            let made = MadeInfoFile(id: id)
            let url = try write(made.build().data)
            defer { try? FileManager.default.removeItem(at: url) }
            let way = PDFStreamReconstructor.overwriteInfoLiterals(at: url)
            if rewriteIdentifier { PDFStreamReconstructor.overwriteFileIdentifier(at: url) }
            let row = try await metadataRow(url)
            expectNeedsReview(row, "File identifier was not derived from the file contents", label: label)
            print("INFODICT \(label) way=\(way) row=\(row.status)")
        }
    }

    // MARK: - No file fares worse than before

    static func everyLiteralDeclines() async throws {
        let made = MadeInfoFile(dictionary: "<< /Producer (short) /CreationDate (D:2026) /ModDate (D:2026) >>")
        let (before, _) = made.build()
        let url = try write(before)
        let tailOnly = try write(before)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: tailOnly)
        }
        let way = PDFStreamReconstructor.overwriteInfoLiterals(at: url)
        #expect(way == .byIndexNothingRewritten, "18: \(way)")
        #expect(try Data(contentsOf: url) == before, "18: nothing was rewritten")
        #expect(!PDFStreamReconstructor.overwriteInfoLiteralsInTail(at: tailOnly), "18: the tail search declines the same literals")
        PDFStreamReconstructor.overwriteFileIdentifier(at: url)
        let row = try await metadataRow(url)
        expectNeedsReview(row, "Producer or timestamp fields were not rewritten to the fixed values", label: "18")
        print("INFODICT 18 way=\(way) row=\(row.status)")
    }

    static func identifierInTheTail() async throws {
        // The trailer the index names holds no pair; the information
        // dictionary, in the tail, holds the one pair in the writer's shape.
        let zeros = String(repeating: "0", count: 32)
        let made = MadeInfoFile(dictionary: "<< /Producer (\(MadeInfoFile.producer)) /CreationDate (\(MadeInfoFile.date)) /ModDate (\(MadeInfoFile.date)) /ID [<\(zeros)> <\(zeros)>] >>", id: nil)
        let data = made.build().data
        let tail = data[max(data.startIndex, data.endIndex - PDFFileIdentifier.tailWindowLength)...]
        let inTail = try #require(PDFFileIdentifier.locate(in: tail), "19: the tail holds one pair")
        #expect(PDFFileIdentifier.location(in: data) == inTail, "19: located in the tail, as before the index was read")
        // Two literal strings of the identifier's length: the check reads a
        // pair, but no pair in the writer's shape is located anywhere.
        let literal = String(repeating: "a", count: 16)
        let (url, way) = try produce(MadeInfoFile(id: "[(\(literal)) (\(literal))]"))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PDFFileIdentifier.recomputedIdentifier(for: try Data(contentsOf: url)) == nil, "19: nothing to recompute from")
        let row = try await metadataRow(url)
        expectCouldNotVerify(row, label: "19 literal pair")
        print("INFODICT 19 way=\(way) row=\(row.status)")
    }

    // MARK: - Support

    static let fixedFields = [
        "Producer": PDFStreamReconstructor.fixedProducerValue,
        "CreationDate": PDFStreamReconstructor.fixedDateValue,
        "ModDate": PDFStreamReconstructor.fixedDateValue,
    ]

    /// The three fields as the system reader gives them.
    static func fields(_ data: Data) -> [String: String] {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider),
              let info = doc.info else { return [:] }
        var out: [String: String] = [:]
        for key in ["Producer", "CreationDate", "ModDate"] {
            var ref: CGPDFStringRef?
            if CGPDFDictionaryGetString(info, key, &ref), let ref, let text = CGPDFStringCopyTextString(ref) {
                var value = text as String
                while value.hasSuffix(" ") { value.removeLast() }
                out[key] = value
            }
        }
        return out
    }

    static func metadataRow(_ url: URL) async throws -> LayerResult {
        let doc = try #require(PDFDocument(url: url), "PDFKit opens \(url.lastPathComponent)")
        let modes = Array(repeating: PipelineMode.secureRasterization, count: doc.pageCount)
        return await VerificationEngine().runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: doc.pageCount, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization, filterDigests: [], perPageModes: modes)
    }

    static func name(_ status: VerificationStatus) -> String {
        switch status {
        case .pass: "pass"
        case .warn: "warn"
        case .info: "info"
        case .attention: "attention"
        case .fail: "fail"
        case .skipped: "skipped"
        case .notApplicable: "notApplicable"
        }
    }

    static func expectNeedsReview(_ row: LayerResult, _ message: String, label: String) {
        guard case .attention(let got) = row.status else {
            Issue.record("\(label): Needs review expected, got \(row.status)")
            return
        }
        #expect(got == message, "\(label)")
        #expect(row.couldNotVerify == false, "\(label)")
    }

    static func expectCouldNotVerify(_ row: LayerResult, label: String) {
        guard case .warn(let got) = row.status else {
            Issue.record("\(label): could not verify expected, got \(row.status)")
            return
        }
        #expect(got == "Could not inspect metadata", "\(label)")
        #expect(row.couldNotVerify, "\(label): the could-not-verify mark")
    }

    static func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("info_index_\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    /// The made file through the producer's two rewrites, as `finalize`
    /// runs them, with the way the first one reports.
    static func produce(_ made: MadeInfoFile) throws -> (URL, RunRecord.InfoDictionaryWay) {
        let url = try write(made.build().data)
        let way = PDFStreamReconstructor.overwriteInfoLiterals(at: url)
        PDFStreamReconstructor.overwriteFileIdentifier(at: url)
        return (url, way)
    }
}

/// A one-page file in the system writer's shape, its index's offsets right:
/// catalog 1, pages 2, page 3, contents 4, the information dictionary 5, a
/// stream 6 that can push 5 away from the end, a look-alike dictionary 7,
/// and, for a cross-reference stream, the stream 8.
struct MadeInfoFile {
    enum Entry: Equatable { case inUse(generation: Int), free, intoStream }

    static let producer = "iOS Version 27.2 \\(Build 24B8117\\) Quartz PDFContext"
    static let date = "D:20261031185415Z00'00'"
    static let zeroPair = "[<\(String(repeating: "0", count: 32))> <\(String(repeating: "0", count: 32))>]"

    var dictionary: String? = "<< /Producer (\(MadeInfoFile.producer)) /CreationDate (\(MadeInfoFile.date)) /ModDate (\(MadeInfoFile.date)) >>"
    var infoInTrailer = true
    var padding = 16
    var lookAlike = false
    var crossReferenceStream = false
    var infoEntry: Entry = .inUse(generation: 0)
    var id: String? = MadeInfoFile.zeroPair
    var damage: InfoDictionaryThroughIndexTests.Damage? = nil

    func build() -> (data: Data, offsets: [Int: Int]) {
        var out = Data((crossReferenceStream ? "%PDF-1.5\n" : "%PDF-1.3\n").utf8)
        var offsets: [Int: Int] = [:]
        func add(_ n: Int, _ body: String) {
            offsets[n] = out.count
            out.append(Data("\(n) 0 obj\n\(body)\nendobj\n".utf8))
        }
        add(1, "<< /Type /Catalog /Pages 2 0 R >>")
        add(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << >> >>")
        add(4, "<< /Length 3 >>\nstream\nq Q\nendstream")
        if let dictionary { add(5, dictionary) }
        let pad = String(repeating: "x", count: max(padding, 16))
        let streamHead = "6 0 obj\n<< /Length \(pad.count) >>\nstream\n"
        add(6, "<< /Length \(pad.count) >>\nstream\n\(pad)\nendstream")
        if lookAlike {
            add(7, "<< /Producer (Look-alike Producer Value) /CreationDate (\(MadeInfoFile.date)) /ModDate (\(MadeInfoFile.date)) >>")
        }
        let trailerKeys = (infoInTrailer ? " /Info 5 0 R" : "") + (id.map { " /ID \($0)" } ?? "")
        let xrefOffset = out.count
        if crossReferenceStream {
            var rows = Data()
            func row(_ type: UInt8, _ field: Int, _ gen: Int) {
                rows.append(type)
                rows.append(contentsOf: withUnsafeBytes(of: UInt32(field).bigEndian, Array.init))
                rows.append(contentsOf: withUnsafeBytes(of: UInt16(gen).bigEndian, Array.init))
            }
            for n in 0..<9 {
                if n == 8 { row(1, xrefOffset, 0) } else if let o = offsets[n] { row(1, o, 0) } else { row(0, 0, n == 0 ? 65535 : 0) }
            }
            out.append(Data("8 0 obj\n<< /Type /XRef /Size 9 /W [1 4 2] /Root 1 0 R\(trailerKeys) /Length \(rows.count) >>\nstream\n".utf8))
            out.append(rows)
            out.append(Data("\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
            return (out, offsets)
        }
        let size = (offsets.keys.max() ?? 0) + 1
        var table = "xref\n0 \(size)\n"
        for n in 0..<size {
            guard let o = offsets[n] else { table += "0000000000 65535 f\r\n"; continue }
            if n == 5 {
                switch infoEntry {
                case .inUse(let g): table += String(format: "%010d %05d n\r\n", o, g)
                case .free: table += String(format: "%010d %05d f\r\n", o, 0)
                case .intoStream: table += String(format: "%010d %05d n\r\n", offsets[6]! + streamHead.utf8.count + 4, 0)
                }
            } else if n == 1 && damage == .entriesDoNotParse {
                table += String(format: "%010d %05d x\r\n", o, 0)
            } else {
                table += String(format: "%010d %05d n\r\n", o, 0)
            }
        }
        let close = damage == .trailerNotClosed ? "" : " >>"
        let startxref = damage == .noStartxref ? "startXref" : "startxref"
        var tail = table + "trailer\n<< /Size \(size) /Root 1 0 R\(trailerKeys)\(close)\n\(startxref)\n"
        let offsetLine = damage == .offsetPastTheEnd ? "\(out.count + tail.utf8.count + 100_000)" : "\(xrefOffset)"
        tail += offsetLine + "\n%%EOF\n"
        out.append(Data(tail.utf8))
        return (out, offsets)
    }
}
