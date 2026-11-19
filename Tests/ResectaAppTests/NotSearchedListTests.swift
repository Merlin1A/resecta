import Testing
import SwiftUI
import UIKit
@testable import ResectaApp

// The shared list of pages a search did not read: what it draws from its
// content, how it shortens a search name, how many page chips fit on a
// row's line, and renders for the reviewer. Every expectation is this
// list's case table, written out, not derived from the code under test.

@Suite("Not Searched list")
struct NotSearchedListTests {

    typealias Content = NotSearchedListContent
    typealias Row = NotSearchedListContent.Row
    typealias Section = NotSearchedListContent.Section
    typealias NameLine = NotSearchedListContent.NameLine

    static let rowA = Row(sentence: "Include OCR Pages was off, so 2 pages were not read: 2 and 3.", pages: [1, 2])
    static let rowB = Row(sentence: "Page 5 is a picture with no text.", pages: [4])
    static let rowC = Row(sentence: "The search stopped before pages 3 and 9.", pages: [2, 8])
    static let named = NameLine(shown: "For your search for \u{201C}Hartwell\u{201D}:",
                                spoken: "For your search for \u{201C}Hartwell\u{201D}:")
    static let small = "Small pictures were not read."

    static var sources: URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
    }

    /// A source file's lines with comment lines left out.
    static func codeLines(_ path: String) throws -> [String] {
        let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    // MARK: - 1, 2: the items

    @Test("The list draws its content's sections and rows in order, once each")
    func sectionsAndRowsInOrder() {
        let cases: [(String, Content, Bool, [NotSearchedListItem])] = [
            ("N-1", Content(sections: [Section(nameLine: nil, rows: [Self.rowA])], smallPicturesLine: nil), true,
             [.header, .row(Self.rowA, hairlineAbove: false)]),
            ("N-2", Content(sections: [Section(nameLine: nil, rows: [Self.rowB]),
                                       Section(nameLine: Self.named, rows: [Self.rowC])], smallPicturesLine: nil), true,
             [.header, .row(Self.rowB, hairlineAbove: false), .nameLine(Self.named), .row(Self.rowC, hairlineAbove: false)]),
            // Two rows of one section, not in page order: drawn as given.
            ("N-3", Content(sections: [Section(nameLine: nil, rows: [Self.rowC, Self.rowA])], smallPicturesLine: nil), true,
             [.header, .row(Self.rowC, hairlineAbove: false), .row(Self.rowA, hairlineAbove: true)]),
            ("N-7", Content(sections: [Section(nameLine: nil, rows: [Self.rowA])], smallPicturesLine: nil), false,
             [.row(Self.rowA, hairlineAbove: false)]),
        ]
        for (name, content, header, expected) in cases {
            #expect(NotSearchedList.items(for: content, showsHeader: header) == expected, "\(name)")
        }
        #expect(cases.count == 4)
    }

    @Test("Header first, naming lines before their rows, the small-pictures line last, nothing for an empty list")
    func headerNamingLinesAndTheLastLine() {
        let noPages = Row(sentence: "One match could not be boxed.", pages: [])
        let cases: [(String, Content, [NotSearchedListItem])] = [
            ("N-4", Content(sections: [Section(nameLine: nil, rows: [Self.rowA])], smallPicturesLine: Self.small),
             [.header, .row(Self.rowA, hairlineAbove: false), .smallPictures(Self.small)]),
            ("N-5", Content(sections: [], smallPicturesLine: Self.small),
             [.header, .smallPictures(Self.small)]),
            ("N-6", Content(sections: [], smallPicturesLine: nil), []),
            ("N-8", Content(sections: [Section(nameLine: nil, rows: [noPages])], smallPicturesLine: nil),
             [.header, .row(noPages, hairlineAbove: false)]),
        ]
        for (name, content, expected) in cases {
            #expect(NotSearchedList.items(for: content, showsHeader: true) == expected, "\(name)")
        }
        // N-8: a row with no pages has no chip line.
        #expect(NotSearchedList.chipLine(chipWidths: [], moreWidth: 60, available: 338)
                == NotSearchedList.ChipLine(shown: 0, more: nil))
        #expect(cases.count == 4)
    }

    // MARK: - 3: a shortened name

    @Test("A long search name is shortened to 40 characters only where the rule allows")
    func longNameShortenedWhereAllowed() {
        let sixty = String(repeating: "a", count: 39) + String(repeating: "b", count: 21)
        let twin = String(repeating: "a", count: 39) + String(repeating: "c", count: 21)
        let forty = String(repeating: "d", count: 40)
        let fortyOne = String(repeating: "d", count: 41)
        let accent = "e\u{0301}"   // one Character, two scalars
        let fortyWithAccent = String(repeating: "f", count: 39) + accent
        let fortyOneAccentAt39 = String(repeating: "g", count: 38) + accent + "hh"
        let cases: [(String, String, Bool, [String], String)] = [
            ("S-1", sixty, true, [], String(repeating: "a", count: 39) + "\u{2026}"),
            ("S-2", sixty, false, [], sixty),
            ("S-3", sixty, true, [twin], sixty),
            ("S-4 forty", forty, true, [], forty),
            ("S-4 forty-one", fortyOne, true, [], String(repeating: "d", count: 39) + "\u{2026}"),
            ("S-5a", fortyWithAccent, true, [], fortyWithAccent),
            ("S-5b", fortyOneAccentAt39, true, [], String(repeating: "g", count: 38) + accent + "\u{2026}"),
        ]
        #expect(fortyWithAccent.count == 40 && fortyWithAccent.unicodeScalars.count == 41)
        for (name, input, button, others, expected) in cases {
            let shown = NotSearchedList.shownName(input, sectionHasButton: button, otherNames: others)
            #expect(Array(shown.unicodeScalars) == Array(expected.unicodeScalars), "\(name): \(shown)")
        }
        // S-3 both ways: the twin is shown whole beside the first.
        #expect(NotSearchedList.shownName(twin, sectionHasButton: true, otherNames: [sixty]) == twin)
        #expect(cases.count == 7)
    }

    // MARK: - 4, 5: the chip line

    @Test("A row shows the page chips that fit, at most five, else one fewer and the count of the rest")
    func chipsThatFit() {
        let w70 = { (n: Int) in Array(repeating: 70, count: n) }
        let cases: [(String, [Int], Int, Int, NotSearchedList.ChipLine)] = [
            ("C-1", [62, 62, 62], 60, 308, .init(shown: 3, more: nil)),
            ("C-2", w70(5), 60, 400, .init(shown: 5, more: nil)),
            ("C-3", w70(6), 60, 400, .init(shown: 4, more: 2)),
            ("C-4", w70(12), 60, 308, .init(shown: 3, more: 9)),
            ("C-5", w70(5), 60, 381, .init(shown: 3, more: 2)),
            ("C-6", w70(3), 60, 150, .init(shown: 1, more: 2)),
            ("C-7", w70(6), 90, 230, .init(shown: 1, more: 5)),
            ("C-8", w70(1), 60, 60, .init(shown: 0, more: nil)),
            ("C-9", [], 60, 308, .init(shown: 0, more: nil)),
            ("C-10", w70(2), 60, 100, .init(shown: 1, more: nil)),
            ("C-11", Array(repeating: 60, count: 5), 150, 200, .init(shown: 3, more: nil)),
        ]
        for (name, widths, more, available, expected) in cases {
            #expect(NotSearchedList.chipLine(chipWidths: widths, moreWidth: more, available: available) == expected,
                    "\(name)")
        }
        #expect(cases.count == 11)
    }

    @Test("The count of the rest reads as the results screen's")
    func countReadsAsTheResultsScreens() {
        var compared = 0
        for n in 6...9 {
            #expect(NotSearchedList.moreText(n - 4) == LayerResultRow.moreChipsText(Array(0..<n)), "\(n) pages")
            compared += 1
        }
        #expect(NotSearchedList.moreText(8) == "+8\u{00A0}more")
        #expect(compared == 4)
    }

    // MARK: - 6, 7: what the list reads, and a chip's tap

    @Test("The list's file reads no match text and changes nothing when it leaves the screen")
    func noMatchTextNoLeavingWork() throws {
        let lines = try Self.codeLines("Views/Messages/NotSearchedList.swift")
        #expect(lines.count > 50, "the list's file was not read")
        for word in ["SearchResult", "matchedText", "contextSnippet", "onDisappear"] {
            #expect(!lines.contains { $0.contains(word) }, "the list's file names \(word)")
        }
    }

    @Test("A page chip hands its page to the caller and nothing else")
    func chipHandsItsPage() {
        var received: [Int] = []
        let content = Content(sections: [Section(nameLine: nil, rows: [Self.rowA])], smallPicturesLine: nil)
        let before = content
        let tap = NotSearchedList.chipAction(page: 2) { received.append($0) }
        tap()
        #expect(received == [2])
        #expect(content == before)
    }

    // MARK: - 8: renders

    @Test("Renders of the list for the reviewer")
    @MainActor
    func rendersForTheReviewer() throws {
        let twelve = Row(sentence: "The search stopped early, so 12 pages were not read.", pages: Array(10..<22))
        let content = Content(sections: [Section(nameLine: nil, rows: [Self.rowB]),
                                         Section(nameLine: Self.named, rows: [Self.rowC, twelve])],
                              smallPicturesLine: Self.small)
        var renders = 0
        for header in [true, false] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility5] {
                    let image = Self.render(NotSearchedList(content: content, showsHeader: header, goToPage: { _ in })
                        .environment(\.dynamicTypeSize, size), style: style, width: 338)
                    let name = "not-searched-\(header ? "header" : "no-header")-\(style == .dark ? "dark" : "light")-\(size == .large ? "large" : "ax5")"
                    #expect(image.size.width == 338, "\(name): \(image.size)")
                    #expect(image.size.height >= 60, "\(name): \(image.size)")
                    #expect(Self.distinctPixelValues(image) >= 2, "\(name) is one flat colour")
                    if let data = image.pngData() {
                        Attachment.record(data, named: "\(name).png")
                    }
                    renders += 1
                }
            }
        }
        #expect(renders == 8)
    }

    /// The view hosted in a window at `width`, laid out until its measures
    /// settle, then drawn.
    @MainActor
    static func render<V: View>(_ view: V, style: UIUserInterfaceStyle, width: CGFloat) -> UIImage {
        let host = UIHostingController(rootView: view.background(Color(.systemBackground)))
        host.overrideUserInterfaceStyle = style
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 2000))
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.isHidden = false
        for _ in 0..<4 {
            let fitted = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: max(1, fitted.height.rounded(.up)))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }

    /// How many different pixel values the image holds, up to 2.
    static func distinctPixelValues(_ image: UIImage) -> Int {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let step = cg.bitsPerPixel / 8
        let count = CFDataGetLength(data) / max(1, step)
        guard count > 0, step > 0 else { return 0 }
        let first = (0..<step).map { bytes[$0] }
        for pixel in 1..<count where (0..<step).contains(where: { bytes[pixel * step + $0] != first[$0] }) {
            return 2
        }
        return 1
    }

    // MARK: - 9, 10: the caution mark's colour

    @Test("The list's caution mark takes the message surface's own colour")
    func markTakesTheMessageSurfaceColour() throws {
        let lines = try Self.codeLines("Views/Messages/NotSearchedList.swift")
        #expect(lines.contains { $0.contains("Ink.cautionMark") })
        #expect(!lines.contains { $0.contains("SemanticColor.warnText") })
    }

    @Test("The message surfaces' caution mark keeps its own two values")
    func cautionMarkKeepsItsTwoValues() throws {
        for (style, hex) in [(UIUserInterfaceStyle.light, UInt32(0x9A5B00)), (.dark, UInt32(0xFF9F0A))] {
            let resolved = UIColor(ResectaTokens.Ink.cautionMark).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            #expect(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
            let expected = [CGFloat((hex >> 16) & 0xFF), CGFloat((hex >> 8) & 0xFF), CGFloat(hex & 0xFF)].map { $0 / 255 }
            let tolerance: CGFloat = 1.0 / 255.0
            #expect(abs(r - expected[0]) <= tolerance && abs(g - expected[1]) <= tolerance
                    && abs(b - expected[2]) <= tolerance && abs(a - 1) <= tolerance,
                    "\(style == .dark ? "dark" : "light"): \(r * 255), \(g * 255), \(b * 255)")
        }
        let tokenLines = try Self.codeLines("Design/ResectaTokens+Ink.swift")
        #expect(tokenLines.count > 10, "the token file was not read")
        #expect(!tokenLines.contains { $0.contains("SemanticColor.") })
    }
}
