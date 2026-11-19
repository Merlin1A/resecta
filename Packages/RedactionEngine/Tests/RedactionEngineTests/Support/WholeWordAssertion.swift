import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

/// The assertion every Searchable export of the whole-word suites runs, at
/// each set of painted rectangles a fixture is given:
/// - every hand-listed boxed word is absent from the hidden text, and no
///   kept letter's own box meets an ordinary rectangle;
/// - no kept letter's middle shares area with a painted rectangle or a
///   plan's rectangle;
/// - read back from the written page at the place it is drawn, no hidden
///   character's centre lies in a painted rectangle.
/// The written page is made by the writer's own call, from the text path's
/// list and its laid-out lines, and read back with PDFKit.
enum WholeWordAssertion {

    /// A page the text path wrote, read back.
    struct Written {
        let entries: [CharacterInfo]
        let text: String
        /// Each non-space character read back, with its box on the page.
        let readBack: [(character: String, box: CGRect)]
    }

    /// Writes `path`'s list as the writer does and reads the page back. Nil
    /// when the path made the page a picture.
    static func write(_ path: PageTextPath.Result, frame: PageFrame) throws -> Written? {
        guard case .written(let entries, _, let rects) = path.outcome else { return nil }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: frame.displayedSize)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        TextLayerReconstructor.drawInvisibleTextLayer(
            context: context, entries: entries, pageSize: frame.displayedSize,
            redactionRects: rects, rotation: frame.rotation, laidOut: path.hiddenTextLines)
        context.endPDFPage()
        context.closePDF()
        let page = try #require(PDFDocument(data: data as Data)?.page(at: 0))
        let text = page.string ?? ""
        var readBack: [(character: String, box: CGRect)] = []
        let ns = text as NSString
        var index = 0
        while index < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: index)
            let character = ns.substring(with: range)
            if !character.allSatisfy(\.isWhitespace) {
                readBack.append((character, page.characterBounds(at: range.location)))
            }
            index = range.location + range.length
        }
        return Written(entries: entries, text: text, readBack: readBack)
    }

    /// The hidden text's words: split at white space, each trimmed of the
    /// punctuation at its ends.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map {
            String($0).trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
    }

    /// The three clauses on one written page. `boxedWords` is the fixture's
    /// hand-written list; `rectangles` the text-path rectangles handed in.
    static func holds(
        _ written: Written, boxedWords: [String], rectangles: [TextPathRectangle],
        painted: [CGRect], frame: PageFrame, _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let hidden = Set(words(written.text))
        for word in boxedWords {
            #expect(!hidden.contains(word), "\(comment): the boxed word \(word) is in the hidden text",
                    sourceLocation: sourceLocation)
        }
        let ordinary = rectangles.filter { $0.kind == .ordinary }.map(\.rect)
        let plans = rectangles.filter { $0.kind == .plansRectangle }.map(\.rect)
        for entry in written.entries where !entry.character.allSatisfy(\.isWhitespace) {
            #expect(!ordinary.contains { $0.intersects(entry.bounds) },
                    "\(comment): \(entry.character) at \(entry.bounds) meets an ordinary rectangle",
                    sourceLocation: sourceLocation)
            #expect(!(painted + plans).contains { TextPathPaintMarks.middleUnder($0, entry, frame: frame) },
                    "\(comment): the middle of \(entry.character) at \(entry.bounds) is under paint or a plan's rectangle",
                    sourceLocation: sourceLocation)
        }
        for (character, box) in written.readBack {
            let centre = CGPoint(x: box.midX, y: box.midY)
            #expect(!painted.contains { $0.contains(centre) },
                    "\(comment): \(character) is drawn with its centre under paint at \(box)",
                    sourceLocation: sourceLocation)
        }
    }
}
