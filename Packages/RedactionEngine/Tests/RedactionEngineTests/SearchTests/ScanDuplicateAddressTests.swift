import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

/// Two copies of one address on a page: each copy is placed in the page's
/// text where its own box is, and boxed on its own lines, on both of Scan's
/// legs (the placing and the boxes kept by place are shared by them).
@Suite("Scan boxes each copy of a repeated address on its own lines")
struct ScanDuplicateAddressTests {
    static func line(_ x: Int, _ y: Int, _ text: String) -> String { "BT /F1 12 Tf \(x) \(y) Td (\(text)) Tj ET" }
    static let street = "1234 Main Street", city = "Springfield, IL 62704"

    /// The page's copies: the upper one at y 700/686, the lower at 500/486.
    static func page(cityFirst: Bool) throws -> PDFDocument {
        let copies = [(700, 686), (500, 486)].flatMap { top, bottom in
            cityFirst ? [line(72, bottom, city), line(72, top, street)] : [line(72, top, street), line(72, bottom, city)]
        }
        return try ContentGlyphWalkTests.document(copies.joined(separator: "\n"))
    }

    /// A copy's two lines in page points.
    static func copy(top: CGFloat) -> CGRect { CGRect(x: 72, y: top - 17, width: 112, height: 29) }

    static func covers(_ hit: SearchResult, _ copy: CGRect) -> Bool {
        ContentGlyphScanTests.points(hit.normalizedRect).intersects(copy)
    }

    /// Whether the hit's box holds both lines of the copy whose street line
    /// sits at `top` - 9: a point inside each line, not only some overlap.
    static func coversBothLines(_ hit: SearchResult, top: CGFloat) -> Bool {
        let box = ContentGlyphScanTests.points(hit.normalizedRect)
        return box.contains(CGPoint(x: 100, y: top - 5)) && box.contains(CGPoint(x: 100, y: top - 19))
    }

    /// The same one-line address twice, at y 700 and 500. With `above`, a
    /// street line at x 300, y 520 (not aligned with the copy, so not joined
    /// to it) starts the address pattern's match on the line above the
    /// lower copy, and the overlap step widens the lower copy over it.
    /// Written without commas: the text leg's lines drop them, and only an
    /// address whose text is in the page's text word for word gets a place
    /// there (with commas it goes to the sentinel and meets no other match).
    static let oneLine = "1234 Main Street Springfield IL 62704"
    static func oneLinePage(above: Bool) throws -> PDFDocument {
        var lines = [line(72, 700, oneLine)]
        if above { lines.append(line(300, 520, "55 Oak Avenue")) }
        lines.append(line(72, 500, oneLine))
        return try ContentGlyphWalkTests.document(lines.joined(separator: "\n"))
    }
    static func oneLineAt(_ baseline: CGFloat) -> CGRect { CGRect(x: 90, y: baseline + 2, width: 40, height: 4) }

    @Test("Two copies drawn in order: each assembled address is boxed on its own copy")
    func stackedCopiesEachOnTheirOwnLines() async throws {
        let hits = await ContentGlyphScanTests.scan(try Self.page(cityFirst: false))
        let assembled = hits.filter { !$0.matchedText.contains("\n") && $0.matchedText.contains("62704") }
        #expect(assembled.count == 2, "two assembled addresses: \(hits.map(\.matchedText))")
        #expect(assembled.filter { Self.covers($0, Self.copy(top: 709)) }.count == 1,
                "one on the upper copy: \(assembled.map { ContentGlyphScanTests.points($0.normalizedRect) })")
        #expect(assembled.filter { Self.covers($0, Self.copy(top: 509)) }.count == 1,
                "one on the lower copy: \(assembled.map { ContentGlyphScanTests.points($0.normalizedRect) })")
        #expect(assembled.contains { Self.coversBothLines($0, top: 709) } && assembled.contains { Self.coversBothLines($0, top: 509) },
                "each copy's box holds both its lines: \(assembled.map { ContentGlyphScanTests.points($0.normalizedRect) })")
    }

    @Test("On the picture leg too, two copies drawn in order: each assembled address is boxed on its own copy")
    func stackedCopiesOnThePictureLeg() async throws {
        let doc = try Self.page(cityFirst: false)
        let page = try #require(doc.page(at: 0))
        let hits = await DocumentSearcher()._testScanPagePIIViaOCR(page: SendablePDFPage(page), pageIndex: 0, categories: [.address])
        let assembled = hits.filter { !$0.matchedText.contains("\n") && $0.matchedText.contains("62704") }
        let upper = Self.copy(top: 709), lower = Self.copy(top: 509)
        let at = assembled.map { "\($0.matchedText.debugDescription) \(ContentGlyphScanTests.points($0.normalizedRect))" }
        #expect(!assembled.isEmpty && assembled.allSatisfy { Self.covers($0, upper) != Self.covers($0, lower) },
                "each assembled address sits on one copy: \(at)")
        #expect(assembled.contains { Self.covers($0, upper) }, "the upper copy has its own: \(at)")
        #expect(assembled.contains { Self.covers($0, lower) }, "the lower copy has its own: \(at)")
        #expect(assembled.contains { Self.coversBothLines($0, top: 709) } && assembled.contains { Self.coversBothLines($0, top: 509) },
                "each copy's box holds both its lines: \(at)")
    }

    @Test("On the picture leg, a one-line address twice is placed at each copy's own line: one result each")
    func oneLineCopiesPlacedOnThePictureLeg() async throws {
        let doc = try Self.oneLinePage(above: false)
        let page = try #require(doc.page(at: 0))
        let hits = await DocumentSearcher()._testScanPagePIIViaOCR(page: SendablePDFPage(page), pageIndex: 0, categories: [.address])
        let at = hits.map { "\($0.matchedText.debugDescription) \(ContentGlyphScanTests.points($0.normalizedRect))" }
        // Placed at its own line, each copy meets the pattern's match there
        // and the two are one result; placed at the sentinel, each would
        // stand beside the pattern's match as a second result.
        #expect(hits.filter { Self.covers($0, Self.oneLineAt(700)) }.count == 1, "one result on the upper copy: \(at)")
        #expect(hits.filter { Self.covers($0, Self.oneLineAt(500)) }.count == 1, "one result on the lower copy: \(at)")
    }

    @Test("A copy the overlap step widens over the line above is still boxed on its own line")
    func widenedCopyIsBoxedOnItsOwnLine() async throws {
        let hits = await ContentGlyphScanTests.scan(try Self.oneLinePage(above: true))
        let at = hits.map { "\($0.matchedText.debugDescription) \(ContentGlyphScanTests.points($0.normalizedRect))" }
        #expect(hits.contains { Self.covers($0, Self.oneLineAt(700)) }, "the upper copy is boxed: \(at)")
        #expect(hits.contains { $0.matchedText == Self.oneLine && Self.covers($0, Self.oneLineAt(500)) },
                "the lower copy's own result is boxed on the lower copy: \(at)")
    }

    @Test("Two copies drawn ZIP line first: the lower copy's ZIP line has a box of its own")
    func lowerCopyDrawnZipFirstIsBoxed() async throws {
        let doc = try Self.page(cityFirst: true)
        let hits = await ContentGlyphScanTests.scan(doc)
        let zip = CGRect(x: 72, y: 484, width: 112, height: 14)
        #expect(hits.contains { $0.matchedText.contains("62704") && Self.covers($0, zip) },
                "a box on the lower copy's ZIP line: \(hits.map { "\($0.matchedText.debugDescription) \(ContentGlyphScanTests.points($0.normalizedRect))" })")
        #expect(hits.contains { Self.covers($0, Self.copy(top: 709)) }, "the upper copy keeps its box")
    }

    @Test("An address is placed at the occurrence its own box meets, and at the sentinel when none meets")
    func placedWhereItsBoxIs() {
        let haystack = "A B A" as NSString
        let boxOf: (NSRange) -> CGRect? = { $0.location == 0 ? CGRect(x: 0, y: 0, width: 1, height: 1) : CGRect(x: 10, y: 10, width: 1, height: 1) }
        let second = DocumentSearcher.place("A", meeting: CGRect(x: 10, y: 10, width: 2, height: 2), in: haystack, boxOf: boxOf)
        #expect(second == NSRange(location: 4, length: 1), "the second occurrence: \(second)")
        let first = DocumentSearcher.place("A", meeting: CGRect(x: 0, y: 0, width: 2, height: 2), in: haystack, boxOf: boxOf)
        #expect(first == NSRange(location: 0, length: 1), "the first occurrence: \(first)")
        let none = DocumentSearcher.place("A", meeting: CGRect(x: 50, y: 50, width: 1, height: 1), in: haystack, boxOf: boxOf)
        #expect(none == NSRange(location: 5, length: 0), "no occurrence meets: the sentinel, not the first copy: \(none)")
        let unread = DocumentSearcher.place("A", meeting: CGRect(x: 0, y: 0, width: 2, height: 2), in: haystack, boxOf: { _ in nil })
        #expect(unread == NSRange(location: 5, length: 0), "no box read: the sentinel: \(unread)")
    }

    @Test("Two copies kept at one real place are both taken by its one survivor, united")
    func copiesAtOneRealPlaceAreTakenTogether() {
        let place = NSRange(location: 9, length: 19)
        let upper = DocumentSearcher.TextLayerBox(rect: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.02), textLayerRect: nil)
        let lower = DocumentSearcher.TextLayerBox(rect: CGRect(x: 0.4, y: 0.79, width: 0.2, height: 0.02), textLayerRect: nil)
        var boxes: [DocumentSearcher.AddressPlace: [DocumentSearcher.TextLayerBox]] =
            [DocumentSearcher.AddressPlace(text: "1 Main St, IL 62704", range: place): [upper, lower]]
        // The overlap step leaves one survivor for the two copies' matches:
        // one text, one range.
        let match = PIIDetector.PIIMatch(text: "1 Main St, IL 62704", range: place, kind: .address, confidence: 0.8)
        let box = DocumentSearcher.takeBox(for: match, from: &boxes)
        #expect(box?.rect == upper.rect.union(lower.rect), "both copies covered: \(String(describing: box?.rect))")
        #expect(DocumentSearcher.takeBox(for: match, from: &boxes) == nil, "each box is taken once")
    }

    @Test("Two copies kept at the stand-in are taken one each, in order")
    func copiesAtOnePlaceTakeOneBoxEach() {
        let place = NSRange(location: 9, length: 0)
        let upper = DocumentSearcher.TextLayerBox(rect: CGRect(x: 0, y: 0.8, width: 0.2, height: 0.04), textLayerRect: nil)
        let lower = DocumentSearcher.TextLayerBox(rect: CGRect(x: 0, y: 0.5, width: 0.2, height: 0.04), textLayerRect: nil)
        var boxes: [DocumentSearcher.AddressPlace: [DocumentSearcher.TextLayerBox]] =
            [DocumentSearcher.AddressPlace(text: "1 Main St", range: place): [upper, lower]]
        let match = PIIDetector.PIIMatch(text: "1 Main St", range: place, kind: .address, confidence: 0.9)
        #expect(DocumentSearcher.takeBox(for: match, from: &boxes)?.rect == upper.rect)
        #expect(DocumentSearcher.takeBox(for: match, from: &boxes)?.rect == lower.rect)
        #expect(DocumentSearcher.takeBox(for: match, from: &boxes) == nil, "two boxes, two takes")
    }

    @Test("A survivor widened over two copies' places takes both their boxes, and no stand-in's")
    func widenedSurvivorTakesEveryBoxInside() {
        let text = "1 Main St, IL 62704"
        let upper = DocumentSearcher.TextLayerBox(rect: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.02), textLayerRect: nil)
        let lower = DocumentSearcher.TextLayerBox(rect: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.02), textLayerRect: nil)
        let standIn = DocumentSearcher.TextLayerBox(rect: CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.02), textLayerRect: nil)
        let other = DocumentSearcher.TextLayerBox(rect: CGRect(x: 0.6, y: 0.5, width: 0.2, height: 0.02), textLayerRect: nil)
        let outside = DocumentSearcher.TextLayerBox(rect: CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.02), textLayerRect: nil)
        var boxes: [DocumentSearcher.AddressPlace: [DocumentSearcher.TextLayerBox]] = [
            DocumentSearcher.AddressPlace(text: text, range: NSRange(location: 20, length: 19)): [upper],
            DocumentSearcher.AddressPlace(text: text, range: NSRange(location: 40, length: 19)): [lower],
            DocumentSearcher.AddressPlace(text: text, range: NSRange(location: 59, length: 0)): [standIn],
            DocumentSearcher.AddressPlace(text: text, range: NSRange(location: 70, length: 19)): [outside],
            DocumentSearcher.AddressPlace(text: "9 Elm St, IL 62704", range: NSRange(location: 45, length: 5)): [other],
        ]
        // The overlap step's survivor: the same text, its range widened from
        // its own place over both copies' places.
        let widened = PIIDetector.PIIMatch(text: text, range: NSRange(location: 5, length: 54), kind: .address, confidence: 0.8)
        let box = DocumentSearcher.takeBox(for: widened, from: &boxes)
        #expect(box?.rect == upper.rect.union(lower.rect), "both copies' boxes, united: \(String(describing: box?.rect))")
        #expect(DocumentSearcher.takeBox(for: widened, from: &boxes) == nil, "each box is taken once")
        // The stand-in sits at the widened range's end, inside its bounds by
        // location alone, and a copy of the same text lies past the range.
        let atStandIn = PIIDetector.PIIMatch(text: text, range: NSRange(location: 59, length: 0), kind: .address, confidence: 0.8)
        #expect(DocumentSearcher.takeBox(for: atStandIn, from: &boxes)?.rect == standIn.rect, "the stand-in's box is left to its own match")
        let past = PIIDetector.PIIMatch(text: text, range: NSRange(location: 70, length: 19), kind: .address, confidence: 0.8)
        #expect(DocumentSearcher.takeBox(for: past, from: &boxes)?.rect == outside.rect, "a copy past the range is left to its own match")
        let elsewhere = PIIDetector.PIIMatch(text: "9 Elm St, IL 62704", range: NSRange(location: 45, length: 5), kind: .address, confidence: 0.8)
        #expect(DocumentSearcher.takeBox(for: elsewhere, from: &boxes)?.rect == other.rect, "another text's box is left to it")
    }
}
