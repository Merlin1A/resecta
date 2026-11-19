import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// A check that could not read a page, a value or a result never reads as
// passed, and what it could not read stays in its row: alone, as a warning
// that could not verify, with the pages it could not read; beside an issue,
// as the row's could-not-verify part, the issue itself unchanged. A
// warning that is joined follows the could-not-verify sentences; one that
// stands alone keeps its own row, mark clear. One table; its length is
// pinned so an empty table fails. Each hand-built file first asserts the
// state it stands for, so a reader that repairs the file fails loudly.

@Suite("A page or a value a check could not read never reads as passed", .serialized)
struct CouldNotReadRowTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let body: @Sendable () async throws -> Void
        var testDescription: String { name }
    }

    typealias S = CouldNotReadRowTests

    static let cases: [Case] = [
        // Alone: the could-not-verify sentence is the row.
        Case(name: "OCR of Page Images: a recognition pass that returns no result object is a page not run", body: { try await S.recognitionWithoutResults() }),
        Case(name: "Hidden Words Under Boxes: a recognition pass that returns no result object is a page not checked", body: { try await S.hiddenWordsWithoutResults() }),
        Case(name: "Terms in Text & Bytes: a page that does not open is a page not read", body: { try await S.termsUnopenedPage() }),
        Case(name: "Terms in Text & Bytes: a page the file reader counts and cannot open is a page not read", body: { try await S.termsUnreadableCGPage() }),
        Case(name: "Active Content & Structure: a page whose dictionary cannot be read is a page not read", body: { try await S.structureUnreadablePage() }),
        Case(name: "Active Content & Structure: a file with no end marker could not be inspected", body: { try await S.structureNoEndMarker() }),
        Case(name: "Active Content & Structure: no end marker, then the structural findings", body: { try await S.structureNoEndMarkerAndFindings() }),
        Case(name: "Active Content & Structure: a page not read, then the structural findings", body: { try await S.structureUnreadablePageAndFindings() }),
        Case(name: "Character Positions: a page declared image-only that does not open is a page not read", body: { try await S.positionsSecurePageUnopened() }),
        Case(name: "Character Positions: a page not read leads an edge graze, which is not the row", body: { try await S.positionsUnopenedBeatsGraze() }),
        Case(name: "OCR of Page Images: coordinates not mapped, then the in-region text", body: { try S.ocrUnmappedThenInRegion() }),
        Case(name: "OCR of Page Images: a page not run, then the in-region text", body: { try S.ocrUnrunThenInRegion() }),
        Case(name: "Terms in Text & Bytes: a term too short, then the fragment line", body: { try await S.termsShortThenFragment() }),
        Case(name: "Terms in Text & Bytes: a term too short, then the picture data line", body: { try await S.termsShortThenEXIF() }),
        Case(name: "Terms in Text & Bytes: a page not read, then the fragment line", body: { try await S.termsUnreadThenFragment() }),
        Case(name: "Terms in Text & Bytes: a page not read, a term too short, then the fragment line", body: { try await S.termsUnreadShortThenFragment() }),
        Case(name: "Terms in Text & Bytes: a page not read, then the picture data line", body: { try await S.termsUnreadThenEXIF() }),
        Case(name: "Terms in Text & Bytes and Document Metadata: a file that cannot be read is never read from a rewritten copy", body: { try await S.deletedFileTermsAndMetadata() }),
        Case(name: "Active Content & Structure: a file that cannot be read is never read from a rewritten copy", body: { try await S.deletedFileStructure() }),
        Case(name: "Document Metadata: a fixed field that does not decode could not be inspected", body: { try await S.metadataUndecodable() }),
        Case(name: "Document Metadata: a field that does not decode, then a field not rewritten", body: { try await S.metadataUndecodableAndNotRewritten() }),
        Case(name: "Character Sequence: a digest with no lineage record is a page not compared", body: { try await S.sequenceEmptyRecord() }),
        Case(name: "Terms in Content Streams: a text operator with no operand is a page not read", body: { try await S.contentStreamsMissingOperand() }),
        Case(name: "Terms in Content Streams: an operand that does not decode is a page not read", body: { try await S.contentStreamsUndecodableOperand() }),
        Case(name: "Search Re-check: an applied scan and an applied search that compared nothing say so, the scan's first", body: { try await S.recheckComparedNothingBoth() }),
        Case(name: "Search Re-check: an applied search that compared nothing says so", body: { try await S.recheckComparedNothingSearch() }),
        // Pins: what the change relies on and what it leaves alone.
        Case(name: "pin: a page whose text read returns nothing fails the count, while the other checks pass", body: { try await S.pinTextReadNothing(empty: false) }),
        Case(name: "pin: a page whose text read is empty fails the count, while the other checks pass", body: { try await S.pinTextReadNothing(empty: true) }),
        Case(name: "pin: the in-region text warning alone keeps its row, mark clear", body: { try S.pinInRegionAlone() }),
        Case(name: "pin: the fragment line alone keeps its row, mark clear", body: { try await S.pinFragmentAlone() }),
        Case(name: "pin: the picture data line alone keeps its row, mark clear", body: { try await S.pinEXIFAlone() }),
        Case(name: "pin: a term too short alone keeps its row, mark set", body: { try await S.pinShortTermAlone() }),
        // An issue, and something the same check could not read beside it.
        Case(name: "Text & Annotations: an annotation, and a page that does not open", body: { try await S.findAnnotationsUnopened() }),
        Case(name: "Text & Annotations: selectable text and an annotation are both in the row", body: { try await S.findTextAndAnnotations() }),
        Case(name: "OCR of Page Images: a term inside a region, and a page not run", body: { try S.findOCRUnrun() }),
        Case(name: "OCR of Page Images: a term inside a region, a page not run, and the in-region text", body: { try S.findOCRUnrunAndInRegion() }),
        Case(name: "Terms in Text & Bytes: a readable term, and a page that does not open", body: { try await S.findTermUnopened() }),
        Case(name: "Terms in Text & Bytes: a readable term, and a term too short", body: { try await S.findTermShort() }),
        Case(name: "Active Content & Structure: a page action, and a page whose dictionary cannot be read", body: { try await S.findPageActionUnreadable() }),
        Case(name: "Character Positions: a character inside a region, and a page that does not open", body: { try await S.findPositionUnopened() }),
        Case(name: "Character Count: a deficit, and a page with no record", body: { try await S.findCountNoRecord() }),
        Case(name: "Monospace Fonts: another font, and a page that does not open", body: { try await S.findFontUnopened() }),
        Case(name: "Character Sequence: a mismatch, and a page with no record", body: { try await S.findSequenceNoRecord() }),
        Case(name: "Terms in Content Streams: a term, and an earlier page with an operand not read", body: { try await S.findContentStreamsUnread() }),
        Case(name: "Hidden Words Under Boxes: a flagged word, and a page not matched", body: { try S.findHiddenWordsUnmatched() }),
        Case(name: "Search Re-check: a match remains, and a page that does not open", body: { try S.findRecheckRemainsUnopened() }),
        Case(name: "Search Re-check: a match only partly covered, and a page that does not open", body: { try S.findRecheckShortfallUnopened() }),
        Case(name: "Detection Sweep: an item in the scan's categories remains, and a page that does not open", body: { try S.findSweepRemainsUnopened() }),
        // More than one could-not-verify condition, and the page lists.
        Case(name: "OCR of Page Images: coordinates not mapped, a page not run, then the in-region text", body: { try S.ocrBothConditions() }),
        Case(name: "Text & Annotations: no file to read form fields from, and a page that does not open", body: { try await S.annotationsNoURLUnopened() }),
        Case(name: "Character Positions: no measurable position, a page that does not open, and a graze left out", body: { try await S.positionsUnmeasuredUnopenedGraze() }),
        Case(name: "Character Count: a page with no record, then the excess", body: { try await S.countNoRecordThenExcess() }),
        Case(name: "Monospace Fonts: a page that does not open, then a page with no resources", body: { try await S.fontsUnopenedThenNoResources() }),
        Case(name: "Detection Sweep: possible items only, and a page that does not open", body: { try S.sweepPossibleOnlyUnopened() }),
    ]

    @Test("The table holds exactly fifty-four cases")
    func tableLength() {
        #expect(Self.cases.count == 54)
    }

    @Test("Each case", arguments: cases)
    func eachCase(_ c: Case) async throws {
        try await c.body()
    }

    // MARK: - Alone

    static func recognitionWithoutResults() async throws {
        let doc = try open(rawPDF([RawPage(content: text("Statement"))]))
        defer { remove(doc) }
        let r = await VerificationEngine.$onRecognitionSimulateNoResults.withValue({ _ in true }) {
            await run(.ocrCheck, doc, mode: .secureRasterization)
        }
        expectWarn(r, "OCR could not be run on 1 page", mark: true, pages: [0])
    }

    static func hiddenWordsWithoutResults() async throws {
        let data = HiddenWordInkFixtures.seededPage(drift: 30)
        let output = try #require(PDFDocument(data: data)), source = try #require(PDFDocument(data: data))
        // A box over a blank stretch below the last line: no hidden word lies
        // near it, so a page read that returns no words is a page checked.
        let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.05, width: 0.3, height: 0.05),
                                     source: .manual)
        let emptyRead = await VerificationEngine.$hiddenWordInkSourceRead.withValue({ _ in [] }) {
            await run(.hiddenWordInk, output, regions: [0: [region]], source: source)
        }
        #expect(emptyRead.status == .pass, "a read that returns no words is a read: the page is checked")
        let r = await VerificationEngine.$onRecognitionSimulateNoResults.withValue({ _ in true }) {
            await run(.hiddenWordInk, output, regions: [0: [region]], source: source)
        }
        expectWarn(r, VerificationEngine.hiddenWordInkCouldNotCheck(page: 1), mark: true, pages: [0])
    }

    static func termsUnopenedPage() async throws {
        let doc = try open(rawPDF([RawPage(), RawPage()]), unopenable: [1])
        defer { remove(doc) }
        let r = await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED"])
        expectWarn(r, unread(2), mark: true, pages: [1])
    }

    /// The file reader counts two pages and returns none for the second.
    static func badKidPrecondition(_ data: Data) throws {
        let cg = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(cg.numberOfPages == 2, "precondition: the reader counts two pages; got \(cg.numberOfPages)")
        #expect(cg.page(at: 2)?.dictionary == nil, "precondition: the reader returns no second page")
        try #require(cg.numberOfPages == 2 && cg.page(at: 2)?.dictionary == nil)
    }

    static func termsUnreadableCGPage() async throws {
        let data = rawPDF([RawPage()], badKid: true)
        try badKidPrecondition(data)
        let doc = try open(data)
        defer { remove(doc) }
        let r = await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED"])
        expectWarn(r, unread(2), mark: true, pages: [1])
    }

    static func structureUnreadablePage() async throws {
        let data = rawPDF([RawPage()], badKid: true)
        try badKidPrecondition(data)
        let doc = try open(data)
        defer { remove(doc) }
        expectWarn(await run(.structureCheck, doc, mode: .secureRasterization), unread(2), mark: true, pages: [1])
    }

    /// The document opens and its bytes hold no end marker.
    static func noEndMarker(catalogExtras: String = "") throws -> UnopenablePagesDocument {
        let data = rawPDF([RawPage()], catalogExtras: catalogExtras, endMarker: false)
        try #require(data.range(of: Data("%%EOF".utf8)) == nil, "precondition: no end marker in the bytes")
        try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!)?.catalog != nil, "precondition: the file opens")
        return try open(data)
    }

    static func structureNoEndMarker() async throws {
        let doc = try noEndMarker()
        defer { remove(doc) }
        expectWarn(await run(.structureCheck, doc, mode: .secureRasterization),
                   "Could not inspect document structure", mark: true, pages: nil)
    }

    static func structureNoEndMarkerAndFindings() async throws {
        let doc = try noEndMarker(catalogExtras: "/Metadata 8 0 R")
        defer { remove(doc) }
        expectWarn(await run(.structureCheck, doc, mode: .secureRasterization),
                   "Could not inspect document structure; Structural findings: Metadata", mark: true, pages: nil)  // LegalPhrases:safe (the engine message)
    }

    static func structureUnreadablePageAndFindings() async throws {
        let data = rawPDF([RawPage()], catalogExtras: "/Metadata 8 0 R", badKid: true)
        try badKidPrecondition(data)
        let doc = try open(data)
        defer { remove(doc) }
        expectWarn(await run(.structureCheck, doc, mode: .secureRasterization),
                   "\(unread(2)); Structural findings: Metadata", mark: true, pages: [1])  // LegalPhrases:safe (the engine message)
    }

    static func positionsSecurePageUnopened() async throws {
        let doc = try open(rawPDF([RawPage(), RawPage()]), unopenable: [1])
        defer { remove(doc) }
        let r = await run(.spatialVerification, doc, modes: [.searchableRedaction, .secureRasterization])
        expectWarn(r, unread(2), mark: true, pages: [1])
    }

    static func positionsUnopenedBeatsGraze() async throws {
        let doc = try open(rawPDF([RawPage(content: text("SECRET CONTENT")), RawPage()]), unopenable: [1])
        defer { remove(doc) }
        let region = try grazeRegion(on: try #require(doc.page(at: 0)))
        expectWarn(await run(.spatialVerification, doc, regions: [0: [region]]), unread(2), mark: true, pages: [1])
    }

    typealias Bucket = VerificationEngine.PageOCRBucket

    static func fold(_ outcomes: [(page: Int, bucket: Bucket)]) -> LayerResult {
        let f = VerificationEngine.foldLayer2PageOutcomes(outcomes, pipelineMode: .searchableRedaction, documentHasRegions: true)
        return row(f.0, pages: f.1, couldNotVerify: f.3, part: f.6, partPages: f.7, terms: f.2)
    }

    static let unmapped4 = "OCR coordinates could not be mapped to page space on page 4 — text could not be confirmed inside or outside a redacted region"
    static let inRegion3 = "OCR detected text within a redacted region on page 3"
    static let unrun1 = "OCR could not be run on 1 page"

    static func ocrUnmappedThenInRegion() throws {
        expectWarn(fold([(3, .textInRegionSearchable), (4, .unmappable)]), "\(unmapped4); \(inRegion3)", mark: true, pages: [3])
    }

    static func ocrUnrunThenInRegion() throws {
        expectWarn(fold([(3, .textInRegionSearchable), (5, .unchecked)]), "\(unrun1); \(inRegion3)", mark: true, pages: [4])
    }

    static func fragmentDoc(pages: Int = 1, unopenable: Set<Int> = []) throws -> UnopenablePagesDocument {
        try open(rawPDF(Array(repeating: RawPage(), count: pages), info: "/X (CLASSIFIEDZ)"), unopenable: unopenable)
    }

    static func exifDoc(pages: Int, on picturePage: Int, unopenable: Set<Int> = []) throws -> UnopenablePagesDocument {
        var raw = Array(repeating: RawPage(), count: pages)
        raw[picturePage - 1].jpeg = TestFixtures.exifJPEG(app1Payloads: ["CLASSIFIED"])
        return try open(rawPDF(raw), unopenable: unopenable)
    }

    static func termsShortThenFragment() async throws {
        let doc = try fragmentDoc()
        defer { remove(doc) }
        expectWarn(await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED", "ab"]),
                   "\(short); \(fragment)", mark: true, pages: nil)
    }

    static func termsShortThenEXIF() async throws {
        let doc = try exifDoc(pages: 3, on: 3)
        defer { remove(doc) }
        expectWarn(await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED", "ab"]),
                   "\(short); \(exif(page: 3))", mark: true, pages: nil)
    }

    static func termsUnreadThenFragment() async throws {
        let doc = try fragmentDoc(pages: 2, unopenable: [1])
        defer { remove(doc) }
        expectWarn(await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED"]),
                   "\(unread(2)); \(fragment)", mark: true, pages: [1])
    }

    static func termsUnreadShortThenFragment() async throws {
        let doc = try fragmentDoc(pages: 2, unopenable: [1])
        defer { remove(doc) }
        expectWarn(await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED", "ab"]),
                   "\(unread(2)); \(short); \(fragment)", mark: true, pages: [1])
    }

    static func termsUnreadThenEXIF() async throws {
        let doc = try exifDoc(pages: 2, on: 1, unopenable: [1])
        defer { remove(doc) }
        expectWarn(await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED"]),
                   "\(unread(2)); \(exif(page: 1))", mark: true, pages: [1])
    }

    /// A document opened from a file that is then deleted.
    static func deletedFile() throws -> PDFDocument {
        let doc = try open(rawPDF([RawPage()]))
        try FileManager.default.removeItem(at: try #require(doc.documentURL))
        try #require((try? Data(contentsOf: doc.documentURL!)) == nil, "precondition: the file is gone")
        return doc
    }

    static func deletedFileTermsAndMetadata() async throws {
        let doc = try deletedFile()
        expectWarn(await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED"]),
                   "Could not read output PDF for binary search", mark: true, pages: nil)
        expectWarn(await run(.metadataCheck, doc, mode: .secureRasterization), "Could not inspect metadata", mark: true, pages: nil)
    }

    static func deletedFileStructure() async throws {
        let doc = try deletedFile()
        expectWarn(await run(.structureCheck, doc, mode: .secureRasterization),
                   "Could not inspect document structure", mark: true, pages: nil)
    }

    static func fixedDates(creation: String = PDFStreamReconstructor.fixedDateValue) -> String {
        "/CreationDate (\(creation)) /ModDate (\(PDFStreamReconstructor.fixedDateValue))"
    }

    static func metadataUndecodable() async throws {
        let doc = try open(rawPDF([RawPage()], info: "/Producer <\(unreadHex)> \(fixedDates())"))
        defer { remove(doc) }
        let r = await whereUnreadHexDoesNotDecode { await run(.metadataCheck, doc, mode: .secureRasterization) }
        expectWarn(r, "Could not inspect metadata", mark: true, pages: nil)
    }

    static func metadataUndecodableAndNotRewritten() async throws {
        let doc = try open(rawPDF([RawPage()], info: "/Producer <\(unreadHex)> \(fixedDates(creation: "D:19990101000000Z"))"))
        defer { remove(doc) }
        expectWarn(await whereUnreadHexDoesNotDecode { await run(.metadataCheck, doc, mode: .secureRasterization) },
                   "Could not inspect metadata; Producer or timestamp fields were not rewritten to the fixed values",
                   mark: true, pages: nil)
    }

    static func digest(_ page: Int, lineage: Data = Data(), surviving: Int = 0) -> PageFilterDigest {
        PageFilterDigest(pageIndex: page, extractedCount: surviving, excludedCount: 0, survivingCount: surviving,
                         boundaryCharacters: [], lineageHash: lineage)
    }

    static func sequenceEmptyRecord() async throws {
        let doc = try open(rawPDF([RawPage(), RawPage()]))
        defer { remove(doc) }
        let one = await run(.characterLineage, doc, digests: [digest(0, lineage: SandwichMetrics.emptyLineageDigest), digest(1)])
        expectWarn(one, notCrossChecked, mark: true, pages: [1])
        let both = await run(.characterLineage, doc, digests: [digest(0), digest(1)])
        #expect(both.status.isSkipped, "no page compared reads skipped; got \(both.status)")
        expectNotPassed(both)
    }

    /// The scan of `page` completes (no operator is installed).
    static func scanCompletes(_ doc: PDFDocument, page: Int) throws {
        let cgPage = try #require(doc.page(at: page)?.pageRef)
        let table = try #require(CGPDFOperatorTableCreate())
        defer { CGPDFOperatorTableRelease(table) }
        let stream = CGPDFContentStreamCreateWithPage(cgPage)
        defer { CGPDFContentStreamRelease(stream) }
        let scanner = CGPDFScannerCreate(stream, table, nil)
        defer { CGPDFScannerRelease(scanner) }
        try #require(CGPDFScannerScan(scanner), "precondition: the scan completes")
    }

    static func contentStreamsMissingOperand() async throws {
        let doc = try open(rawPDF([RawPage(content: "BT /F1 12 Tf Tj ET")]))
        defer { remove(doc) }
        try scanCompletes(doc, page: 0)
        expectWarn(await run(.operatorReExtraction, doc, terms: ["CLASSIFIED"]),
                   "Operator scanner could not traverse page 1", mark: true, pages: [0])
    }

    static func contentStreamsUndecodableOperand() async throws {
        let doc = try open(rawPDF([RawPage(content: "BT /F1 12 Tf <\(unreadHex)> Tj ET")]))
        defer { remove(doc) }
        try scanCompletes(doc, page: 0)
        expectWarn(await whereUnreadHexDoesNotDecode { await run(.operatorReExtraction, doc, terms: ["CLASSIFIED"]) },
                   "Operator scanner could not traverse page 1", mark: true, pages: [0])
    }

    static func recheckComparedNothing(scan: Bool) async throws -> LayerResult {
        let doc = try #require(PDFDocument(data: TestFixtures.textPagesPDF(["Statement of account for the period"])))
        let box = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05), source: .manual)
        var searches = [TestFixtures.textRequest("Delia")]
        if scan { searches.insert(UnfinishedRunTests.scanRequest(), at: 0) }
        return await run(.searchRecheck, doc, regions: [0: [box]], searches: searches)
    }

    static func recheckComparedNothingBoth() async throws {
        expectWarn(try await recheckComparedNothing(scan: true),
                   "Re-ran 1 search; \(SearchRecheck.coverageNoMatchClause); \(SearchRecheck.coverageNoSearchMatchClause)",
                   mark: true, pages: nil)
    }

    static func recheckComparedNothingSearch() async throws {
        expectWarn(try await recheckComparedNothing(scan: false),
                   "Re-ran 1 search; the re-run found none of the applied search's matches on the original pages, so the coverage check compared nothing",
                   mark: true, pages: nil)
    }

    // MARK: - Pins

    static func pinTextReadNothing(empty: Bool) async throws {
        let page = TextReadPage()
        page.empty = empty
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        let count = await run(.characterCount, doc, digests: [digest(0, surviving: 5)])
        #expect(count.status.isFail, "the count fails; got \(count.status)")
        #expect(message(count.status) == "Character count deficit on page 1: output has 0, expected 5", "got \(message(count.status))")
        let terms = await run(.binaryStringSearch, doc, terms: ["CLASSIFIED"])
        let positions = await run(.spatialVerification, doc)
        #expect(terms.status == .pass, "Terms in Text & Bytes passes; got \(terms.status)")
        #expect(positions.status == .pass, "Character Positions passes; got \(positions.status)")
        #expect(VerificationEngine().aggregateStatus([terms, positions, count]) != .pass)
    }

    static func pinInRegionAlone() throws {
        let r = fold([(3, .textInRegionSearchable)])
        expectWarn(r, inRegion3, mark: false, pages: [2])
    }

    static func pinFragmentAlone() async throws {
        let doc = try fragmentDoc()
        defer { remove(doc) }
        expectWarn(await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED"]),
                   fragment, mark: false, pages: nil)
    }

    static func pinEXIFAlone() async throws {
        let doc = try exifDoc(pages: 1, on: 1)
        defer { remove(doc) }
        expectWarn(await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED"]),
                   exif(page: 1), mark: false, pages: [0])
    }

    static func pinShortTermAlone() async throws {
        let doc = try open(rawPDF([RawPage()]))
        defer { remove(doc) }
        expectWarn(await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED", "ab"]),
                   short, mark: true, pages: nil)
    }

    // MARK: - An issue, and what it could not read

    static func findAnnotationsUnopened() async throws {
        let data = TestFixtures.threePageAnnotationsOnFirstAndThird()
        let doc = try open(data, unopenable: [1]), base = try open(data)
        defer { remove(doc); remove(base) }
        expectFindKept(await run(.textExtraction, doc, mode: .secureRasterization),
                       as: await run(.textExtraction, base, mode: .secureRasterization), part: unread(2), partPages: [1])
    }

    static func findTextAndAnnotations() async throws {
        let annotated = RawPage(extras: "/Annots [<< /Type /Annot /Subtype /Square /Rect [10 10 100 100] >>]")
        let doc = try open(rawPDF([RawPage(content: text("Statement")), RawPage(), annotated]))
        defer { remove(doc) }
        let r = await run(.textExtraction, doc, mode: .secureRasterization)
        #expect(r.status.isFail, "got \(r.status)")
        #expect(message(r.status) == "Selectable text found on page 1; Annotations found on page 3", "got \(message(r.status))")
        #expect(r.pageReferences == [0, 2])
        #expect(r.couldNotVerifyPart == nil && !r.couldNotVerify)
        expectNotPassed(r)
    }

    static let termInRegion3 = "Sensitive text detected within a redacted region on page 3"

    static func findOCRUnrun() throws {
        expectFindKept(fold([(3, .sensitiveTermInRegion), (5, .unchecked)]), as: fold([(3, .sensitiveTermInRegion)]),
                       part: unrun1, partPages: [4])
    }

    static func findOCRUnrunAndInRegion() throws {
        expectFindKept(fold([(1, .sensitiveTermInRegion), (3, .textInRegionSearchable), (5, .unchecked)]),
                       as: fold([(1, .sensitiveTermInRegion), (3, .textInRegionSearchable)]),
                       part: "\(unrun1); \(inRegion3)", partPages: [4])
    }

    static func findTermUnopened() async throws {
        let data = rawPDF([RawPage(content: text("CLASSIFIED here")), RawPage(content: text("other"))])
        let doc = try open(data, unopenable: [1]), base = try open(data)
        defer { remove(doc); remove(base) }
        expectFindKept(await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED"]),
                       as: await run(.binaryStringSearch, base, mode: .secureRasterization, terms: ["CLASSIFIED"]),
                       part: unread(2), partPages: [1])
    }

    static func findTermShort() async throws {
        let doc = try open(rawPDF([RawPage(content: text("CLASSIFIED here"))]))
        defer { remove(doc) }
        expectFindKept(await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED", "ab"]),
                       as: await run(.binaryStringSearch, doc, mode: .secureRasterization, terms: ["CLASSIFIED"]),
                       part: short, partPages: [])
    }

    static let pageAction = "/AA << /O << /S /JavaScript /JS (app.alert(1)) >> >>"

    static func findPageActionUnreadable() async throws {
        let data = rawPDF([RawPage(extras: pageAction)], badKid: true)
        try badKidPrecondition(data)
        let doc = try open(data), base = try open(rawPDF([RawPage(extras: pageAction)]))
        defer { remove(doc); remove(base) }
        expectFindKept(await run(.structureCheck, doc, mode: .secureRasterization),
                       as: await run(.structureCheck, base, mode: .secureRasterization), part: unread(2), partPages: [1])
    }

    static func findPositionUnopened() async throws {
        let data = rawPDF([RawPage(content: text("SECRET CONTENT")), RawPage()])
        let doc = try open(data, unopenable: [1]), base = try open(data)
        defer { remove(doc); remove(base) }
        let region = try coverRegion(on: try #require(base.page(at: 0)), count: 6)
        expectFindKept(await run(.spatialVerification, doc, regions: [0: [region]]),
                       as: await run(.spatialVerification, base, regions: [0: [region]]), part: unread(2), partPages: [1])
    }

    static func findCountNoRecord() async throws {
        let doc = try open(rawPDF([RawPage(content: text("ABCDEFG")), RawPage()]))
        defer { remove(doc) }
        let r = await run(.characterCount, doc, digests: [digest(0, surviving: 9), nil])
        expectFindKept(r, as: await run(.characterCount, doc, digests: [digest(0, surviving: 9), digest(1)]),
                       part: notCrossChecked, partPages: [1])
        #expect(message(r.status) == "Character count deficit on page 1: output has 7, expected 9", "got \(message(r.status))")
    }

    static func findFontUnopened() async throws {
        let data = rawPDF([RawPage(content: text("Statement")), RawPage(font: false)])
        let doc = try open(data, unopenable: [1]), base = try open(data)
        defer { remove(doc); remove(base) }
        expectFindKept(await run(.fontVerification, doc), as: await run(.fontVerification, base), part: unread(2), partPages: [1])
    }

    static func findSequenceNoRecord() async throws {
        let doc = try open(rawPDF([RawPage(content: text("Statement")), RawPage()]))
        defer { remove(doc) }
        let mismatch = Data(repeating: 7, count: 32)
        expectFindKept(await run(.characterLineage, doc, digests: [digest(0, lineage: mismatch), nil]),
                       as: await run(.characterLineage, doc, digests: [digest(0, lineage: mismatch),
                                                                       digest(1, lineage: SandwichMetrics.emptyLineageDigest)]),
                       part: notCrossChecked, partPages: [1])
    }

    static func findContentStreamsUnread() async throws {
        let doc = try open(rawPDF([RawPage(content: "BT /F1 12 Tf Tj ET"), RawPage(content: text("CLASSIFIED"))]))
        let base = try open(rawPDF([RawPage(content: text("other")), RawPage(content: text("CLASSIFIED"))]))
        defer { remove(doc); remove(base) }
        expectFindKept(await run(.operatorReExtraction, doc, terms: ["CLASSIFIED"]),
                       as: await run(.operatorReExtraction, base, terms: ["CLASSIFIED"]),
                       part: "Operator scanner could not traverse page 1", partPages: [0])
    }

    static func hiddenFold(_ outcomes: [(page: Int, outcome: VerificationEngine.HiddenWordInkPage)]) -> LayerResult {
        let f = VerificationEngine.foldHiddenWordInk(outcomes)
        return row(f.0, pages: f.1, couldNotVerify: f.2, part: f.4, partPages: f.5)
    }

    static func findHiddenWordsUnmatched() throws {
        let flagged = VerificationEngine.HiddenWordInkPage.verdict(HiddenWordInkVerdict(
            findings: [HiddenWordInkMark(pageIndex: 0, regionID: UUID(), inkRect: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.02))]))
        expectFindKept(hiddenFold([(0, flagged), (1, .couldNotCheck)]), as: hiddenFold([(0, flagged)]),
                       part: VerificationEngine.hiddenWordInkCouldNotCheck(page: 2), partPages: [1])
    }

    static func observation(_ page: Int, route: PageSearchCoverage.Route?, remaining: Int = 0) -> RecheckObservation {
        RecheckObservation(pageIndex: page, route: route, regexTimedOut: false,
                           counts: route == .textLayer ? [0: UnfinishedRunTests.count(remaining)] : [:],
                           textLayerRead: route == .textLayer)
    }

    static func recheck(_ observations: [RecheckObservation], shortfalls: [SearchRecheck.Shortfall] = []) -> LayerResult {
        let o = SearchRecheck.fold(requests: [TestFixtures.textRequest("Delia")], observations: observations, pageCount: 2,
                                   shortfalls: shortfalls)
        return row(o.status, pages: o.pageReferences, couldNotVerify: o.status.isWarn, part: o.partSentence,
                   partPages: o.partPages, terms: o.reviewTermTexts)
    }

    static func findRecheckRemainsUnopened() throws {
        let r = recheck([observation(0, route: .textLayer, remaining: 1), observation(1, route: .unopenable)])
        let base = recheck([observation(0, route: .textLayer, remaining: 1), observation(1, route: .textLayer)])
        #expect(r.status.isAttention && base.status.isAttention)
        #expect(message(r.status) == "Re-ran 1 search — 1 match remains on page 1, 1 page could not be checked: 2",
                "the needs-review sentence as composed today; got \(message(r.status))")
        #expect(r.pageReferences == base.pageReferences && r.reviewTermTexts == base.reviewTermTexts)
        #expect(r.couldNotVerifyPart == "1 page could not be checked: 2" && r.couldNotVerifyPartPages == [1])
        #expect(!r.couldNotVerify && base.couldNotVerifyPart == nil)
        expectNotPassed(r)
    }

    static func findRecheckShortfallUnopened() throws {
        let partly = [SearchRecheck.Shortfall(page: 0, displayText: "Delia")]
        expectFindKept(recheck([observation(0, route: .textLayer), observation(1, route: .unopenable)], shortfalls: partly),
                       as: recheck([observation(0, route: .textLayer), observation(1, route: .textLayer)], shortfalls: partly),
                       part: "1 page could not be checked: 2", partPages: [1])
    }

    static func sweepRequest(_ categories: Set<PIICategory>, origin: SearchRecheckRequest.Origin = .applied) -> SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(query: AppliedSearchQuery(kind: .piiScan(categories: categories), options: SearchOptions()),
                                        foundCount: 1),
            appliedCount: origin == .applied ? 1 : 0, appliedPages: origin == .applied ? [0] : [], origin: origin)
    }

    static func sweepPage(_ page: Int, route: PageSearchCoverage.Route?, items: [Int: [RecheckObservation.RemainingItem]]) -> RecheckObservation {
        var counts: [Int: RecheckObservation.Count] = [:]
        if route != .unopenable {
            for (request, list) in items {
                counts[request] = RecheckObservation.Count(remaining: list.count, hitCap: false,
                                                           perTerm: list.isEmpty ? [:] : [list[0].category?.rawValue ?? "Custom": list.count],
                                                           items: list)
            }
        }
        return RecheckObservation(pageIndex: page, route: route, regexTimedOut: false, counts: counts,
                                  textLayerRead: route == .textLayer)
    }

    static func sweep(_ requests: [SearchRecheckRequest], _ observations: [RecheckObservation]) -> LayerResult {
        let o = DetectionSweep.fold(requests: requests, observations: observations, pageCount: 2)
        return row(o.status, pages: o.pageReferences, couldNotVerify: o.status.isWarn, part: o.partSentence,
                   partPages: o.partPages, terms: o.reviewTermTexts)
    }

    static func ssn(_ page: Int) -> RecheckObservation.RemainingItem {
        RecheckObservation.RemainingItem(pageIndex: page, category: .ssn, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.04),
                                         matchedText: "123-45-6789")
    }

    static func findSweepRemainsUnopened() throws {
        let requests = [sweepRequest([.ssn])]
        let r = sweep(requests, [sweepPage(0, route: .textLayer, items: [0: [ssn(0)]]), sweepPage(1, route: .unopenable, items: [:])])
        let base = sweep(requests, [sweepPage(0, route: .textLayer, items: [0: [ssn(0)]]), sweepPage(1, route: .textLayer, items: [0: []])])
        expectFindKept(r, as: base, part: "1 page could not be checked: 2", partPages: [1])
        #expect(r.status.isAttention, "Needs review, where it read could not verify")
    }

    // MARK: - More than one condition, and the page lists

    static func ocrBothConditions() throws {
        let r = fold([(3, .textInRegionSearchable), (4, .unmappable), (5, .unchecked)])
        expectWarn(r, "\(unmapped4); \(unrun1); \(inRegion3)", mark: true, pages: [3, 4])
        #expect(message(r.status).count == 211)
    }

    static func annotationsNoURLUnopened() async throws {
        let doc = try #require(UnopenablePagesDocument(data: rawPDF([RawPage(), RawPage()])))
        doc.unopenable = [1]
        try #require(doc.documentURL == nil, "precondition: no file URL")
        expectWarn(await run(.textExtraction, doc, mode: .secureRasterization),
                   "Could not verify /AcroForm absence; \(unread(2))", mark: true, pages: [1])
    }

    static func positionsUnmeasuredUnopenedGraze() async throws {
        let unmeasured = RawPage(content: "BT /F1 12 Tf 0 0 0 0 100 700 Tm (AB) Tj ET")
        let doc = try open(rawPDF([unmeasured, RawPage(), RawPage(content: text("SECRET CONTENT"))]), unopenable: [1])
        defer { remove(doc) }
        let region = try grazeRegion(on: try #require(doc.page(at: 2)))
        let zero = message(SandwichVerification.zeroBoundsWarning(count: 2, pageIndex: 0))
        expectWarn(await run(.spatialVerification, doc, regions: [2: [region]]), "\(zero); \(unread(2))", mark: true, pages: [0, 1])
    }

    static func countNoRecordThenExcess() async throws {
        let doc = try open(rawPDF([RawPage(content: text("ABCDEFGHIJKL")), RawPage()]))
        defer { remove(doc) }
        expectWarn(await run(.characterCount, doc, digests: [digest(0, surviving: 9), nil]),
                   "\(notCrossChecked); Character count excess on page 1: output has 12, expected 9", mark: true, pages: [1])
    }

    static func fontsUnopenedThenNoResources() async throws {
        let doc = try open(rawPDF([RawPage(font: false), RawPage(font: false), RawPage(resources: false)]), unopenable: [1])
        defer { remove(doc) }
        let r = await run(.fontVerification, doc)
        expectWarn(r, "\(unread(2)); Page 3 has no page-level /Resources — font verification skipped", mark: true, pages: [1, 2])
        #expect(message(r.status).count == 104)
    }

    static func sweepPossibleOnlyUnopened() throws {
        let requests = [sweepRequest([.email]), sweepRequest(Set(PIICategory.allCases), origin: .sweep)]
        let r = sweep(requests, [sweepPage(0, route: .textLayer, items: [0: [], 1: [ssn(0)]]), sweepPage(1, route: .unopenable, items: [:])])
        #expect(r.status.isWarn, "could not verify, as today; got \(r.status)")
        #expect(r.couldNotVerify && r.couldNotVerifyPart == nil)
        #expect(r.pageReferences == [1], "only the page it could not check; got \(String(describing: r.pageReferences))")
        expectNotPassed(r)
    }
}
