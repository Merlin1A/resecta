import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The census on scans stored as many small pictures: when no single picture
// passes the floors and the text layer is not thin, a page whose pictures, as
// painted, cover four fifths of the crop box, or whose painting cannot be
// followed, carries image content. Where pictures are painted is read only for
// a page that reaches an image object, draws an inline image or shows
// invisible text, and the answer is kept while the page lives.
//
// Privacy rule (audit-lint M-1): locate/read/report vocabulary.

@Suite("Page image census: scans stored in pieces", .serialized, .tags(.search))
struct PageImageCensusPiecesTests {
    typealias S = PiecewiseScan

    struct Row {
        let name: String
        let data: Data
        let carries: Bool
    }

    // MARK: - Pages

    /// The builder's filler lines, shown in the visible mode.
    static var visibleFiller: String { S.fillerLayer.replacingOccurrences(of: " 3 Tr ", with: " 0 Tr ") }

    /// A scan stored as `pieces` under a text layer too long to read as a stamp:
    /// the three lines and the filler, invisible over the pictures or visible
    /// before them.
    static func fullScan(_ pieces: S.Pieces, dpi: CGFloat = 300, layer: S.Layer = .invisible) -> Data {
        var page = S.scanPage(pieces, dpi: dpi, shift: 0, layer: layer)
        if layer == .invisible {
            page.content.append(Data(S.fillerLayer.utf8))
        } else {
            page.content = Data(visibleFiller.utf8) + page.content
        }
        return S.document([page])
    }

    /// A 600 × 800 pt page whose one small picture is drawn over its top
    /// `height` points, in whole points, under the full text layer.
    static func coverPage(height: CGFloat) -> Data {
        var page = S.Page(S.picture(0, at: CGRect(x: 0, y: 800 - height, width: 600, height: height))
                          + S.text(mode: 3) + S.fillerLayer,
                          resources: "/XObject << /P0 @0@ >>", objects: [S.image(S.shade(width: 100, height: 100))])
        page.size = CGSize(width: 600, height: 800)
        return S.document([page])
    }

    /// A typed letter with no picture.
    static func typedLetter() -> Data { S.document([S.Page(S.typedText + visibleFiller)]) }

    /// A short page (the three lines, invisible) that draws one small inline logo.
    static func shortPageWithInlineLogo() -> Data {
        let d = S.draw(S.shade(width: 60, height: 30), dpi: 300, .inlineStrips(rows: 30))
        return S.document([S.Page(d.ops + S.text(mode: 3))])
    }

    /// A typed letter whose fill is set to a tiling pattern that holds a
    /// picture; with `logo`, it also draws a small logo as an image object.
    static func letterWithPatternFill(logo: Bool) -> Data {
        let tile = S.image(S.shade(width: 200, height: 100))
        let pattern = S.Object(dictionary: "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 200 100] /XStep 200 /YStep 100 /Resources << /XObject << /Im @1@ >> >>",
                               stream: Data("q 200 0 0 100 0 0 cm /Im Do Q".utf8))
        let fill = "q /Pattern cs /T1 scn 300 720 200 50 re f Q "
        let mark = logo ? S.picture(0, at: CGRect(x: 72, y: 720, width: 120, height: 60)) : ""
        let resources = (logo ? "/XObject << /P0 @0@ >> " : "") + "/Pattern << /T1 @2@ >>"
        return S.document([S.Page(mark + fill + S.typedText + visibleFiller, resources: resources,
                                  objects: [S.image(S.shade(width: 120, height: 60)), tile, pattern])])
    }

    static func carries(_ data: Data) throws -> Bool {
        let (_, page, _) = try #require(S.pdfPage(data))
        return PageImageCensus.carriesImageContent(page)
    }

    static func check(_ rows: [Row]) throws {
        for row in rows {
            #expect(try carries(row.data) == row.carries, "\(row.name)")
        }
    }

    // MARK: - The rows

    @Test("Scans stored in pieces under a full text layer carry image content")
    func newlyTaken() throws {
        try Self.check([
            Row(name: "C1 strips of 96 rows at 300 dpi", data: Self.fullScan(.strips(rows: 96)), carries: true),
            Row(name: "C2 strips of 98 rows at 300 dpi, the last count under the floor", data: Self.fullScan(.strips(rows: 98)), carries: true),
            Row(name: "C4 strips of 150 rows at 150 dpi", data: Self.fullScan(.strips(rows: 150), dpi: 150), carries: true),
            Row(name: "C5 tiles of 200 px", data: Self.fullScan(.tiles(200)), carries: true),
            Row(name: "C6 strips stored turned", data: Self.fullScan(.turnedStrips(rows: 96)), carries: true),
            Row(name: "C7 inline strips, no image object, visible text before them", data: Self.fullScan(.inlineStrips(rows: 96), layer: .visibleBefore), carries: true),
            Row(name: "C8 visible text before strips that hide it", data: Self.fullScan(.strips(rows: 96), layer: .visibleBefore), carries: true),
            Row(name: "C12 pictures over exactly four fifths of the crop box", data: Self.coverPage(height: 640), carries: true),
        ])
    }

    @Test("Pages the old terms decide, and pages under the line, keep their answer")
    func unchanged() throws {
        try Self.check([
            Row(name: "C0 strips under the builder's three lines alone (a thin layer)", data: S.scan(.strips(rows: 96), shift: 0), carries: true),
            Row(name: "C3 strips of 99 rows, over the pixel floor", data: Self.fullScan(.strips(rows: 99)), carries: true),
            Row(name: "C9 one page-scale picture", data: Self.fullScan(.one), carries: true),
            Row(name: "C10 a short title page", data: TestFixtures.shortTitlePagePDF(), carries: false),
            Row(name: "C10 a typed letter", data: Self.typedLetter(), carries: false),
            Row(name: "C11 a letter with a letterhead logo", data: TestFixtures.letterWithImagePDF(width: 600, height: 300), carries: false),
            Row(name: "C13 pictures over four fifths less one row of points", data: Self.coverPage(height: 639), carries: false),
            Row(name: "C16 a short page that draws one small inline logo", data: Self.shortPageWithInlineLogo(), carries: false),
            Row(name: "C18 a typed letter whose only picture is inside a pattern", data: Self.letterWithPatternFill(logo: false), carries: false),
        ])
    }

    @Test("A page whose painting cannot be followed carries image content")
    func notFollowed() throws {
        try Self.check([
            Row(name: "C14 tiles of 40 px, more pictures than the map follows", data: Self.fullScan(.tiles(40)), carries: true),
            Row(name: "C17 a letter with a logo and a fill set to a pattern that holds a picture", data: Self.letterWithPatternFill(logo: true), carries: true),
            Row(name: "C19 a scan printed inside a pattern, under invisible text", data: InkFitPiecewiseScanTests.patternScan(), carries: true),
        ])
    }

    // MARK: - Read only when needed, and kept

    @Test("Where pictures are painted is read only for a page the old terms do not decide")
    func mapReadOnlyWhenNeeded() throws {
        let cases: [(String, Data, Bool)] = [
            ("C3 strips of 99 rows", Self.fullScan(.strips(rows: 99)), false),
            ("C9 one page-scale picture", Self.fullScan(.one), false),
            ("C10 a typed letter", Self.typedLetter(), false),
            ("C1 strips of 96 rows", Self.fullScan(.strips(rows: 96)), true),
            ("C11 a letter with a letterhead logo", TestFixtures.letterWithImagePDF(width: 600, height: 300), true),
        ]
        for (name, data, read) in cases {
            let (_, page, _) = try #require(S.pdfPage(data))
            _ = PageImageCensus.carriesImageContent(page)
            #expect((PagePictureMapCache.shared.value(for: page) != nil) == read, "\(name)")
        }
    }

    /// A measurement, never in the gate (RESECTA_PIECES_TIMING=1, from an
    /// optimised build): the census read afresh on a typed letter, a letter
    /// with a letterhead logo and a scan in strips, 50 new documents each.
    @Test("The census's reading time on typed pages and on a scan in strips",
          .enabled(if: ProcessInfo.processInfo.environment["RESECTA_PIECES_TIMING"] == "1"))
    func readingTime() throws {
        let pages: [(String, Data)] = [
            ("typed letter", Self.typedLetter()),
            ("letter with a letterhead logo", TestFixtures.letterWithImagePDF(width: 600, height: 300)),
            ("strips of 96 rows", Self.fullScan(.strips(rows: 96))),
        ]
        for (name, data) in pages {
            var times: [Double] = []
            for _ in 0..<50 {
                let (_, page, _) = try #require(S.pdfPage(data))
                let start = DispatchTime.now().uptimeNanoseconds
                _ = PageImageCensus.readCarriesImageContent(page)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            times.sort()
            print(String(format: "CENSUS-TIMING %@: median %.3f ms, largest %.3f ms (50 pages)", name, times[25], times[49]))
        }
    }

    @Test("The census returns the answer it keeps for the page")
    func keptAnswer() throws {
        let (_, typed, _) = try #require(S.pdfPage(Self.typedLetter()))
        PageImageCensusCache.shared.set(true, for: typed)
        #expect(PageImageCensus.carriesImageContent(typed), "the kept answer, not a new reading")
        let (_, strips, _) = try #require(S.pdfPage(Self.fullScan(.strips(rows: 96))))
        #expect(PageImageCensus.carriesImageContent(strips))
        #expect(PageImageCensusCache.shared.value(for: strips) == true)
        #expect(PageImageCensus.carriesImageContent(strips))
    }
}
