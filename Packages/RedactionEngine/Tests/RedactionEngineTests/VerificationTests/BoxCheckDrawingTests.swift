import CryptoKit
import Foundation
import Testing
@testable import RedactionEngine

// The box check's own reading of what each page draws (PageDrawingReader).
// Every page the app's pipeline exports is admitted, whatever its mode, size
// or picture. A one-page file in the writer's form is admitted; changed by
// one key, one operator or one segment it is refused, by name, for each way
// a page can show something other than its one stored picture.

private typealias D = PageDrawingFixtures
private typealias Reason = PageImageRefusal.Reason

/// The outcome's refusal, or nil for a completed walk.
private func refusal(_ o: PageImageOutcome) -> PageImageRefusal? {
    if case .couldNotFinish(let r) = o { r } else { nil }
}

@Suite("The box check refuses a page that draws more than its picture", .serialized)
struct BoxCheckDrawingTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let number: Int
        let name: String
        let expected: PageImageRefusal.Reason?
        let change: @Sendable (inout PageDrawingFixtures.Page) -> Void
        var testDescription: String { "D\(number): \(name)" }
    }

    static let content = "q 144 0 0 144 0 0 cm /Im1 Do Q"
    static let writersFont = "/F1 << /Type /Font /Subtype /TrueType /BaseFont /Courier /FirstChar 32 /LastChar 32 /Widths [600] "
        + "/FontDescriptor << /Type /FontDescriptor /FontName /Courier /Flags 32 /FontBBox [0 0 600 600] /ItalicAngle 0 "
        + "/Ascent 600 /Descent 0 /CapHeight 600 /StemV 80 /FontFile2 6 0 R >> >>"
    static let form = "<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] /Length 0 >>\nstream\n\nendstream"

    static func picture(_ change: @escaping @Sendable (Data) -> Data) -> @Sendable (inout PageDrawingFixtures.Page) -> Void {
        { $0.picture = change($0.picture) }
    }

    static let cases: [Case] = [
        // Admitted: the writer's form, and what it may hold beside its picture.
        Case(number: 1, name: "the writer's form: one picture drawn once over the page box", expected: nil) { _ in },
        Case(number: 2, name: "invisible text in a TrueType face beside it", expected: nil) {
            $0.fonts = writersFont; $0.content = content + " BT /F1 12 Tf 0 Tc 3 Tr 1 0 0 1 10 10 Tm (a) Tj ET" },
        Case(number: 3, name: "the text mode a q saved, restored by its Q", expected: nil) {
            $0.content = content + " BT 3 Tr ET q 0 Tr Q BT (a) Tj ET" },
        Case(number: 4, name: "the page-box matrix made in two steps whose order counts", expected: nil) {
            $0.content = "q 1 0 0 1 10 0 cm 144 0 0 144 -10 0 cm /Im1 Do Q" },
        Case(number: 5, name: "a matrix undone by its Q before the draw", expected: nil) {
            $0.content = "q 2 0 0 2 0 0 cm Q " + content },
        Case(number: 6, name: "operator words inside a shown string, one after an escaped bracket", expected: nil) {
            $0.content = content + " BT 3 Tr (q 0 0 9 9 re f) Tj (a\\) f BI) Tj ET" },
        Case(number: 7, name: "a comment and a name that read as operators", expected: nil) {
            $0.content = "% 0 0 9 9 re f\n" + content + " BT /f 12 Tf 3 Tr (a) Tj ET" },
        // The content: every operator outside the writer's.
        Case(number: 10, name: "an inline picture after the picture", expected: .operatorNotListed) {
            $0.content = content + " BI /W 1 /H 1 /CS /G /BPC 8 ID \u{0} EI" },
        Case(number: 11, name: "the picture clipped by a path", expected: .operatorNotListed) {
            $0.content = "q 0 0 72 72 re W n 144 0 0 144 0 0 cm /Im1 Do Q" },
        Case(number: 12, name: "a fill painted over the picture", expected: .operatorNotListed) {
            $0.content = content + " 0 g 0 0 10 10 re f" },
        Case(number: 13, name: "a shading painted", expected: .operatorNotListed) { $0.content = content + " /Sh0 sh" },
        Case(number: 14, name: "a graphics-state dictionary set before the draw", expected: .operatorNotListed) {
            $0.content = "/GS0 gs " + content },
        Case(number: 15, name: "the picture inside optional content", expected: .operatorNotListed) {
            $0.content = "/OC /L0 BDC " + content + " EMC" },
        Case(number: 16, name: "text shown with TJ, even in mode 3", expected: .operatorNotListed) {
            $0.content = content + " BT 3 Tr [(a)] TJ ET" },
        Case(number: 17, name: "a compatibility section", expected: .operatorNotListed) { $0.content = "BX " + content + " EX" },
        Case(number: 18, name: "an operator no list names", expected: .operatorNotListed) { $0.content = content + " zz" },
        // Text that paints or clips.
        Case(number: 20, name: "text shown filled, mode 0", expected: .textNotInvisible) { $0.content = content + " BT 0 Tr (a) Tj ET" },
        Case(number: 21, name: "text shown before any mode is set", expected: .textNotInvisible) { $0.content = content + " BT (a) Tj ET" },
        Case(number: 22, name: "text as a clip, mode 7, then the picture", expected: .textNotInvisible) {
            $0.content = "BT 7 Tr (a) Tj ET " + content },
        // How often and where the picture is drawn.
        Case(number: 30, name: "the picture drawn twice", expected: .pictureNotDrawnOnce) { $0.content = content + " " + content },
        Case(number: 31, name: "the picture never drawn", expected: .pictureNotDrawnOnce) { $0.content = "q Q" },
        Case(number: 32, name: "a second picture listed", expected: .pictureNotDrawnOnce) { $0.pictures = "/Im1 5 0 R /Im2 5 0 R" },
        Case(number: 33, name: "a draw of a name the page does not list", expected: .pictureNotDrawnOnce) {
            $0.content = "q 144 0 0 144 0 0 cm /Im9 Do Q" },
        Case(number: 34, name: "the picture drawn half the page wide", expected: .pictureNotOverThePage) {
            $0.content = "q 72 0 0 144 0 0 cm /Im1 Do Q" },
        Case(number: 35, name: "the picture moved one point right", expected: .pictureNotOverThePage) {
            $0.content = "q 144 0 0 144 1 0 cm /Im1 Do Q" },
        Case(number: 36, name: "a matrix left open from before the draw", expected: .pictureNotOverThePage) {
            $0.content = "2 0 0 2 0 0 cm " + content },
        // Resources outside the writer's.
        Case(number: 40, name: "a pattern resource", expected: .resourceNotListed) { $0.resources = "/Pattern << >>" },
        Case(number: 41, name: "a graphics-state resource", expected: .resourceNotListed) { $0.resources = "/ExtGState << >>" },
        Case(number: 42, name: "a shading resource", expected: .resourceNotListed) { $0.resources = "/Shading << >>" },
        Case(number: 43, name: "an optional-content resource", expected: .resourceNotListed) { $0.resources = "/Properties << >>" },
        Case(number: 44, name: "a colour-space resource", expected: .resourceNotListed) { $0.resources = "/ColorSpace << >>" },
        Case(number: 45, name: "a Type3 font, whose glyphs are drawings", expected: .resourceNotListed) {
            $0.fonts = "/F1 << /Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] /FontMatrix [1 0 0 1 0 0] /CharProcs << >> /Encoding << >> /FirstChar 0 /LastChar 0 /Widths [0] /Resources << >> >>" },
        Case(number: 46, name: "a Type1 font", expected: .resourceNotListed) {
            $0.fonts = "/F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>" },
        Case(number: 47, name: "a TrueType font whose program is not a TrueType one", expected: .resourceNotListed) {
            $0.fonts = writersFont.replacingOccurrences(of: "/FontFile2", with: "/FontFile3") },
        Case(number: 48, name: "a form drawn in place of the picture", expected: .resourceNotListed) {
            $0.pictures = "/Im1 7 0 R"; $0.more = [form] },
        // The picture's own keys.
        Case(number: 50, name: "a soft mask on the picture", expected: .pictureKeyNotListed) { $0.pictureKeys = "/SMask 5 0 R" },
        Case(number: 51, name: "a mask on the picture", expected: .pictureKeyNotListed) { $0.pictureKeys = "/Mask [0 0 0 0 0 0]" },
        Case(number: 52, name: "a decode array that inverts it", expected: .pictureKeyNotListed) { $0.pictureKeys = "/Decode [1 0 1 0 1 0]" },
        Case(number: 53, name: "decode parameters that turn off its colour transform", expected: .pictureKeyNotListed) {
            $0.pictureKeys = "/DecodeParms << /ColorTransform 0 >>" },
        Case(number: 54, name: "alternate pictures", expected: .pictureKeyNotListed) { $0.pictureKeys = "/Alternates [<< /Image 5 0 R >>]" },
        Case(number: 55, name: "a prepress swap", expected: .pictureKeyNotListed) { $0.pictureKeys = "/OPI << >>" },
        Case(number: 56, name: "its data in another file", expected: .pictureKeyNotListed) { $0.pictureKeys = "/F (picture.jpg)" },
        Case(number: 57, name: "a stencil flag", expected: .pictureKeyNotListed) { $0.pictureKeys = "/ImageMask false" },
        Case(number: 58, name: "optional content on the picture", expected: .pictureKeyNotListed) { $0.pictureKeys = "/OC << /Type /OCG /Name (L) >>" },
        Case(number: 59, name: "a rendering intent on the picture", expected: .pictureKeyNotListed) { $0.pictureKeys = "/Intent /Perceptual" },
        Case(number: 60, name: "the filter given as a list", expected: .pictureKeyNotListed) { $0.filter = "[/DCTDecode]" },
        Case(number: 61, name: "a device colour space", expected: .pictureColourNotListed) { $0.colourSpace = "/DeviceRGB" },
        Case(number: 62, name: "a one-component profile", expected: .pictureColourNotListed) { $0.profileKeys = "/N 1 /Alternate /DeviceGray" },
        Case(number: 63, name: "a profile with a range", expected: .pictureColourNotListed) {
            $0.profileKeys = "/N 3 /Alternate /DeviceRGB /Range [0 1 0 1 0 1]" },
        Case(number: 64, name: "an indexed colour space", expected: .pictureColourNotListed) {
            $0.colourSpace = "[/Indexed /DeviceRGB 1 <000000FFFFFF>]" },
        Case(number: 65, name: "16 bits a component", expected: .pictureColourNotListed) { $0.bitsPerComponent = 16 },
        Case(number: 66, name: "a four-component profile over device RGB", expected: .pictureColourNotListed) {
            $0.profileKeys = "/N 4 /Alternate /DeviceRGB" },
        Case(number: 67, name: "a three-component profile over device grey", expected: .pictureColourNotListed) {
            $0.profileKeys = "/N 3 /Alternate /DeviceGray" },
        // The page and the tree above it.
        Case(number: 70, name: "an annotation", expected: .pageKeyNotListed) { $0.page = "/Annots [<< /Type /Annot /Subtype /Square /Rect [0 0 10 10] >>]" },
        Case(number: 71, name: "a transparency group", expected: .pageKeyNotListed) { $0.page = "/Group << /S /Transparency >>" },
        Case(number: 72, name: "a thumbnail", expected: .pageKeyNotListed) { $0.page = "/Thumb 5 0 R" },
        Case(number: 73, name: "a crop box", expected: .pageKeyNotListed) { $0.page = "/CropBox [0 0 72 72]" },
        Case(number: 74, name: "a turn", expected: .pageKeyNotListed) { $0.page = "/Rotate 90" },
        Case(number: 75, name: "a user unit", expected: .pageKeyNotListed) { $0.page = "/UserUnit 2" },
        Case(number: 76, name: "page actions", expected: .pageKeyNotListed) { $0.page = "/AA << >>" },
        Case(number: 77, name: "application data", expected: .pageKeyNotListed) { $0.page = "/PieceInfo << >>" },
        Case(number: 78, name: "a turn the page inherits from its tree", expected: .pageKeyNotListed) { $0.pageTree = "/Rotate 90" },
        Case(number: 79, name: "a crop box the page inherits from its tree", expected: .pageKeyNotListed) { $0.pageTree = "/CropBox [0 0 72 72]" },
        // The file as a whole: every page's reason.
        Case(number: 80, name: "a form the viewer fills", expected: .documentKeyNotListed) { $0.catalog = "/AcroForm << /Fields [] >>" },
        Case(number: 81, name: "optional content in the catalog", expected: .documentKeyNotListed) {
            $0.catalog = "/OCProperties << /OCGs [] /D << >> >>" },
        Case(number: 82, name: "an action on opening", expected: .documentKeyNotListed) { $0.catalog = "/OpenAction [3 0 R /Fit]" },
        Case(number: 83, name: "named files and scripts", expected: .documentKeyNotListed) { $0.catalog = "/Names << >>" },
        Case(number: 84, name: "a portfolio", expected: .documentKeyNotListed) { $0.catalog = "/Collection << >>" },
        Case(number: 85, name: "a second revision appended", expected: .fileRevised) {
            $0.appended = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\nxref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 7 /Root 1 0 R /Prev 9 >>\nstartxref\n0\n%%EOF\n" },
        Case(number: 86, name: "a trailer that names an earlier one", expected: .fileRevised) { $0.trailer = "/Prev 9" },
        Case(number: 87, name: "a trailer that names an earlier one with an escape", expected: .fileRevised) { $0.trailer = "/Pr#65v 9" },
        Case(number: 88, name: "a trailer that names a cross-reference stream", expected: .fileRevised) { $0.trailer = "/XRefStm 9" },
        Case(number: 89, name: "an object after the end of the file", expected: .fileRevised) { $0.appended = "9 0 obj\n<< >>\nendobj\n" },
        Case(number: 98, name: "a second trailer word after the name of an earlier one", expected: .fileRevised) {
            $0.trailer = "/Prev 9 /Note (trailer)" },
        Case(number: 104, name: "startxref names a cross-reference stream that names an earlier one, the one trailer word left in the file",
             expected: .fileRevised) {
            $0.more = ["<< /Type /XRef /Size 8 /W [1 2 1] /Prev 9 /Length 0 >>\nstream\n\nendstream"]; $0.startxrefObject = 7 },
        Case(number: 105, name: "startxref names a byte past the start of the table", expected: .fileRevised) { $0.startxrefShift = 1 },
        Case(number: 106, name: "startxref's number in thirteen digits: the table's offset zero-padded to twelve, then one digit more",
             expected: .fileRevised) { $0.startxrefWidth = 12; $0.startxrefAfter = "7" },
        Case(number: 107, name: "startxref's number followed by a byte that is not a line end", expected: .fileRevised) {
            $0.startxrefAfter = " 5" },
        Case(number: 108, name: "startxref names the xref inside its own keyword, after the trailer", expected: .fileRevised) {
            $0.startxrefSelf = true },
        // The picture's segments.
        Case(number: 90, name: "a comment segment", expected: .unlistedSegment,
             change: picture { D.withSegment($0, marker: 0xFE, body: Array("note".utf8)) }),
        Case(number: 91, name: "a colour profile segment", expected: .unlistedSegment,
             change: picture { D.withSegment($0, marker: 0xE2, body: Array("ICC_PROFILE\0\u{1}\u{1}".utf8)) }),
        Case(number: 92, name: "an Exif segment that names a second directory, where a thumbnail lives", expected: .unlistedSegment,
             change: picture { D.withSegment(D.withoutSegment($0, marker: 0xE1), marker: 0xE1, body: D.exif(next: 26)) }),
        Case(number: 93, name: "an Exif segment with no second directory, holding an orientation the writer does not write",
             expected: .unlistedSegment,
             change: picture { D.withSegment(D.withoutSegment($0, marker: 0xE1), marker: 0xE1, body: D.exif(next: 0)) }),
        Case(number: 99, name: "the writer's Exif segment one byte longer", expected: .unlistedSegment,
             change: picture { D.withSegment(D.withoutSegment($0, marker: 0xE1), marker: 0xE1, body: D.writersExif() + [0]) }),
        Case(number: 100, name: "the writer's Exif segment naming the picture's own sides", expected: nil,
             change: picture { D.withSegment(D.withoutSegment($0, marker: 0xE1), marker: 0xE1, body: D.writersExif()) }),
        Case(number: 101, name: "the writer's Exif segment naming sides other than the picture's", expected: .unlistedSegment,
             change: picture { D.withSegment(D.withoutSegment($0, marker: 0xE1), marker: 0xE1, body: D.writersExif(width: 97)) }),
        Case(number: 102, name: "the writer's Exif segment with one byte outside the sides changed", expected: .unlistedSegment,
             change: picture { var e = D.writersExif(); e[43] = 2; return D.withSegment(D.withoutSegment($0, marker: 0xE1), marker: 0xE1, body: e) }),
        Case(number: 103, name: "the writer's Exif segment twice", expected: .unlistedSegment,
             change: picture { D.withSegment(D.withSegment(D.withoutSegment($0, marker: 0xE1), marker: 0xE1, body: D.writersExif()),
                                             marker: 0xE1, body: D.writersExif()) }),
        Case(number: 94, name: "a Photoshop segment one byte longer than the writer's", expected: .unlistedSegment,
             change: picture { D.withSegment(D.withoutSegment($0, marker: 0xED), marker: 0xED, body: D.segmentBody($0, marker: 0xED)! + [0]) }),
        Case(number: 95, name: "a JFIF extension segment, which can hold a thumbnail", expected: .unlistedSegment,
             change: picture { D.withSegment($0, marker: 0xE0, body: Array("JFXX\0\u{10}".utf8)) }),
        Case(number: 96, name: "an Adobe segment", expected: .unlistedSegment,
             change: picture { D.withSegment($0, marker: 0xEE, body: Array("Adobe\0d\0\0\0\0\u{1}".utf8)) }),
        // Not read.
        Case(number: 97, name: "a Q with nothing saved", expected: .drawingNotRead) { $0.content = "Q " + content },
    ]

    @Test("The table holds 92 cases, eight of them admitted")
    func tableLength() {
        #expect(Self.cases.count == 92)
        #expect(Set(Self.cases.map(\.number)).count == 92)
        #expect(Self.cases.filter { $0.expected == nil }.count == 8)
    }

    @Test("Each case", arguments: BoxCheckDrawingTests.cases)
    func eachCase(_ c: Case) throws {
        var page = PageDrawingFixtures.Page()
        c.change(&page)
        let file = page.file()
        let pages = try PageDrawingReader.read(fileData: file)
        try #require(pages.count == 1, "one page read: \(pages.count)")
        switch (pages[0], c.expected) {
        case (.success(let d), nil):
            #expect(d.pictureSHA256 == Data(SHA256.hash(data: page.picture)))
            #expect(d.width == 96 && d.height == 96)
            let walk = try D.walk(page.picture)
            #expect(refusal(PageDrawingReader.admit(.completed(walk), drawing: pages[0])) == nil)
        case (.failure(let r), let expected?):
            #expect(r == PageImageRefusal(reason: expected, offset: 0))
            #expect(r.reason.fault == .unreadableInput)
        default:
            Issue.record("D\(c.number): \(pages[0]) where \(c.expected.map { "\($0)" } ?? "admitted") was expected")
        }
    }

    @Test("A drawing whose picture or sides differ from the walk's refuses the walk; any other outcome stands")
    func admitHoldsTheWalkToTheDrawing() throws {
        let jpeg = D.writersPicture()
        let walk = try D.walk(jpeg)
        let same = PageDrawing(pictureSHA256: Data(SHA256.hash(data: jpeg)), width: 96, height: 96)
        #expect(refusal(PageDrawingReader.admit(.completed(walk), drawing: .success(same))) == nil)
        let other = PageDrawing(pictureSHA256: Data(repeating: 1, count: 32), width: 96, height: 96)
        #expect(refusal(PageDrawingReader.admit(.completed(walk), drawing: .success(other)))
                == PageImageRefusal(reason: .pictureNotDrawnOnce, offset: 0))
        let wider = PageDrawing(pictureSHA256: same.pictureSHA256, width: 97, height: 96)
        #expect(refusal(PageDrawingReader.admit(.completed(walk), drawing: .success(wider)))
                == PageImageRefusal(reason: .pictureSizeDiffers, offset: 0))
        let refused = PageImageRefusal(reason: .operatorNotListed, offset: 0)
        #expect(refusal(PageDrawingReader.admit(.completed(walk), drawing: .failure(refused))) == refused)
        let readers = PageImageOutcome.couldNotFinish(PageImageRefusal(reason: .notJPEG, offset: 0))
        #expect(refusal(PageDrawingReader.admit(readers, drawing: .failure(refused))) == refusal(readers), "the reader's own reason stands first")
    }

    @Test("Bytes that are not a file give no page; a document reason is every page's")
    func notAFileAndEveryPage() throws {
        #expect(try PageDrawingReader.read(fileData: Data("not a file".utf8)).isEmpty)
        var page = PageDrawingFixtures.Page()
        page.catalog = "/AcroForm << /Fields [] >>"
        let pages = try PageDrawingReader.read(fileData: page.file())
        #expect(pages.map { (try? $0.get()) == nil } == [true])
    }

    @Test("The check over a file: a page that draws an annotation gives its page and its box no verdict but unreadable input")
    func runRefusesWhatThePageDraws() throws {
        var page = PageDrawingFixtures.Page()
        let input = { (p: PageDrawingFixtures.Page) in
            BoxCheckInput(fill: .black, chosenDPI: 300,
                          pages: [.init(widthSixtyFourths: 9216, heightSixtyFourths: 9216,
                                        boxes: [BoxCheckFixtures.box(BoxCheckFixtures.r(1000, 1000, 2000, 2000))], reported: [:])],
                          pageImageDigests: [Data(SHA256.hash(data: p.picture))])
        }
        let plain = page.file()
        let admitted = try ExactFillCheck.run(fileData: plain, source: try #require(SystemPageImageSource(fileData: plain)), input: input(page))
        #expect(admitted.outcomes.map(\.kind).first == .completed, "the writer's form: its picture is read (\(admitted.outcomes))")
        page.page = "/Annots [<< /Type /Annot /Subtype /Square /Rect [0 0 10 10] >>]"
        let drawn = page.file()
        let refused = try ExactFillCheck.run(fileData: drawn, source: try #require(SystemPageImageSource(fileData: drawn)), input: input(page))
        #expect(refused.outcomes.map(\.kind) == [.fault(.unreadableInput), .fault(.unreadableInput)], "\(refused.outcomes)")
    }

    @Test("Every page the app's pipeline exports is admitted: its one picture, at its sides", arguments: [
        ("Secure, one typed page, 300 dpi, black", [D.Source.text(D.letter, D.typed)], PipelineMode.secureRasterization, 300, FillColor.black),
        ("Searchable, one typed page, 300 dpi", [.text(D.letter, D.typed)], .searchableRedaction, 300, .black),
        ("Searchable, white fill, 200 dpi", [.text(D.letter, D.typed)], .searchableRedaction, 200, .white),
        ("Searchable, four pages of three sizes, A4 to the hundredth of a point, a scan last", [.text(D.letter, D.typed), .text(D.a4, D.typed),
            .text(D.wide, D.typed), .scan(D.letter, gray: false)], .searchableRedaction, 150, .black),
        ("Secure, a colour scan", [.scan(D.letter, gray: false)], .secureRasterization, 300, .black),
        ("Secure, a grey scan", [.scan(D.letter, gray: true)], .secureRasterization, 300, .black),
        ("Searchable, a grey A4 scan then a typed page", [.scan(D.a4, gray: true), .text(D.letter, D.typed)], .searchableRedaction, 300, .black),
        ("Searchable, lines in many scripts, ligatures and emoji", [.text(D.letter, D.mixed)], .searchableRedaction, 300, .black),
    ] as [(String, [PageDrawingFixtures.Source], PipelineMode, Int, FillColor)])
    func everyExportAdmitted(_ c: (String, [PageDrawingFixtures.Source], PipelineMode, Int, FillColor)) async throws {
        let file = try await D.export(c.1, mode: c.2, dpi: c.3, fill: c.4)
        let drawings = try PageDrawingReader.read(fileData: file)
        #expect(drawings.count == c.1.count)
        let source = try #require(SystemPageImageSource(fileData: file))
        for (index, drawing) in drawings.enumerated() {
            guard case .success(let d) = drawing else { Issue.record("page \(index + 1): \(drawing)"); continue }
            let stream = try #require(try? source.images(onPage: index).get().first)
            #expect(d.pictureSHA256 == Data(SHA256.hash(data: stream.bytes)), "page \(index + 1)")
            let walk = try D.walk(stream.bytes)
            #expect(refusal(PageDrawingReader.admit(.completed(walk), drawing: drawing)) == nil, "page \(index + 1)")
        }
    }
}
