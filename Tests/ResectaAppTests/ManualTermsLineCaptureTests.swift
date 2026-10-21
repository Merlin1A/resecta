import Testing
import Foundation
import CoreGraphics
import PDFKit
import UIKit
import RedactionEngine
@testable import ResectaApp

// The manual-region capture's line rule and admission rule: a region takes
// the words the Searchable filter would touch (parity with removal), each
// captured line joins as the page text's verbatim span ("123-45-6789" whole),
// lines never join across, a region over exactly one word keeps it, and a
// single token of a multi-word run joins only when it carries a digit or has
// four scalars or more outside the bundled English stop list.

@Suite("Manual-region line capture")
struct ManualTermsLineCaptureTests {

    private enum TestError: Error { case failed }

    /// One page, Helvetica 24, six lines at known positions.
    private static let lines = [
        "Account Number 1234-5678",
        "j.doe@example.com",
        "Bo Lee IBM Ann Lee",
        "José the Account",
        "Hart-",
        "well",
    ]

    private static func textPDF() -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont(name: "Helvetica", size: 24)!,
                                                        .foregroundColor: UIColor.black]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 72, y: 80 + 60 * i), withAttributes: attrs)
            }
        }
        return PDFDocument(data: data)!
    }

    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Every word's normalized rect on page 0, in reading order.
    private static func words(_ doc: PDFDocument) throws -> [(text: String, rect: CGRect)] {
        guard let page = doc.page(at: 0) else { throw TestError.failed }
        return TextSpan.words(fullyInside: unit, on: page).map { ($0.text, $0.normalizedRect) }
    }

    /// The union of the boxes of the words on the line of the first word
    /// whose text contains `piece`.
    private static func lineBox(_ words: [(text: String, rect: CGRect)], line piece: String) throws -> CGRect {
        guard let anchor = words.first(where: { $0.text.contains(piece) })?.rect else { throw TestError.failed }
        return words.filter { $0.rect.minY < anchor.maxY && anchor.minY < $0.rect.maxY }
            .reduce(anchor) { $0.union($1.rect) }
    }

    private static func manual(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }

    /// A one-point halo around a rect (in normalized units of a 612 × 792 page).
    private static func padded(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -1 / 612, dy: -1 / 792)
    }

    private static func table(_ set: SensitiveTermSet) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: set.terms.map { ($0.text, $0.requiresTokenBoundary) })
    }

    private static func capture(_ doc: PDFDocument, _ rects: [CGRect]) -> [String: Bool] {
        table(PipelineCoordinator.sensitiveTermSet(
            applied: [], manualRegions: [0: rects.map(manual)], in: doc, textLayerStatus: [0: .rich]))
    }

    @Test("A line joins as the page text's verbatim span; its stop-listed tokens stay out, a token with a digit stays in")
    func verbatimSpanAndAdmission() throws {
        let doc = Self.textPDF()
        let words = try Self.words(doc)
        let box = try Self.lineBox(words, line: "Number")
        let terms = Self.capture(doc, [Self.padded(box)])
        #expect(terms["Account Number 1234-5678"] == false, "the span, verbatim: \(terms.keys.sorted())")
        #expect(terms["Account"] == nil && terms["Number"] == nil, "stop-listed tokens")
        #expect(terms["Account Number 1234 5678"] == nil, "no space join")
        let digitTokens = terms.filter { $0.key.contains("1234") && $0.key != "Account Number 1234-5678" }
        #expect(!digitTokens.isEmpty && digitTokens.values.allSatisfy { $0 }, "a token with a digit, bounded")
    }

    @Test("An address with separators is searched whole")
    func emailIsWhole() throws {
        let doc = Self.textPDF()
        let words = try Self.words(doc)
        let box = try Self.lineBox(words, line: "doe")
        let terms = Self.capture(doc, [Self.padded(box)])
        #expect(terms.keys.contains("j.doe@example.com"), "\(terms.keys.sorted())")
    }

    @Test("A region over exactly one word keeps it, short or stop-listed; a multi-word run's tokens follow the rule")
    func singleWordRule() throws {
        let doc = Self.textPDF()
        let words = try Self.words(doc)
        let bo = try #require(words.first { $0.text == "Bo" }?.rect)
        #expect(Self.capture(doc, [Self.padded(bo)]) == ["Bo": true])
        let ibm = try #require(words.first { $0.text == "IBM" }?.rect)
        #expect(Self.capture(doc, [Self.padded(ibm)]) == ["IBM": true])
        let the = try #require(words.first { $0.text == "the" }?.rect)
        #expect(Self.capture(doc, [Self.padded(the)]) == ["the": true])
        let ann = try #require(words.first { $0.text == "Ann" }?.rect)
        let lee = try #require(words.last { $0.text == "Lee" }?.rect)
        #expect(Self.capture(doc, [Self.padded(ann.union(lee))]) == ["Ann Lee": false, "Ann": true, "Lee": true],
                "capitalized three-scalar tokens of a run stand alone, bounded")
        let jose = try #require(words.first { $0.text == "José" }?.rect)
        let account = try #require(words.last { $0.text == "Account" }?.rect)
        #expect(Self.capture(doc, [Self.padded(jose.union(account))]) == ["José the Account": false, "José": true],
                "four scalars in, the stop-listed tokens out")
    }

    @Test("A short capitalized word of a run stands alone; an all-caps or lowercase short word does not")
    func shortCapitalizedWords() throws {
        let doc = Self.textPDF()
        let words = try Self.words(doc)
        let box = try Self.lineBox(words, line: "IBM")
        let terms = Self.capture(doc, [Self.padded(box)])
        #expect(terms["Bo Lee IBM Ann Lee"] == false, "the span: \(terms.keys.sorted())")
        #expect(terms["Bo"] == true && terms["Lee"] == true && terms["Ann"] == true, "short surnames, bounded")
        #expect(terms["IBM"] == nil, "an all-caps short word stays out of a run")
        let jose = try Self.lineBox(words, line: "José")
        #expect(Self.capture(doc, [Self.padded(jose)])["the"] == nil, "a lowercase short word stays out of a run")
    }

    @Test("Lines never join across; no hyphen join")
    func linesStayApart() throws {
        let doc = Self.textPDF()
        let words = try Self.words(doc)
        let hart = try #require(words.first { $0.text.hasPrefix("Hart") }?.rect)
        let well = try #require(words.first { $0.text == "well" }?.rect)
        let terms = Self.capture(doc, [Self.padded(hart.union(well))])
        #expect(terms["Hartwell"] == nil && terms["Hart- well"] == nil, "\(terms.keys.sorted())")
        #expect(terms["well"] == true)
        #expect(terms.keys.contains { $0.hasPrefix("Hart") && !$0.contains(" ") })
        let account = try Self.lineBox(words, line: "Number")
        let email = try Self.lineBox(words, line: "doe")
        let both = Self.capture(doc, [Self.padded(account.union(email))])
        #expect(both["Account Number 1234-5678"] == false && both.keys.contains("j.doe@example.com"),
                "one span per line: \(both.keys.sorted())")
    }

    @Test("Parity with removal: a region that clips a word captures it; the 3-pt halo on the region's own line, not on the line above")
    func touchingWordsAreCaptured() throws {
        let doc = Self.textPDF()
        let words = try Self.words(doc)
        // The first word of its line: nothing to its left.
        let jose = try #require(words.first { $0.text == "José" }?.rect)
        let leftHalf = CGRect(x: jose.minX, y: jose.minY, width: jose.width / 2, height: jose.height)
        #expect(Self.capture(doc, [leftHalf]) == ["José": true], "a clipped word is claimed")
        let pt = 1.0 / 612
        let beside = CGRect(x: jose.minX - 3 * pt, y: jose.minY, width: pt, height: jose.height)
        #expect(Self.capture(doc, [beside]) == ["José": true], "2 pt beside it on the same line")
        let farther = CGRect(x: jose.minX - 6 * pt, y: jose.minY, width: pt, height: jose.height)
        #expect(Self.capture(doc, [farther]) == [:], "5 pt beside it is past the halo")
        let above = CGRect(x: jose.minX, y: jose.maxY + 2.0 / 792, width: jose.width, height: 8.0 / 792)
        #expect(Self.capture(doc, [above]) == [:], "2 pt above it is off the line band")
    }

    @Test("The stop list: its count, lowercase, four scalars or more; the admission rule")
    func stopListPins() {
        #expect(ManualTermStopWords.words.count == 151)
        #expect(ManualTermStopWords.words.allSatisfy { $0 == $0.lowercased() && $0.unicodeScalars.count >= 4 })
        #expect(!ManualTermStopWords.admits("Account"))
        #expect(!ManualTermStopWords.admits("ACCOUNT"))
        #expect(ManualTermStopWords.admits("Lee") && ManualTermStopWords.admits("Ng") && ManualTermStopWords.admits("Kim"),
                "a capitalized word of two or three letters, a short surname, stands alone")
        #expect(!ManualTermStopWords.admits("IBM") && !ManualTermStopWords.admits("the") && !ManualTermStopWords.admits("an"),
                "an all-caps or lowercase short word does not")
        #expect(!ManualTermStopWords.admits("A") && !ManualTermStopWords.admits("I"), "one letter never")
        #expect(ManualTermStopWords.admits("Smith"))
        #expect(ManualTermStopWords.admits("José"))
        #expect(ManualTermStopWords.admits("A1"))
        #expect(ManualTermStopWords.admits("1234-5678"))
        #expect(ManualTermStopWords.admits("Straße"))
    }
}
