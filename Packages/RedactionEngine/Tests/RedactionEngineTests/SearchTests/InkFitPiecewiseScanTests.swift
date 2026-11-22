import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// The ink fit on scans stored in pieces (strips, tiles, inline images) and on
// pages whose visible text lies under pictures painted after it: such a page is
// fitted as a one-picture scan is, and a typed page is not. Each row's expected
// side was written before the code, from the rule: the fit runs on a page when
// it shows text in an invisible mode and its print is a picture (its largest
// image is page-scale, or its pictures as painted cover four fifths of the page,
// or its painting cannot be followed), or when text it shows in a visible mode
// starts inside an opaque picture painted after it and the opaque pictures
// painted after it cover four fifths of the page.
//
// Privacy rule (audit-lint M-1): locate/read/report vocabulary.

@Suite("Ink fit on scans stored in pieces", .serialized, .tags(.search))
struct InkFitPiecewiseScanTests {
    typealias S = PiecewiseScan
    static let half = S.halfWord
    static let full = CGRect(x: 0, y: 0, width: 612, height: 792)

    // MARK: - Pages

    struct Row {
        var key: String
        var pages: [Data]
        var fitted: Bool
    }

    static func typed(_ content: String, pictures: [S.Gray] = [], extra: [S.Object] = [], resources: String = "") -> Data {
        let objects = pictures.map { S.image($0) } + extra
        let names = pictures.indices.map { "/P\($0) @\($0)@" }.joined(separator: " ")
        let xobjects = names.isEmpty ? "" : "/XObject << \(names) >> "
        return S.document([S.Page(content, resources: xobjects + resources, objects: objects)])
    }

    /// A tiling pattern whose cell is the page's print, filling the page.
    static func patternScan() -> Data {
        let print = S.image(S.print(dpi: 300, shift: half))
        let pattern = S.Object(dictionary: "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 612 792] /XStep 612 /YStep 792 /Resources << /XObject << /Im @0@ >> >>",
                               stream: Data("q 612 0 0 792 0 0 cm /Im Do Q".utf8))
        return S.document([S.Page("q /Pattern cs /T1 scn 0 0 612 792 re f Q " + S.text(mode: 3),
                                  resources: "/Pattern << /T1 @1@ >>", objects: [print, pattern])])
    }

    /// The print drawn nine forms deep, one form inside the next.
    static func deepScan(forms: Int = 9) -> Data {
        var objects = [S.image(S.print(dpi: 300, shift: half))]
        for k in 1...forms {
            objects.append(k < forms
                ? S.form("/F\(k + 1) Do", resources: "/XObject << /F\(k + 1) @\(k + 1)@ >>")
                : S.form("q 612 0 0 792 0 0 cm /Im Do Q", resources: "/XObject << /Im @0@ >>"))
        }
        return S.document([S.Page("/F1 Do " + S.text(mode: 3), resources: "/XObject << /F1 @1@ >>", objects: objects)])
    }

    static func gateRows() -> [Row] {
        let page = S.shade(width: 850, height: 1100, light: true)
        let photos = [CGRect(x: 60, y: 420, width: 220, height: 220), CGRect(x: 332, y: 420, width: 220, height: 220),
                      CGRect(x: 60, y: 120, width: 220, height: 220), CGRect(x: 332, y: 120, width: 220, height: 220)]
        let unread = (0..<30).map { k in S.image(S.shade(width: 2550, height: 128, light: k % 2 == 0)) }
        let unreadNames = unread.indices.map { "/U\($0) @\($0)@" }.joined(separator: " ")
        return [
            Row(key: "G1", pages: [S.scan(.strips(rows: 128), shift: 0)], fitted: true),
            Row(key: "G2", pages: [S.scan(.strips(rows: 128), shift: half)], fitted: true),
            Row(key: "G3", pages: [S.scan(.tiles(512), shift: half)], fitted: true),
            Row(key: "G4", pages: [S.scan(.inlineStrips(rows: 128), shift: half)], fitted: true),
            Row(key: "G5", pages: [typed(S.typedText + S.invisibleFooter + S.picture(0, at: CGRect(x: 72, y: 730, width: 150, height: 60)),
                                         pictures: [S.shade(width: 300, height: 120)])], fitted: false),
            Row(key: "G6", pages: [typed(S.typedText + S.invisibleFooter + photos.indices.map { S.picture($0, at: photos[$0]) }.joined(),
                                         pictures: Array(repeating: S.shade(width: 306, height: 306), count: 4))], fitted: false),
            Row(key: "G7", pages: [S.document([S.Page(S.typedText + S.invisibleFooter, resources: "/XObject << \(unreadNames) >>",
                                                      objects: unread)])], fitted: false),
            Row(key: "G8", pages: [S.scan(.strips(rows: 128), shift: half, layer: .visibleBefore)], fitted: true),
            Row(key: "G9", pages: [patternScan(), deepScan()], fitted: true),
            Row(key: "G10", pages: [S.scan(.one, shift: half)], fitted: true),
            Row(key: "G11", pages: [S.scan(.strips(rows: 128), shift: half, rotate: 90), S.scan(.turnedStrips(rows: 128), shift: half)],
                fitted: true),
            Row(key: "G12", pages: [S.scan(.one, shift: half, layer: .visibleBefore)], fitted: true),
            Row(key: "G13", pages: [typed(S.picture(0, at: full) + S.typedText, pictures: [page])], fitted: false),
            Row(key: "G14", pages: [typed(S.line("Account holder MARISOL QUENTIN", x: 100, y: 740)
                                          + S.picture(0, at: CGRect(x: 0, y: 0, width: 612, height: 673.2)),
                                          pictures: [S.shade(width: 850, height: 935)])], fitted: false),
            Row(key: "G15", pages: [typed(S.typedText + S.picture(0, at: full),
                                          extra: [S.image(S.shade(width: 850, height: 1100), extra: "/SMask @1@"),
                                                  S.image(S.Gray(width: 850, height: 1100, value: 128))],
                                          resources: "/XObject << /P0 @0@ >>")], fitted: false),
            Row(key: "G16", pages: [typed(S.typedText + "q /G0 gs " + S.picture(0, at: full) + "Q ", pictures: [page],
                                          extra: [S.Object(dictionary: "/Type /ExtGState /ca 0.3")],
                                          resources: "/ExtGState << /G0 @1@ >>")], fitted: false),
            Row(key: "G17", pages: [typed(S.line("QUENTIN", x: 100, y: 700) + S.picture(0, at: CGRect(x: 98, y: 696, width: 60, height: 16)),
                                          pictures: [S.shade(width: 83, height: 22)])], fitted: false),
            Row(key: "G18", pages: [typed(S.typedText)], fitted: false),
            Row(key: "G19", pages: [typed(S.picture(0, at: full) + S.typedText + S.picture(1, at: CGRect(x: 95, y: 695, width: 40, height: 20)),
                                          pictures: [page, S.shade(width: 56, height: 28)])], fitted: false),
            Row(key: "G20", pages: [typed(S.picture(0, at: full) + S.typedText + S.picture(1, at: CGRect(x: 95, y: 665, width: 80, height: 20)),
                                          pictures: [S.print(dpi: 100, shift: 0), S.shade(width: 111, height: 28)])], fitted: false),
            Row(key: "G21", pages: [S.scan(.inlineStrips(rows: 128), shift: half, layer: .visibleBefore)], fitted: true),
        ]
    }

    @Test("Which pages are fitted, by table")
    func gateByTable() throws {
        let rows = Self.gateRows()
        // No row for a page whose content the scanner reports it could not
        // read: no made page gives one (the platform reads malformed streams
        // and reports success), so the gate's answer for it, fitted, is held
        // by the code alone.
        #expect(rows.count == 21)
        #expect(rows.reduce(0) { $0 + $1.pages.count } == 23)
        for row in rows {
            for (k, data) in row.pages.enumerated() {
                let (document, page, cgPage) = try #require(S.pdfPage(data), "\(row.key) page \(k + 1) opens")
                #expect(DocumentSearcher.carriesHiddenTextOverImage(page, cgPage: cgPage) == row.fitted,
                        "\(row.key) page \(k + 1): expected \(row.fitted ? "fitted" : "not fitted")")
                withExtendedLifetime(document) {}
            }
        }
    }

    @Test("A typed page that draws a picture and whose painting cannot be followed is fitted")
    func unfollowedTypedPageIsFitted() throws {
        let dot = S.image(S.Gray(width: 2, height: 2, value: 0))
        let names = "/XObject << /I0 @0@ >>"
        let draws = { (n: Int) in String(repeating: "q 10 0 0 10 20 20 cm /I0 Do Q ", count: n) }
        // Forms seven deep, each drawing the next `times` times, the last drawing the picture.
        func forms(_ times: Int) -> Data {
            var objects = [dot]
            for k in 0..<7 {
                objects.append(k < 6 ? S.form(String(repeating: "/F Do ", count: times), resources: "/XObject << /F @\(k + 2)@ >>")
                                     : S.form("q 10 0 0 10 20 20 cm /I0 Do Q", resources: names))
            }
            return S.document([S.Page(S.typedText + "/F Do", resources: "/XObject << /F @1@ >>", objects: objects)])
        }
        let pattern = S.Object(dictionary: "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << /XObject << /I0 @0@ >> >>",
                               stream: Data("q 10 0 0 10 0 0 cm /I0 Do Q".utf8))
        let rows: [(String, Data, Bool)] = [
            ("1,093 forms drawn", forms(3), true),
            ("127 forms drawn", forms(2), false),
            ("4,097 pictures", S.document([S.Page(S.typedText + draws(4_097), resources: names, objects: [dot])]), true),
            ("4,096 pictures", S.document([S.Page(S.typedText + draws(4_096), resources: names, objects: [dot])]), false),
            ("a picture in a tiling pattern", S.document([S.Page(S.typedText + "q /Pattern cs /T1 scn 20 20 10 10 re f Q",
                resources: "/Pattern << /T1 @1@ >>", objects: [dot, pattern])]), true),
            ("a tiling pattern with no picture", S.document([S.Page(S.typedText + "q /Pattern cs /T1 scn 20 20 10 10 re f Q",
                resources: "/Pattern << /T1 @0@ >>", objects: [S.Object(dictionary: "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << >>",
                                                                         stream: Data("0 0 5 5 re f".utf8))])]), false),
        ]
        #expect(rows.count == 6)
        for (key, data, fitted) in rows {
            let (document, page, cgPage) = try #require(S.pdfPage(data))
            defer { withExtendedLifetime(document) {} }
            #expect(DocumentSearcher.carriesHiddenTextOverImage(page, cgPage: cgPage) == fitted, "\(key): fitted \(fitted)")
        }
    }

    // MARK: - The box on the print

    static func hits(_ document: PDFDocument, _ word: String) async -> [SearchResult] {
        await PageImageInkFitTests.hits(document, word, includeOCR: false)
    }

    /// The first box Search places for `word` on the document's first page, in
    /// points, with the document, which the page needs alive.
    static func box(_ data: Data, _ word: String = S.word) async throws -> (PDFDocument, PDFPage, CGRect) {
        let (document, page, _) = try #require(S.pdfPage(data))
        let hit = try #require(await hits(document, word).first, "\(word) is matched")
        return (document, page, PageImageInkFitTests.points(hit.normalizedRect, page.bounds(for: .cropBox).size))
    }

    @Test("A scan stored in strips is boxed as its one-image twin, within a point")
    func stripsMatchTheirTwin() async throws {
        for word in S.words {
            let (_, _, strips) = try await Self.box(S.scan(.strips(rows: 128), shift: 0), word)
            let (_, _, one) = try await Self.box(S.scan(.one, shift: 0), word)
            for (a, b) in [(strips.minX, one.minX), (strips.minY, one.minY), (strips.maxX, one.maxX), (strips.maxY, one.maxY)] {
                #expect(abs(a - b) <= 1, "\(word): strips \(strips), one image \(one)")
            }
        }
    }

    @Test("On a scan stored in pieces the box covers the printed word")
    func boxCoversThePrint() async throws {
        let cases: [(String, Data, Data)] = [
            ("G2", S.scan(.strips(rows: 128), shift: Self.half), S.scan(.one, shift: Self.half)),
            ("G3", S.scan(.tiles(512), shift: Self.half), S.scan(.one, shift: Self.half)),
            ("G4", S.scan(.inlineStrips(rows: 128), shift: Self.half), S.scan(.one, shift: Self.half)),
            ("G8", S.scan(.strips(rows: 128), shift: Self.half, layer: .visibleBefore), S.scan(.one, shift: Self.half)),
            ("G11 turned page", S.scan(.strips(rows: 128), shift: Self.half, rotate: 90), S.scan(.one, shift: Self.half, rotate: 90)),
            ("G11 turned transform", S.scan(.turnedStrips(rows: 128), shift: Self.half), S.scan(.one, shift: Self.half)),
            ("G12", S.scan(.one, shift: Self.half, layer: .visibleBefore), S.scan(.one, shift: Self.half)),
            ("G21", S.scan(.inlineStrips(rows: 128), shift: Self.half, layer: .visibleBefore), S.scan(.one, shift: Self.half)),
        ]
        #expect(cases.count == 8)
        for (key, data, twinData) in cases {
            let (document, page, box) = try await Self.box(data)
            let (twinDocument, twinPage, twinBox) = try await Self.box(twinData)
            if page.rotation == 0 {
                // The word's ink, from the font: none of it outside the box.
                let word = S.wordInk(shift: Self.half)
                let outside = try PageImageInkFitTests.inkOutside(page, word: word, boxes: [box])
                #expect(outside.share == 0, "\(key): \(String(format: "%.1f", outside.share * 100))% of the word's ink outside \(box), up to \(String(format: "%.2f", outside.reach)) pt")
                let twinOutside = try PageImageInkFitTests.inkOutside(twinPage, word: word, boxes: [twinBox])
                #expect(twinOutside.share == 0, "\(key): the one-image twin covers its word")
            } else {
                // A turned page: the box is the one-image twin's (today's fit), within a point.
                for (a, b) in [(box.minX, twinBox.minX), (box.minY, twinBox.minY), (box.maxX, twinBox.maxX), (box.maxY, twinBox.maxY)] {
                    #expect(abs(a - b) <= 1, "\(key): pieces \(box), one image \(twinBox)")
                }
            }
            withExtendedLifetime((document, twinDocument)) {}
        }
    }

    @Test("On a page whose visible text lies under pictures, a result carries the text layer's box over the word")
    func textLayerBoxOverTheWord() async throws {
        let rows: [(String, Data)] = [
            ("G8", S.scan(.strips(rows: 128), shift: Self.half, layer: .visibleBefore)),
            ("G12", S.scan(.one, shift: Self.half, layer: .visibleBefore)),
            ("G21", S.scan(.inlineStrips(rows: 128), shift: Self.half, layer: .visibleBefore)),
        ]
        #expect(rows.count == 3)
        // The text is drawn at the unshifted positions: the word's own glyphs.
        let glyphs = S.wordInk(shift: 0).insetBy(dx: 1, dy: 1)
        for (key, data) in rows {
            let (document, page, _) = try #require(S.pdfPage(data))
            defer { withExtendedLifetime(document) {} }
            let hit = try #require(await Self.hits(document, S.word).first, "\(key): matched")
            let layer = try #require(hit.textLayerRect, "\(key): the result carries the text layer's box")
            let points = PageImageInkFitTests.points(layer, page.bounds(for: .cropBox).size)
            #expect(points.contains(glyphs), "\(key): the text layer's box \(points) holds the word's glyphs \(glyphs)")
        }
    }

    // MARK: - A light row through a word

    /// The print with `blank` rows of the 300 dpi picture made white through
    /// the middle of the word, its darkest ink `ink`, stored in two strips
    /// that meet at those rows (the lower one placed `drop` points lower), or
    /// stored whole; the text layer half a word to one side, invisible.
    static func seamScan(blank: Int, drop: CGFloat, ink: UInt8 = 0, whole: Bool = false) -> Data {
        var g = S.print(dpi: 300, shift: half)
        if ink > 0 {
            let light = 255 - Int(ink)
            for i in g.pixels.indices {
                let dark: Int = 255 - Int(g.pixels[i])
                g.pixels[i] = UInt8(255 - dark * light / 255)
            }
        }
        let seam = Int(((S.page.height - S.wordInk(shift: half).midY) * 300 / 72).rounded())
        for r in seam..<(seam + blank) { for c in 0..<g.width { g.pixels[r * g.width + c] = 255 } }
        if whole {
            return S.document([S.Page("q 612 0 0 792 0 0 cm /S0 Do Q " + S.text(mode: 3), resources: "/XObject << /S0 @0@ >>", objects: [S.image(g)])])
        }
        let unit: CGFloat = 72 / 300
        let top = g.piece(rows: 0..<seam, columns: 0..<g.width), bottom = g.piece(rows: seam..<g.height, columns: 0..<g.width)
        let topHeight = CGFloat(seam) * unit, bottomHeight = CGFloat(g.height - seam) * unit
        let ops = "q 612 0 0 \(S.n(topHeight)) 0 \(S.n(S.page.height - topHeight)) cm /S0 Do Q "
            + "q 612 0 0 \(S.n(bottomHeight)) 0 \(S.n(-drop)) cm /S1 Do Q "
        return S.document([S.Page(ops + S.text(mode: 3), resources: "/XObject << /S0 @0@ /S1 @1@ >>",
                                  objects: [S.image(top), S.image(bottom)])])
    }

    /// The word's ink at `threshold` in its own rectangle from the font, a
    /// point and more around it, and how much of it lies outside `boxes`;
    /// read over the whole rectangle, so a light row through the word does
    /// not end the count.
    static func wordInkOutside(_ page: PDFPage, word: CGRect, boxes: [CGRect], threshold: UInt8) throws -> (ink: Int, outside: Int) {
        let bounds = page.bounds(for: .cropBox)
        let frame = DocumentSearcher.readingFrame(of: page, visual: bounds.size)
        let window = frame.toReading(word).insetBy(dx: -1, dy: -2), reading = boxes.map(frame.toReading)
        let cgPage = try #require(page.pageRef)
        let bitmap = try #require(DocumentSearcher.renderGray(
            cgPage, rotation: page.rotation, visual: bounds.size, window: window, frame: frame)).reading(threshold: threshold)
        let scale = DocumentSearcher.inkFitScale
        var ink = 0, outside = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.isInk(x, y) {
                ink += 1
                let point = CGPoint(x: window.minX + (CGFloat(x) + 0.5) / scale, y: window.minY + (CGFloat(y) + 0.5) / scale)
                if !reading.contains(where: { $0.contains(point) }) { outside += 1 }
            }
        }
        return (ink, outside)
    }

    @Test("A light row through a word leaves none of the word outside the paint")
    func lightRowThroughAWord() async throws {
        let rows: [(String, Data, UInt8)] = [
            ("a blank picture row where two strips meet", Self.seamScan(blank: 1, drop: 0), DocumentSearcher.inkFitThreshold),
            ("three blank picture rows where two strips meet", Self.seamScan(blank: 3, drop: 0), DocumentSearcher.inkFitThreshold),
            ("a gap of 0.3 pt between two strips", Self.seamScan(blank: 0, drop: 0.3), DocumentSearcher.inkFitThreshold),
            ("a seam 0.1 pt off on faint grey ink", Self.seamScan(blank: 0, drop: 0.1, ink: 150), DocumentSearcher.inkFitLightThreshold),
            ("one image, a blank picture row", Self.seamScan(blank: 1, drop: 0, whole: true), DocumentSearcher.inkFitThreshold),
            ("one image, three blank picture rows", Self.seamScan(blank: 3, drop: 0, whole: true), DocumentSearcher.inkFitThreshold),
        ]
        #expect(rows.count == 6)
        let word = S.wordInk(shift: Self.half)
        for (key, data, threshold) in rows {
            let (document, page, box) = try await Self.box(data)
            defer { withExtendedLifetime(document) {} }
            let read = try Self.wordInkOutside(page, word: word, boxes: [box], threshold: threshold)
            #expect(read.ink > 0, "\(key): the word's ink is read")
            #expect(read.outside == 0, "\(key): \(read.outside) of \(read.ink) ink points of the word outside the paint \(box)")
        }
    }

    // MARK: - When the map is read

    @Test("Where pictures are painted is read only for pages that need it")
    func mapIsReadOnlyWhenNeeded() {
        let rows: [(String, Bool, Bool, Bool, Bool, Bool)] = [
            ("N1", true, true, true, false, false),
            ("N2", true, false, false, false, true),
            ("N3", false, false, true, false, true),
            ("N4", false, false, false, true, true),
            ("N5", false, false, false, false, false),
        ]
        #expect(rows.count == 5)
        for (key, invisible, pageScale, reaches, inline, needs) in rows {
            #expect(DocumentSearcher.needsPictureMap(showsInvisibleText: invisible, largestImageIsPageScale: pageScale,
                                                     reachesImage: reaches, drawsInlineImage: inline) == needs, "\(key)")
        }
    }

    @Test("Two pages of a scan in pieces have different fit keys")
    func piecesKeepTheirOwnKeys() throws {
        let data = S.document([S.scanPage(.strips(rows: 128), shift: Self.half), S.scanPage(.strips(rows: 128), shift: Self.half, mark: true)])
        let document = try #require(PDFDocument(data: data))
        let keys = try (0..<2).map { i -> Int in
            let page = try #require(document.page(at: i))
            let cgPage = try #require(page.pageRef)
            return InkTokenCache.key(page: page, cgPage: cgPage, visual: page.bounds(for: .cropBox).size)
        }
        #expect(document.page(at: 0)?.string == document.page(at: 1)?.string)
        #expect(keys[0] != keys[1])
    }

    // MARK: - The plan for hidden words

    static func normalized(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX / 612, y: r.minY / 792, width: r.width / 612, height: r.height / 792)
    }

    /// The plan as the app's run makes it: in a detached task, off the main
    /// thread, where the fit reads the page (on the main thread it reads only
    /// its caches).
    static func plan(_ regions: [RedactionRegion], on page: PDFPage) async -> InkStripPlan? {
        nonisolated(unsafe) let page = page
        return await Task.detached { await DocumentSearcher.inkStripPlan(regions: regions, page: page) }.value
    }

    @Test("The plan for hidden words on a scan stored in pieces")
    func planOnNewlyFittedPages() async throws {
        // The column: true while a drawn box on a newly fitted page keeps the
        // text layer, false if such a page is to stay a picture. Typed here.
        let drawnBoxKeepsTextLayer = false
        #expect(DocumentSearcher.drawnBoxOnNewlyFittedPageKeepsTextLayer == false)
        // Unshifted scans: with the layer half a word to one side, the fit
        // cannot place the line's last word even on the one-image twin, so
        // every box on that line is unsure there as well.
        let twin = try #require(S.pdfPage(S.scan(.one, shift: 0)))
        let drawnRows: [(String, Data)] = [
            ("X1", S.scan(.strips(rows: 128), shift: 0)),
            ("X2", S.scan(.strips(rows: 128), shift: 0, layer: .visibleBefore)),
            ("X3", S.scan(.one, shift: 0, layer: .visibleBefore)),
        ]
        for (key, data) in drawnRows {
            let (document, page, cgPage) = try #require(S.pdfPage(data))
            defer { withExtendedLifetime(document) {} }
            // The wider gate takes the page, so "no plan" is the rule's answer.
            try #require(DocumentSearcher.carriesHiddenTextOverImage(page, cgPage: cgPage), "\(key): the page is fitted")
            let drawn = RedactionRegion(id: UUID(), normalizedRect: Self.normalized(S.wordInk(shift: 0).insetBy(dx: -1, dy: -1)),
                                        source: .manual)
            let plan = await Self.plan([drawn], on: page)
            if drawnBoxKeepsTextLayer {
                let made = try #require(plan, "\(key): a plan")
                let twinPlan = try #require(await Self.plan([drawn], on: twin.1))
                try #require(twinPlan.covers([drawn]) && !(twinPlan.words[drawn.id] ?? []).isEmpty, "\(key): the twin's plan covers the box and holds the word: \(twinPlan)")
                #expect(made.covers([drawn]), "\(key): it covers the box; the twin's plan \(twinPlan)")
                #expect(!(made.words[drawn.id] ?? []).isEmpty, "\(key): it holds the word")
                #expect(made.words[drawn.id] == twinPlan.words[drawn.id], "\(key): the words of its one-image twin's plan \(twinPlan)")
            } else {
                #expect(plan == nil, "\(key): no plan, as today")
            }
        }
        let (document, page, _) = try #require(S.pdfPage(S.scan(.strips(rows: 128), shift: 0)))
        let hit = try #require(await Self.hits(document, S.word).first)
        let matched = RedactionRegion(id: UUID(), normalizedRect: hit.normalizedRect, source: .searchMatch(term: S.word),
                                      textAnchored: true)
        let plan = try #require(await Self.plan([matched], on: page), "X4: a plan")
        #expect(plan.covers([matched]), "X4: it covers the box")
        #expect(drawnRows.count + 1 == 4)
    }

    @Test("When a page gets a plan for its hidden words")
    func planIsMadeByRule() {
        let rows: [(String, Bool, Bool, Bool, Bool, Bool)] = [
            ("P1", true, true, true, false, true),
            ("P2", false, true, false, false, true),
            ("P3", false, true, true, true, true),
            ("P4", false, true, true, false, false),
            ("P5", false, false, false, true, false),
        ]
        #expect(rows.count == 5)
        for (key, today, ruleG, unanchored, keeps, made) in rows {
            #expect(DocumentSearcher.planIsMade(fittedToday: today, fittedByRuleG: ruleG, hasUnanchoredBox: unanchored,
                                                drawnBoxKeepsTextLayer: keeps) == made, "\(key)")
        }
        // P1 under either value.
        #expect(DocumentSearcher.planIsMade(fittedToday: true, fittedByRuleG: true, hasUnanchoredBox: true, drawnBoxKeepsTextLayer: true))
    }

    // MARK: - The plan's page facts

    /// Each use of `PageTextFacts(` in `text` whose call, to its matching
    /// closing parenthesis, does not hold `printIsAPicture(`; comment lines skipped.
    static func factsWithoutPrintAnswer(_ text: String) -> [String] {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        var out: [String] = []
        var rest = Substring(code)
        while let start = rest.range(of: "PageTextFacts(") {
            var depth = 1
            var index = start.upperBound
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "(" { depth += 1 } else if rest[index] == ")" { depth -= 1 }
                index = rest.index(after: index)
            }
            let call = String(rest[start.lowerBound..<index])
            if !call.contains("printIsAPicture(") || call.contains("printIsAPicture(pageScale:") { out.append(call) }
            rest = rest[index...]
        }
        return out
    }

    @Test("The plan's page facts take the print-is-a-picture answer")
    func pageFactsTakeThePrintAnswer() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, "the scan reads the engine's sources (\(files.count) files)")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard !text.contains("struct PageTextFacts") else { continue }
            let bad = Self.factsWithoutPrintAnswer(text)
            #expect(bad.isEmpty, "\(file.lastPathComponent): \(bad)")
        }
        let variable = "let facts = PageTextFacts(\n    showsInvisibleText: invisible,\n    carriesPageScaleImage: scale)"
        #expect(Self.factsWithoutPrintAnswer(variable).count == 1, "a call that passes a variable fails the rule")
        let call = "PageTextFacts(showsInvisibleText: invisible,\n carriesPageScaleImage: DocumentSearcher.printIsAPicture(page, cgPage: cgPage))"
        #expect(Self.factsWithoutPrintAnswer(call).isEmpty)
        let literal = "PageTextFacts(showsInvisibleText: invisible,\n carriesPageScaleImage: DocumentSearcher.printIsAPicture(pageScale: true, page: page, cgPage: cgPage))"
        #expect(Self.factsWithoutPrintAnswer(literal).count == 1, "an answer given in place of the page's own fails the rule")
    }
}
