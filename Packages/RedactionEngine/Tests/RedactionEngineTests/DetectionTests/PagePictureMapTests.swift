import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// Where a page's pictures are painted: the exact area they cover together, the
// line of four fifths, when visible text is hidden under them, and the walk of
// a page's content that reads each picture's rectangle, whether it is known to
// be opaque, and where each line of visible text starts.

@Suite("Page picture map")
struct PagePictureMapTests {
    typealias Map = PagePictureMap
    typealias R = PagePictureMap.PictureRect
    typealias S = PiecewiseScan

    static func r(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> R { R(minX: x0, minY: y0, maxX: x1, maxY: y1) }
    static let box = r(0, 0, 100, 100)

    static func map(_ crop: R = box, _ pictures: [(Int, R, Bool)] = [], starts: [(Int, Int, Int)] = []) -> Map {
        Map(cropBox: crop, pictures: pictures.map { .init(order: $0.0, rect: $0.1, hides: $0.2) },
            visibleTextStarts: starts.map { .init(order: $0.0, x: $0.1, y: $0.2) }, followed: true)
    }

    @Test("The area pictures cover together is exact, and the line is four fifths")
    func coverIsExact() {
        var rows = 0
        // U1: one rectangle equal to the crop box.
        rows += 1; #expect(Self.map(Self.box, [(1, Self.box, true)]).coversAtLeast(4, of: 5))
        // U2: two strips overlapping by 2 points count the overlap once.
        rows += 1; #expect(Map.unionArea([Self.r(0, 0, 100, 52), Self.r(0, 50, 100, 100)]) == 10_000)
        // U3: twenty-five tiles in a five-by-five grid with no gaps.
        rows += 1
        let tiles = (0..<25).map { k in Self.r(k % 5 * 20, k / 5 * 20, k % 5 * 20 + 20, k / 5 * 20 + 20) }
        #expect(Map.unionArea(tiles) == 10_000)
        #expect(Self.map(Self.box, tiles.map { (1, $0, true) }).coversAtLeast(4, of: 5))
        // U4 and U5: 3,999 and 4,000 of 5,000 square points.
        let half = Self.r(0, 0, 100, 50)
        rows += 1
        let short = [Self.r(0, 0, 79, 50), Self.r(79, 0, 80, 49)]
        #expect(Map.unionArea(short) == 3_999)
        #expect(!Self.map(half, short.map { (1, $0, true) }).coversAtLeast(4, of: 5))
        rows += 1
        #expect(Map.unionArea([Self.r(0, 0, 80, 50)]) == 4_000)
        #expect(Self.map(half, [(1, Self.r(0, 0, 80, 50), true)]).coversAtLeast(4, of: 5))
        // U6: a rectangle 0.4 points inside a 100-point crop box on every side rounds to the box.
        rows += 1
        let inside = Map.paintedRect(CGAffineTransform(a: 99.2, b: 0, c: 0, d: 99.2, tx: 0.4, ty: 0.4),
                                     crop: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(inside == Self.box && inside?.area == 10_000)
        // U7: a picture half outside the crop box: only the inside half counts.
        rows += 1
        let halfOut = Map.paintedRect(CGAffineTransform(a: 100, b: 0, c: 0, d: 100, tx: 50, ty: 0),
                                      crop: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(halfOut == Self.r(50, 0, 100, 100) && halfOut?.area == 5_000)
        // U8: a square under a 30-degree turn: its bounding box.
        rows += 1
        let c = 100 * cos(CGFloat.pi / 6), s = 100 * sin(CGFloat.pi / 6)
        let turn = CGAffineTransform(a: c, b: s, c: -s, d: c, tx: 200, ty: 200)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map { $0.applying(turn) }
        let turned = Map.paintedRect(turn, crop: CGRect(x: 0, y: 0, width: 612, height: 792))
        #expect(turned.map { t in corners.allSatisfy { t.holds(x: Int($0.x.rounded(.down)), y: Int($0.y.rounded(.down))) } } == true)
        #expect(turned.map { t in
            abs(CGFloat(t.minX) - corners.map(\.x).min()!) < 1 && abs(CGFloat(t.maxX) - corners.map(\.x).max()!) < 1
                && abs(CGFloat(t.minY) - corners.map(\.y).min()!) < 1 && abs(CGFloat(t.maxY) - corners.map(\.y).max()!) < 1
        } == true, "the bounding box of the turned square: \(String(describing: turned))")
        // U9: no picture.
        rows += 1
        #expect(Map.unionArea([]) == 0)
        #expect(!Self.map(Self.box).coversAtLeast(4, of: 5))
        // U10: a crop box 100.6 points square is 100 by 100; the line is 4 of 5.
        rows += 1
        #expect(Map.inward(CGRect(x: 0, y: 0, width: 100.6, height: 100.6)) == Self.box)
        #expect(Map.pageCoverNumerator == 4 && Map.pageCoverDenominator == 5)
        #expect(rows == 10)
    }

    @Test("Visible text is hidden only under later opaque pictures that cover the page")
    func hiddenOnlyUnderLaterCover() {
        let rows: [(String, Map, Bool)] = [
            ("A1", Self.map(Self.box, [(2, Self.box, true)], starts: [(1, 10, 10)]), true),
            ("A2", Self.map(Self.box, [(0, Self.box, true)], starts: [(1, 10, 10)]), false),
            ("A3", Self.map(Self.box, [(0, Self.box, true), (2, Self.r(0, 0, 10, 100), true)], starts: [(1, 10, 10)]), false),
            ("A4", Self.map(Self.box, [(2, Self.r(0, 0, 49, 100), true), (3, Self.r(52, 0, 100, 100), true)], starts: [(1, 50, 50)]), false),
            ("A5", Self.map(Self.box, [(2, Self.r(0, 0, 20, 20), false), (3, Self.r(20, 0, 100, 100), true)], starts: [(1, 10, 10)]), false),
            ("A6", Self.map(Self.box, [(2, Self.box, true)], starts: [(1, 10, 10), (3, 20, 20)]), true),
        ]
        #expect(rows.count == 6)
        for (key, map, hidden) in rows { #expect(map.hidesVisibleText == hidden, "\(key)") }
    }

    // MARK: - The walk

    static func read(_ content: String, resources: String = "", objects: [S.Object] = []) throws -> Map {
        let (document, page, cgPage) = try #require(S.pdfPage(S.document([S.Page(content, resources: resources, objects: objects)])))
        return withExtendedLifetime(document) { Map.read(cgPage, cropBox: page.bounds(for: .cropBox)) }
    }

    static var dot: S.Object { S.image(S.Gray(width: 2, height: 2, value: 0)) }
    static let dotNames = "/XObject << /I0 @0@ >>"
    static let inline = "BI /W 2 /H 2 /CS /G /BPC 8 /F /AHx ID 00000000> EI"

    @Test("The map holds each picture where it is painted")
    func picturesWherePainted() throws {
        let rows: [(String, Map, [R])] = [
            ("two nested transforms", try Self.read("q 2 0 0 2 10 10 cm q 50 0 0 25 5 5 cm /I0 Do Q Q", resources: Self.dotNames, objects: [Self.dot]),
             [Self.r(20, 20, 120, 70)]),
            ("inside a form with a matrix", try Self.read("/X0 Do", resources: "/XObject << /X0 @1@ >>",
                                                          objects: [Self.dot, S.form("q 30 0 0 40 0 0 cm /I0 Do Q", resources: "/XObject << /I0 @0@ >>",
                                                                                     extra: "/Matrix [1 0 0 1 100 200]")]),
             [Self.r(100, 200, 130, 240)]),
            ("an inline image", try Self.read("q 20 0 0 10 300 400 cm \(Self.inline) Q"), [Self.r(300, 400, 320, 410)]),
            ("an image drawn twice", try Self.read("q 10 0 0 10 0 0 cm /I0 Do Q q 10 0 0 10 50 50 cm /I0 Do Q", resources: Self.dotNames, objects: [Self.dot]),
             [Self.r(0, 0, 10, 10), Self.r(50, 50, 60, 60)]),
            ("an image reached and not drawn", try Self.read("0 0 10 10 re f", resources: Self.dotNames, objects: [Self.dot]), []),
            ("outside the crop box", try Self.read("q 10 0 0 10 700 900 cm /I0 Do Q", resources: Self.dotNames, objects: [Self.dot]), []),
            ("a stencil mask", try Self.read("q 8 0 0 8 1 1 cm /I0 Do Q", resources: Self.dotNames,
                                             objects: [S.Object(dictionary: "/Type /XObject /Subtype /Image /Width 8 /Height 1 /ImageMask true /BitsPerComponent 1",
                                                                stream: Data([0x55]))]),
             [Self.r(1, 1, 9, 9)]),
            ("the transform restored after Q", try Self.read("q 100 0 0 100 50 50 cm /I0 Do Q q 20 0 0 20 5 5 cm /I0 Do Q", resources: Self.dotNames, objects: [Self.dot]),
             [Self.r(50, 50, 150, 150), Self.r(5, 5, 25, 25)]),
            ("a transform scaled by 1e30", try Self.read("q 1000000000000000000000000000000.0 0 0 1000000000000000000000000000000.0 0 0 cm /I0 Do Q",
                                                         resources: Self.dotNames, objects: [Self.dot]),
             [Self.r(0, 0, 612, 792)]),
        ]
        #expect(rows.count == 9)
        for (key, map, rects) in rows {
            #expect(map.pictures.map(\.rect) == rects, "\(key): \(map.pictures)")
            #expect(map.followed, "\(key): followed")
        }
    }

    @Test("A picture hides text only when it is known to be opaque")
    func hidesOnlyWhenOpaque() throws {
        func image(_ extra: String = "", gs: String? = nil, before: String = "", objects: [S.Object] = []) throws -> Bool? {
            let gsNames = gs.map { _ in "/ExtGState << /G0 @1@ >>" } ?? ""
            let gsObjects = gs.map { [S.Object(dictionary: "/Type /ExtGState \($0)")] } ?? []
            let map = try Self.read(before + "q 10 0 0 10 0 0 cm /I0 Do Q", resources: Self.dotNames + " " + gsNames,
                                    objects: [S.image(S.Gray(width: 2, height: 2, value: 0), extra: extra)] + gsObjects + objects)
            return map.pictures.first?.hides
        }
        let rows: [(String, Bool?, Bool)] = [
            ("a plain image", try image(), true),
            ("a soft mask", try image("/SMask @1@", objects: [S.image(S.Gray(width: 2, height: 2, value: 128))]), false),
            ("a colour-key mask", try image("/Mask [0 10]"), false),
            ("a stencil mask", try image("/ImageMask true"), false),
            ("alpha in its data", try image("/SMaskInData 1"), false),
            ("an alpha of 0.3", try image(gs: "/ca 0.3", before: "/G0 gs "), false),
            ("a multiply blend", try image(gs: "/BM /Multiply", before: "/G0 gs "), false),
            ("a compatible blend", try image(gs: "/BM /Compatible", before: "/G0 gs "), true),
            ("a graphics state that cannot be read", try image(before: "/G9 gs "), true),
            ("an alpha of 0.3 restored by Q", try image(gs: "/ca 0.3", before: "q /G0 gs Q "), true),
        ]
        #expect(rows.count == 10)
        for (key, hides, expected) in rows { #expect(hides == expected, "\(key)") }
    }

    @Test("Where a line of text starts")
    func whereTextStarts() throws {
        let rows: [(String, String, [[Int]])] = [
            ("a move after BT", "BT /F1 12 Tf 100 200 Td (a) Tj ET", [[100, 200]]),
            ("a text matrix", "BT /F1 12 Tf 1 0 0 1 50 60 Tm (a) Tj ET", [[50, 60]]),
            ("a move that sets the leading, then the next line", "BT /F1 12 Tf 10 700 Td 0 -14 TD (a) Tj T* (b) Tj ET", [[10, 686], [10, 672]]),
            ("a quote with a leading set in an earlier text object", "BT 12 TL ET BT /F1 12 Tf 20 300 Td (x) ' ET", [[20, 288]]),
            ("invisible text, and a mode restored by Q", "3 Tr BT /F1 12 Tf 5 5 Td (a) Tj ET 0 Tr q 3 Tr Q BT /F1 12 Tf 7 7 Td (b) Tj ET", [[7, 7]]),
        ]
        #expect(rows.count == 5)
        for (key, content, starts) in rows {
            let map = try Self.read(content)
            #expect(map.visibleTextStarts.map { [$0.x, $0.y] } == starts, "\(key): \(map.visibleTextStarts)")
        }
    }

    @Test("Painting that cannot be followed is said so")
    func unfollowedIsSaid() throws {
        func forms(_ count: Int) throws -> Map {
            var objects = [Self.dot]
            for k in 1...count {
                objects.append(k < count ? S.form("/F\(k + 1) Do", resources: "/XObject << /F\(k + 1) @\(k + 1)@ >>")
                                         : S.form("q 10 0 0 10 0 0 cm /I0 Do Q", resources: Self.dotNames))
            }
            return try Self.read("/F1 Do", resources: "/XObject << /F1 @1@ >>", objects: objects)
        }
        let pictures = { (n: Int) in String(repeating: "q 1 0 0 1 0 0 cm /I0 Do Q ", count: n) }
        let rows: [(String, Map)] = [
            ("a tiling pattern holding an image", try Self.read("/Pattern cs /T1 scn 0 0 10 10 re f", resources: "/Pattern << /T1 @1@ >>",
                objects: [Self.dot, S.Object(dictionary: "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << /XObject << /I0 @0@ >> >>",
                                             stream: Data("q 10 0 0 10 0 0 cm /I0 Do Q".utf8))])),
            ("a tiling pattern drawing an inline image", try Self.read("/Pattern cs /T1 scn 0 0 10 10 re f", resources: "/Pattern << /T1 @0@ >>",
                objects: [S.Object(dictionary: "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << >>",
                                   stream: Data("q 10 0 0 10 0 0 cm \(Self.inline) Q".utf8))])),
            ("nine forms deep", try forms(9)),
            ("4,097 pictures", try Self.read(pictures(4_097), resources: Self.dotNames, objects: [Self.dot])),
        ]
        // A stream the scanner reports it could not read is not followed as
        // well; no made page gives one, so no row holds it.
        #expect(rows.count == 4)
        for (key, map) in rows { #expect(!map.followed, "\(key)") }
        #expect(try forms(8).followed, "eight forms deep are followed")
        #expect(try Self.read(pictures(4_096), resources: Self.dotNames, objects: [Self.dot]).followed, "4,096 pictures are followed")
        #expect(Map.pictureLimit == 4_096)
    }

    /// Forms seven deep, each drawing the next `times` times, the last drawing
    /// `last`: 1 + times + … + times⁶ forms drawn.
    static func formTree(times: Int, last: String, objects base: [S.Object] = [], names: String = "") -> (String, [S.Object]) {
        var objects = base
        let first = objects.count
        for k in 0..<7 {
            let next = first + k + 1
            objects.append(k < 6 ? S.form(String(repeating: "/F Do ", count: times), resources: "/XObject << /F @\(next)@ >>")
                                 : S.form(last, resources: names))
        }
        return ("/F Do", objects)
    }

    @Test("Forms that draw each other many times are walked in bounded time, and not followed")
    func formsDrawnManyTimes() throws {
        let clock = ContinuousClock()
        // Three times at each level: 1,093 forms drawn, past the limit; ten
        // times would be 1,111,111 without it.
        let small = Self.formTree(times: 2, last: "q 1 0 0 1 0 0 cm /I0 Do Q", objects: [Self.dot], names: Self.dotNames)
        #expect(try Self.read(small.0, resources: "/XObject << /F @1@ >>", objects: small.1).followed, "127 forms drawn are followed")
        let (content, objects) = Self.formTree(times: 3, last: "q 1 0 0 1 0 0 cm /I0 Do Q", objects: [Self.dot], names: Self.dotNames)
        var map: Map?
        let took = try clock.measure {
            map = try Self.read(content, resources: "/XObject << /F @1@ >>", objects: objects)
        }
        #expect(map?.followed == false, "more than \(Map.formLimit) forms drawn: not followed")
        #expect(took < .seconds(10), "the walk took \(took)")
        // On a page with invisible text, a painting not followed is fitted.
        let page = S.document([S.Page(content + " " + S.text(mode: 3), resources: "/XObject << /F @1@ >>", objects: objects)])
        let (document, pdfPage, cgPage) = try #require(S.pdfPage(page))
        let start = clock.now
        #expect(DocumentSearcher.carriesHiddenTextOverImage(pdfPage, cgPage: cgPage), "fitted")
        #expect(clock.now - start < .seconds(10), "the gate took \(clock.now - start)")
        withExtendedLifetime(document) {}
        // A form drawing itself is not followed.
        let selfDrawing = try Self.read("/F Do", resources: "/XObject << /F @0@ >>",
                                        objects: [S.form("/F Do", resources: "/XObject << /F @0@ >>")])
        #expect(!selfDrawing.followed, "a form drawing itself")
        #expect(Map.formLimit == 1_024)
    }

    @Test("A pattern's forms are each looked into once")
    func patternFormsLookedIntoOnce() throws {
        // Seven levels, each naming the next form four times: 21,844 paths,
        // seven forms.
        func pattern(last: String, names: String, objects base: [S.Object]) throws -> (Map, Duration, Int) {
            var objects = base
            let first = objects.count
            for k in 0..<7 {
                let next = first + k + 1
                let many = (0..<4).map { "/F\($0) @\(next)@" }.joined(separator: " ")
                objects.append(k < 6 ? S.form("", resources: "/XObject << \(many) >>") : S.form(last, resources: names))
            }
            let cell = objects.count
            objects.append(S.Object(dictionary: "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << /XObject << /F @\(first)@ >> >>",
                                    stream: Data("/F Do".utf8)))
            let data = S.document([S.Page("/Pattern cs /T1 scn 0 0 10 10 re f", resources: "/Pattern << /T1 @\(cell)@ >>", objects: objects)])
            let (document, page, cgPage) = try #require(S.pdfPage(data))
            defer { withExtendedLifetime(document) {} }
            var map: Map?
            let took = ContinuousClock().measure { map = Map.read(cgPage, cropBox: page.bounds(for: .cropBox)) }
            // The pattern's own resources, as the walk reads them.
            let pageDictionary = try #require(cgPage.dictionary)
            var resources: CGPDFDictionaryRef?, patterns: CGPDFDictionaryRef?, cellStream: CGPDFStreamRef?, cellResources: CGPDFDictionaryRef?
            try #require(CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources) && resources != nil)
            try #require(CGPDFDictionaryGetDictionary(resources!, "Pattern", &patterns) && patterns != nil)
            try #require(CGPDFDictionaryGetStream(patterns!, "T1", &cellStream) && cellStream != nil)
            let cellDictionary = try #require(CGPDFStreamGetDictionary(cellStream!))
            try #require(CGPDFDictionaryGetDictionary(cellDictionary, "Resources", &cellResources) && cellResources != nil)
            let seen = PictureWalk.FormsSeen()
            let content = CGPDFContentStreamCreateWithPage(cgPage)
            defer { CGPDFContentStreamRelease(content) }
            _ = PictureWalk.reachesPicture(cellResources!, content: content, depth: 0, seen: seen)
            return (try #require(map), took, seen.looked)
        }
        let (plain, plainTook, plainLooked) = try pattern(last: "0 0 1 1 re f", names: "", objects: [])
        #expect(plain.followed, "no picture is reached: followed")
        #expect(plainLooked == 7, "each of the seven forms looked into once, not \(plainLooked) times")
        #expect(plainTook < .seconds(10), "took \(plainTook)")
        let (picture, pictureTook, _) = try pattern(last: "/I0 Do", names: Self.dotNames, objects: [Self.dot])
        #expect(!picture.followed, "a picture is reached: not followed")
        #expect(pictureTook < .seconds(10), "took \(pictureTook)")
    }

    @Test("More lines of visible text than the limit and the painting is not followed")
    func textStartsAreBounded() throws {
        let shows = { (n: Int) in "BT " + String(repeating: "(a) Tj ", count: n) + "ET" }
        let atLimit = try Self.read(shows(16_384))
        #expect(atLimit.followed && atLimit.visibleTextStarts.count == 16_384, "16,384 starts are followed")
        let past = try Self.read(shows(16_385))
        #expect(!past.followed, "16,385 starts: not followed")
        #expect(past.visibleTextStarts.count == 16_384, "and no start past the limit is kept")
        // A form drawn 64 times (two at each of six levels) adds its starts
        // each time: 64 x 200 is within the limit, 64 x 300 is past it.
        for (each, followed) in [(200, true), (300, false)] {
            let (content, objects) = Self.formTree(times: 2, last: shows(each))
            let map = try Self.read(content, resources: "/XObject << /F @0@ >>", objects: objects)
            #expect(map.followed == followed, "64 draws of \(each) starts")
            #expect(map.visibleTextStarts.count <= Map.textStartLimit)
        }
        #expect(Map.textStartLimit == 16_384)
    }

    @Test("More operators than the limit on one page and the painting is not followed")
    func operatorsAreBounded() throws {
        // BT and each T* are read: 1 + 999,999 is the limit.
        let moves = { (n: Int) in "BT " + String(repeating: "T* ", count: n) + "ET" }
        #expect(try Self.read(moves(999_999)).followed, "1,000,000 operators are followed")
        #expect(try !Self.read(moves(1_000_000)).followed, "1,000,001: not followed")
        #expect(Map.operationLimit == 1_000_000)
    }

    @Test("Each pattern stream is read once however many names it has, and the patterns share one record of forms")
    func patternStreamsReadOnce() throws {
        // Seven forms, each naming the next four times; three pattern cells
        // that reach the first, one of them under 10,000 names.
        var objects: [S.Object] = []
        for k in 0..<7 {
            let many = (0..<4).map { "/F\($0) @\(k + 1)@" }.joined(separator: " ")
            objects.append(k < 6 ? S.form("", resources: "/XObject << \(many) >>") : S.form("0 0 1 1 re f", resources: ""))
        }
        let cell = { S.Object(dictionary: "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << /XObject << /F @0@ >> >>",
                              stream: Data("/F Do".utf8)) }
        let first = objects.count
        objects += [cell(), cell(), cell()]
        let names = (0..<10_000).map { "/P\($0) @\(first)@" }.joined(separator: " ") + " /Q1 @\(first + 1)@ /Q2 @\(first + 2)@"
        let data = S.document([S.Page("/Pattern cs /P0 scn 0 0 10 10 re f", resources: "/Pattern << \(names) >>", objects: objects)])
        let (document, _, cgPage) = try #require(S.pdfPage(data))
        defer { withExtendedLifetime(document) {} }
        let seen = PictureWalk.FormsSeen()
        let clock = ContinuousClock()
        let start = clock.now
        #expect(!PictureWalk.patternsHoldPicture(cgPage, seen: seen), "no picture is reached")
        #expect(clock.now - start < .seconds(10), "took \(clock.now - start)")
        #expect(seen.patternsRead == 3, "three streams read once each, not \(seen.patternsRead) times")
        #expect(seen.looked == 7, "the seven forms looked into once over the page, not \(seen.looked) times")
    }

    @Test("More pattern names than the limit and a picture is taken to be held")
    func patternNamesAreBounded() throws {
        let cell = S.Object(dictionary: "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << >>",
                            stream: Data("0 0 1 1 re f".utf8))
        for (count, held) in [(65_536, false), (65_537, true)] {
            let names = (0..<count).map { "/P\($0) @0@" }.joined(separator: " ")
            let data = S.document([S.Page("0 0 1 1 re f", resources: "/Pattern << \(names) >>", objects: [cell])])
            let (document, _, cgPage) = try #require(S.pdfPage(data))
            #expect(PictureWalk.patternsHoldPicture(cgPage) == held, "\(count) names")
            withExtendedLifetime(document) {}
        }
        #expect(Map.entryLimit == 65_536)
    }

    @Test("A picture held deeper in a pattern leaves the painting not followed, and the page's patterns hold it")
    func nestedPatternPictures() throws {
        typealias C = PageImageCensusPiecesTests
        for nested in C.Nested.allCases {
            for picture in [true, false] {
                let (document, page, cgPage) = try #require(S.pdfPage(C.letterWithNestedPattern(nested, picture: picture)))
                defer { withExtendedLifetime(document) {} }
                let map = Map.read(cgPage, cropBox: page.bounds(for: .cropBox))
                #expect(map.followed == !picture, "\(nested), picture \(picture): followed")
                #expect(PictureWalk.patternsHoldPicture(cgPage) == picture, "\(nested), picture \(picture): held")
            }
        }
    }

    @Test("Forms that draw each other many times are read for invisible text in bounded time, and answer true")
    func invisibleTextFormsBounded() throws {
        let clock = ContinuousClock()
        for (times, answer) in [(2, false), (3, true)] {
            // 127 forms drawn, then 1,093: past the limit.
            let (content, objects) = Self.formTree(times: times, last: "BT (a) Tj ET")
            let data = S.document([S.Page(content, resources: "/XObject << /F @0@ >>", objects: objects)])
            let (document, _, cgPage) = try #require(S.pdfPage(data))
            let start = clock.now
            #expect(DocumentSearcher.showsInvisibleText(cgPage) == answer, "\(times) draws at each level")
            #expect(DocumentSearcher.invisibleTextReading(cgPage) == (answer ? .unreadable : .showsNone),
                    "\(times) draws at each level: past the limit reads unreadable")
            #expect(clock.now - start < .seconds(10), "took \(clock.now - start)")
            withExtendedLifetime(document) {}
        }
    }

    @Test("A crop box beyond any page is read without leaving an Int")
    func cropBoxOutOfRange() throws {
        let (document, _, cgPage) = try #require(S.pdfPage(S.document([S.Page("q 10 0 0 10 0 0 cm /I0 Do Q", resources: Self.dotNames, objects: [Self.dot])])))
        defer { withExtendedLifetime(document) {} }
        let l = Int(Map.coordinateLimit)
        let rows: [(String, CGRect, R?)] = [
            ("reaching past both ends", CGRect(x: -1e19, y: -1e19, width: 2e19, height: 2e19), Self.r(-l, -l, l, l)),
            ("1e30 wide", CGRect(x: 0, y: 0, width: 1e30, height: 100), Self.r(0, 0, l, 100)),
            ("wholly past the limit", CGRect(x: 1e19, y: 1e19, width: 100, height: 100), nil),
        ]
        for (key, crop, expected) in rows {
            #expect(Map.inward(Map.limited(crop)) == expected, "\(key)")
            let map = Map.read(cgPage, cropBox: crop)
            #expect(!map.coversThePage || expected == nil, "\(key): a 10-point picture does not cover \(map.cropBox)")
        }
        #expect(Map.inward(CGRect(x: -1e30, y: 0, width: 2e30, height: 100)) == Self.r(-l, 0, l, 100), "rounded within the limit")
        #expect(Map.coordinateLimit == 0x1p28)
    }

    // MARK: - A pattern cell names what it draws

    /// A tiling pattern whose cell runs `cell`, with `/Resources` as given
    /// (none when nil), a 10-point tile.
    static func cellPattern(_ cell: String, resources: String?) -> S.Object {
        S.Object(dictionary: "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10"
                    + (resources.map { " /Resources << \($0) >>" } ?? ""),
                 stream: Data(cell.utf8))
    }

    /// A page that names a small black image `/I0` and fills a square with a
    /// pattern whose cell draws `/I0` by name.
    static func pageDrawingI0ThroughACell(resources: String?, fill: String = "0 0 10 10", extra: [S.Object] = []) -> Data {
        S.document([S.Page("/Pattern cs /P0 scn \(fill) re f", resources: "/XObject << /I0 @0@ >> /Pattern << /P0 @1@ >>",
                           objects: [dot, cellPattern("q 10 0 0 10 0 0 cm /I0 Do Q", resources: resources)] + extra)])
    }

    @Test("A pattern cell that draws an object its own resources do not name cannot be followed")
    func cellNamesWhatItDraws() throws {
        let cases: [(String, Data, Bool)] = [
            ("no /Resources", Self.pageDrawingI0ThroughACell(resources: nil), true),
            ("empty /Resources", Self.pageDrawingI0ThroughACell(resources: ""), true),
            ("/Resources naming a font only", Self.pageDrawingI0ThroughACell(resources: "/Font << >>"), true),
            ("/Resources naming another object", Self.pageDrawingI0ThroughACell(resources: "/XObject << /F0 @2@ >>",
                                                                                extra: [S.form("0 0 1 1 re f", resources: "")]), true),
            ("no /Resources, paths only", S.document([S.Page("/Pattern cs /P0 scn 0 0 10 10 re f", resources: "/XObject << /I0 @0@ >> /Pattern << /P0 @1@ >>",
                                                             objects: [Self.dot, Self.cellPattern("0 0 5 5 re f", resources: nil)])]), false),
            ("a form its own /Resources name, paths only", S.document([S.Page("/Pattern cs /P0 scn 0 0 10 10 re f", resources: "/Pattern << /P0 @1@ >>",
                                                             objects: [S.form("0 0 1 1 re f", resources: ""), Self.cellPattern("/F Do", resources: "/XObject << /F @0@ >>")])]), false),
        ]
        for (name, data, held) in cases {
            let (document, page, cgPage) = try #require(S.pdfPage(data))
            defer { withExtendedLifetime(document) {} }
            #expect(PictureWalk.patternsHoldPicture(cgPage) == held, "\(name): held")
            #expect(Map.read(cgPage, cropBox: page.bounds(for: .cropBox)).followed == !held, "\(name): followed")
        }
    }

    /// The darkest of 25 points over a page whose whole media box is filled
    /// with the pattern, drawn by Core Graphics on white.
    static func darkestDrawn(_ data: Data) throws -> UInt8 {
        let (document, _, cgPage) = try #require(S.pdfPage(data))
        defer { withExtendedLifetime(document) {} }
        let box = cgPage.getBoxRect(.mediaBox)
        let side = 100
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.scaleBy(x: CGFloat(side) / box.width, y: CGFloat(side) / box.height)
        context.drawPDFPage(cgPage)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var darkest: UInt8 = 255
        for y in stride(from: 10, to: side, by: 20) { for x in stride(from: 10, to: side, by: 20) { darkest = min(darkest, pixels[y * side + x]) } }
        return darkest
    }

    /// The platform fact the rule above was weighed against: Core Graphics
    /// draws nothing for a cell's `Do` that its own resources do not name,
    /// though the page names it. The rule does not rest on it (another reader
    /// may draw it), but a change here is worth knowing.
    @Test("Core Graphics draws a cell's object only when the cell's own resources name it")
    func coreGraphicsDrawsOnlyNamedCellObjects() throws {
        let fill = "0 0 612 792"
        #expect(try Self.darkestDrawn(Self.pageDrawingI0ThroughACell(resources: "/XObject << /I0 @0@ >>", fill: fill)) < 128, "named: drawn")
        for resources in [nil, "", "/Font << >>"] as [String?] {
            #expect(try Self.darkestDrawn(Self.pageDrawingI0ThroughACell(resources: resources, fill: fill)) > 128, "\(resources ?? "none"): not drawn")
        }
    }

    // MARK: - The walk's limits

    @Test("Forms nested deeper than the limit in a page's resources are taken to hold a picture")
    func resourceFormDepthIsBounded() throws {
        for (count, held) in [(PageImageCensus.maxFormDepth - 1, false), (PageImageCensus.maxFormDepth, true)] {
            // Form k names form k + 1 in its resources; none is drawn, none holds a pattern.
            let objects = (0..<count).map { k in S.form("0 0 1 1 re f", resources: k + 1 < count ? "/XObject << /F @\(k + 1)@ >>" : "") }
            let data = S.document([S.Page("0 0 1 1 re f", resources: "/XObject << /F @0@ >>", objects: objects)])
            let (document, _, cgPage) = try #require(S.pdfPage(data))
            defer { withExtendedLifetime(document) {} }
            #expect(PictureWalk.patternsHoldPicture(cgPage) == held, "\(count) forms deep")
        }
        #expect(PageImageCensus.maxFormDepth == 8)
    }

    @Test("More forms than the limit in a page's resources are taken to hold a picture")
    func resourceFormsAreBounded() throws {
        for (count, held) in [(Map.formLimit, false), (Map.formLimit + 1, true)] {
            let objects = (0..<count).map { _ in S.form("0 0 1 1 re f", resources: "") }
            let names = (0..<count).map { "/F\($0) @\($0)@" }.joined(separator: " ")
            let data = S.document([S.Page("0 0 1 1 re f", resources: "/XObject << \(names) >>", objects: objects)])
            let (document, _, cgPage) = try #require(S.pdfPage(data))
            defer { withExtendedLifetime(document) {} }
            #expect(PictureWalk.patternsHoldPicture(cgPage) == held, "\(count) forms")
        }
        #expect(Map.formLimit == 1_024)
    }

    @Test("More pattern streams read than the limit are taken to hold a picture")
    func patternsReadAreBounded() throws {
        for (count, held) in [(Map.formLimit, false), (Map.formLimit + 1, true)] {
            let objects = (0..<count).map { _ in Self.cellPattern("0 0 5 5 re f", resources: "") }
            let names = (0..<count).map { "/P\($0) @\($0)@" }.joined(separator: " ")
            let data = S.document([S.Page("0 0 1 1 re f", resources: "/Pattern << \(names) >>", objects: objects)])
            let (document, _, cgPage) = try #require(S.pdfPage(data))
            defer { withExtendedLifetime(document) {} }
            #expect(PictureWalk.patternsHoldPicture(cgPage) == held, "\(count) patterns")
        }
    }

    @Test("Patterns nested deeper than the limit are taken to hold a picture")
    func patternDepthIsBounded() throws {
        for (count, held) in [(PageImageCensus.maxFormDepth, false), (PageImageCensus.maxFormDepth + 1, true)] {
            // Pattern k fills with pattern k + 1; the last has no resources and paints a path.
            let objects = (0..<count).map { k in
                k + 1 < count ? Self.cellPattern("/Pattern cs /Q scn 0 0 10 10 re f", resources: "/Pattern << /Q @\(k + 1)@ >>")
                    : Self.cellPattern("0 0 5 5 re f", resources: nil)
            }
            let data = S.document([S.Page("0 0 1 1 re f", resources: "/Pattern << /P0 @0@ >>", objects: objects)])
            let (document, _, cgPage) = try #require(S.pdfPage(data))
            defer { withExtendedLifetime(document) {} }
            #expect(PictureWalk.patternsHoldPicture(cgPage) == held, "\(count) patterns deep")
        }
    }
}
