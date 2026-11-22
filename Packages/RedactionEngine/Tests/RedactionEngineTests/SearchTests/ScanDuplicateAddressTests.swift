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

    @Test("Two copies drawn in order: each assembled address is boxed on its own copy")
    func stackedCopiesEachOnTheirOwnLines() async throws {
        let hits = await ContentGlyphScanTests.scan(try Self.page(cityFirst: false))
        let assembled = hits.filter { !$0.matchedText.contains("\n") && $0.matchedText.contains("62704") }
        #expect(assembled.count == 2, "two assembled addresses: \(hits.map(\.matchedText))")
        #expect(assembled.filter { Self.covers($0, Self.copy(top: 709)) }.count == 1,
                "one on the upper copy: \(assembled.map { ContentGlyphScanTests.points($0.normalizedRect) })")
        #expect(assembled.filter { Self.covers($0, Self.copy(top: 509)) }.count == 1,
                "one on the lower copy: \(assembled.map { ContentGlyphScanTests.points($0.normalizedRect) })")
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

    @Test("Two copies kept at one place are taken one each, in order")
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
}
