import Testing
import Foundation
import CoreGraphics
import PDFKit

// The two clear-page fixtures (Scripts/generate_uitest_clear_page.py) are
// what their screen tests take them for: each opens; its page has the stated
// size, crop box and rotation; a search for the one word returns exactly one
// match, centred as displayed within 2 pt of the stated point; no other text
// lies in the clear block; no text lies within 16 pt of the left or the top
// edge as displayed. The map from the stored page to the page as displayed is
// worked out here by hand, apart from the app's own geometry.

@Suite("The clear-page fixtures")
struct UITestClearPageFixtureTests {

    struct Fixture: CustomTestStringConvertible, Sendable {
        let name: String
        let media: CGRect
        let crop: CGRect
        let rotation: Int
        /// The page as displayed, y up from its bottom-left corner.
        let displayed: CGSize
        let clearBlock: CGRect
        let wordCentre: CGPoint
        var testDescription: String { name }

        /// A rectangle on the stored page, as displayed.
        func displayedRect(_ r: CGRect) -> CGRect {
            switch rotation {
            case 0:
                return r.offsetBy(dx: -crop.minX, dy: -crop.minY)
            case 90:
                // Shown a quarter clockwise: the stored bottom edge is the left
                // edge as displayed, and the stored right edge its bottom.
                return CGRect(x: r.minY - crop.minY, y: crop.maxX - r.maxX, width: r.height, height: r.width)
            default:
                Issue.record("no map written for rotation \(rotation)")
                return .null
            }
        }
    }

    nonisolated static let fixtures = [
        Fixture(name: "uitest_clear_page", media: CGRect(x: 0, y: 0, width: 612, height: 792),
                crop: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0,
                displayed: CGSize(width: 612, height: 792),
                clearBlock: CGRect(x: 156, y: 246, width: 300, height: 300), wordCentre: CGPoint(x: 214, y: 515)),
        Fixture(name: "uitest_clear_page_turned", media: CGRect(x: 0, y: 0, width: 612, height: 792),
                crop: CGRect(x: 36, y: 54, width: 540, height: 684), rotation: 90,
                displayed: CGSize(width: 684, height: 540),
                clearBlock: CGRect(x: 192, y: 170, width: 300, height: 200), wordCentre: CGPoint(x: 239, y: 351)),
    ]

    static let word = "Wrenlowe"

    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the repository
            .appendingPathComponent("UITestFixtures/\(name).pdf")
    }

    @Test("Each clear-page fixture is the page its screen tests take it for", arguments: fixtures)
    func fixtureIsAsStated(_ f: Fixture) throws {
        let document = try #require(PDFDocument(url: Self.url(f.name)), "\(f.name) opens")
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        #expect(page.bounds(for: .mediaBox) == f.media)
        #expect(page.bounds(for: .cropBox) == f.crop)
        #expect(page.rotation == f.rotation)
        let shown = f.displayedRect(f.crop)
        #expect(shown.size == f.displayed && shown.origin == .zero)

        // The one word: one match, centred where stated.
        let matches = document.findString(Self.word, withOptions: [])
        #expect(matches.count == 1, "\(matches.count) matches")
        let match = try #require(matches.first)
        let box = f.displayedRect(match.bounds(for: page))
        #expect(abs(box.midX - f.wordCentre.x) <= 2 && abs(box.midY - f.wordCentre.y) <= 2,
                "the word's centre as displayed is \(box.midX), \(box.midY)")
        // Its width along the line, which the screen test reads the scale by:
        // Helvetica's advances for the word at 12 pt.
        #expect(abs(box.width - 53.34) <= 0.5, "the word's box is \(box.width) wide as displayed")

        // Every other letter: outside the clear block, and clear of the left
        // and top edges as displayed.
        let text = try #require(page.string) as NSString
        var inBlock = ""
        var letters = 0
        for i in 0..<text.length {
            let character = text.substring(with: NSRange(location: i, length: 1))
            guard !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // A one-letter selection's bounds, in the stored page's space.
            // (`characterBounds(at:)` is not: on these pages it runs an index
            // off the string, and on a turned page it comes back turned.)
            guard let r = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page),
                  !r.isNull, !r.isEmpty else { continue }
            letters += 1
            let d = f.displayedRect(r)
            if f.clearBlock.contains(CGPoint(x: d.midX, y: d.midY)) { inBlock += character }
            #expect(d.minX >= 16 && d.maxY <= f.displayed.height - 16,
                    "'\(character)' at \(d) lies within 16 pt of the left or top edge")
        }
        #expect(inBlock == Self.word, "the clear block holds \"\(inBlock)\"")
        #expect(letters > 60, "the page has a text layer around the block (\(letters) letters)")
    }
}
