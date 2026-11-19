import Testing
import Foundation
import SwiftUI
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// The masthead's title and sentence are laid out by `BalancedLines` at the
// narrowest width that keeps their line count. That width must never be
// less than the text's widest unbreakable run (a stretch with no ordinary
// space or line break; a no-break space does not end one), or the text
// breaks inside a word. These tests host the masthead's own builder,
// `BalancedText`, and pin that it is the one place the layout is built.

@Suite("Balanced lines", .tags(.display))
@MainActor
struct BalancedLinesTests {

    typealias Results = VerificationResultsView
    typealias Fixtures = VerificationDebugFixtures

    /// A float tolerance and nothing else: two separate measurements of the
    /// same glyphs may differ in their last bits.
    static let floatTolerance: CGFloat = 0.01

    static let titleFont: Font = .title.bold()
    static let sentenceFont: Font = .subheadline
    static let titleWidths = Array(stride(from: CGFloat(240), through: 400, by: 2))

    /// Every title the masthead can show: each verdict's title, and the
    /// results view's own title for a run with a check that could not verify.
    static var titles: [String] {
        let statuses: [VerificationStatus] = [
            .pass, .info(""), .warn(""), .attention(""), .fail(""), .skipped, .notApplicable(""),
        ]
        let fromStatus = statuses.map(\.title)
        let fromReports = Fixtures.all.values.map { Results.mastheadTitle(report: $0) }
        return Set(fromStatus + fromReports).sorted()
    }

    /// The masthead sentences of the seeded reports that quote no term.
    static var sentences: [String] {
        var found: Set<String> = []
        for report in Fixtures.all.values where !Results.mastheadSubtitleIsPrivacySensitive(report: report) {
            for outputExists in [true, false] {
                if let sentence = Results.mastheadSubtitle(report: report, outputExists: outputExists) {
                    found.insert(sentence)
                }
            }
        }
        return found.sorted()
    }

    /// The unbreakable runs: split on ordinary spaces and line breaks only.
    static func runs(of string: String) -> [String] {
        string.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    static func host<V: View>(_ view: V, _ size: DynamicTypeSize) -> UIHostingController<some View> {
        UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
    }

    static func fit<V: View>(_ host: UIHostingController<V>, width: CGFloat) -> CGSize {
        host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    /// Checks one string in one font at each width, and returns the faults
    /// it saw: the layout narrower than the widest run that fits the line
    /// (a word broken), or a line count unlike the text's own.
    static func check(_ string: String, font: Font, size: DynamicTypeSize,
                      widths: [CGFloat]) -> [String] {
        let widest = runs(of: string)
            .map { fit(host(Text($0).font(font).fixedSize(), size), width: 100_000).width }
            .max() ?? 0
        let balanced = host(BalancedText(string: string, font: font), size)
        let plain = host(Text(string).font(font).multilineTextAlignment(.center), size)
        var faults: [String] = []
        for width in widths {
            let laid = fit(balanced, width: width)
            let alone = fit(plain, width: width)
            if widest <= width, laid.width < widest - floatTolerance {
                faults.append("\"\(string)\" \(size) at \(width): width \(laid.width) < widest run \(widest)")
            }
            if abs(laid.height - alone.height) > floatTolerance {
                faults.append("\"\(string)\" \(size) at \(width): height \(laid.height) != \(alone.height)")
            }
        }
        return faults
    }

    @Test("No title or sentence breaks inside a word, and the line count is the text's own")
    func titlesAndSentencesKeepWholeWords() throws {
        let titles = Self.titles
        let sentences = Self.sentences
        let sizes = DynamicTypeSize.allCases
        try #require(titles.count == 7, "titles: \(titles)")
        try #require(sizes.count == 12)
        try #require(Self.titleWidths.count == 81)
        try #require(!sentences.isEmpty)

        var faults: [String] = []
        var examined = 0
        for size in sizes {
            for title in titles {
                faults += Self.check(title, font: Self.titleFont, size: size, widths: Self.titleWidths)
                examined += Self.titleWidths.count
            }
            for sentence in sentences {
                faults += Self.check(sentence, font: Self.sentenceFont, size: size,
                                     widths: [ResectaTokens.Results.sentenceMaxWidth])
                examined += 1
            }
        }
        print("balanced lines: \(examined) combinations, \(titles.count) titles, "
              + "\(sentences.count) sentences, \(faults.count) faults")
        for fault in faults { print("balanced lines fault: \(fault)") }
        #expect(examined == sizes.count * (titles.count * Self.titleWidths.count + sentences.count))
        #expect(faults.isEmpty, "\(faults.count) faults; first: \(faults.prefix(12).joined(separator: "; "))")
    }

    @Test("The balanced layout is built in one place: the masthead's builder")
    func layoutIsBuiltInOnePlace() throws {
        let sources = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
        let files = try #require(FileManager.default.enumerator(atPath: sources.path))
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
        #expect(files.count > 100, "the source tree was not found")
        var uses: [(file: String, line: Int)] = []
        var builderSpan: [String: ClosedRange<Int>] = [:]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if code.contains("BalancedLines {") { uses.append((file, index)) }
                if line.hasPrefix("struct BalancedText: View {") {
                    let end = lines[(index + 1)...].firstIndex {
                        !$0.isEmpty && !$0.hasPrefix(" ") && !$0.hasPrefix("}")
                    } ?? lines.count
                    builderSpan[file] = index...(end - 1)
                }
            }
        }
        try #require(builderSpan.count == 1, "the builder was not found once: \(builderSpan.keys.sorted())")
        let (builderFile, span) = try #require(builderSpan.first)
        #expect(uses.count == 1, "the layout is built at \(uses.map { "\($0.file):\($0.line + 1)" })")
        for use in uses {
            #expect(use.file == builderFile && span.contains(use.line),
                    "\(use.file):\(use.line + 1) builds the layout outside the builder")
        }
    }
}

// MARK: - The width in plain numbers

/// A wrapping text modelled with numbers: words (split on ordinary spaces
/// only, as the system breaks lines) of character widths, and a space width.
/// Lines fill greedily; a word wider than the line starts a new line and
/// breaks across lines by its characters. Each line is 10 high.
struct WrappingModel {
    let words: [[CGFloat]]
    let space: CGFloat

    var single: CGFloat { words.map { $0.reduce(0, +) }.reduce(0, +) + space * CGFloat(words.count - 1) }

    /// The number of lines at width `w`, and how many words broke inside.
    func lines(at w: CGFloat) -> (count: Int, broken: Int) {
        var count = 0, broken = 0
        var line: CGFloat = 0
        for word in words {
            let width = word.reduce(0, +)
            if count > 0, line + space + width <= w {
                line += space + width
            } else if width <= w {
                count += 1
                line = width
            } else {
                broken += 1
                count += 1
                line = 0
                for character in word {
                    if line > 0, line + character > w {
                        count += 1
                        line = character
                    } else {
                        line += character
                    }
                }
            }
        }
        return (count, broken)
    }

    func height(_ w: CGFloat) -> CGFloat { CGFloat(lines(at: w).count) * 10 }
}

extension BalancedLinesTests {

    /// Today's arithmetic before the floor: the search starts at half the line.
    static func widthBeforeTheFloor(available: CGFloat, model: WrappingModel) -> CGFloat {
        guard model.single > available else { return available }
        let target = model.height(available)
        var low = available / 2, high = available
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if model.height(mid) > target + 0.5 { low = mid } else { high = mid }
        }
        return ceil(high)
    }

    struct Row {
        enum Expect {
            /// Exactly this result.
            case exactly(CGFloat?)
            /// At least this wide, no word broken, the line count at
            /// `available` kept.
            case wholeWords(atLeast: CGFloat)
            /// The same as before the floor.
            case unchanged
        }
        let name: String
        let text: String
        let widths: [Character: CGFloat]
        let space: CGFloat
        let available: CGFloat?
        let expect: [Expect]

        var model: WrappingModel {
            WrappingModel(words: text.split(separator: " ").map { $0.map { widths[$0] ?? 10 } }, space: space)
        }
        /// The floor as the builder measures it: its own runs of the text.
        var floor: CGFloat {
            BalancedText.runs(of: text).map { $0.reduce(0) { $0 + (widths[$1] ?? 10) } }.max() ?? 0
        }
    }

    /// "Checks" is 198 (43, 35, 33, 31, 27, 29) and "Failed" 152, a space
    /// 14: "s Failed" (195) is narrower than "Checks". "Passed" is 170, so
    /// "s Passed" (213) is wider.
    static let letterWidths: [Character: CGFloat] = [
        "C": 43, "h": 35, "e": 33, "c": 31, "k": 27, "s": 29,
        "F": 30, "a": 27, "i": 12, "l": 12, "d": 38, "P": 14,
    ]

    static let rows: [Row] = [
        Row(name: "a word as wide as the tail it would break into", text: "Checks Failed",
            widths: letterWidths, space: 14, available: 360, expect: [.wholeWords(atLeast: 198)]),
        Row(name: "a title that breaks whole today", text: "Checks Passed",
            widths: letterWidths, space: 14, available: 380, expect: [.unchanged, .wholeWords(atLeast: 198)]),
        Row(name: "the default size: one line", text: "Checks Failed",
            widths: letterWidths, space: 14, available: 393, expect: [.exactly(393)]),
        Row(name: "a no-break space keeps its run whole", text: "aaaa\u{00A0}bbbb cccccc",
            widths: ["\u{00A0}": 10], space: 10, available: 150, expect: [.wholeWords(atLeast: 90)]),
        Row(name: "several lines keep their count", text: "aaaa bbbbbbb ccc dddddddd eee ffffff gg hhhhh",
            widths: [:], space: 10, available: 200, expect: [.wholeWords(atLeast: 80)]),
        Row(name: "a run wider than the line", text: "aaaaaaaaaaaaaaaaaaaa bb",
            widths: ["a": 20], space: 10, available: 300.5, expect: [.exactly(300.5)]),
        Row(name: "exactly one line wide", text: "Checks Failed",
            widths: letterWidths, space: 14, available: 364, expect: [.exactly(364)]),
        Row(name: "no width proposed", text: "Checks Failed",
            widths: letterWidths, space: 14, available: nil, expect: [.exactly(nil)]),
    ]

    @Test("The narrowest width keeps whole words, by the table")
    func narrowestWidthTable() {
        var ran = 0
        for row in Self.rows {
            let model = row.model
            let result = BalancedLines.narrowestWidth(
                available: row.available, single: model.single, floor: row.floor, height: model.height)
            for expect in row.expect {
                switch expect {
                case .exactly(let width):
                    #expect(result == width, "\(row.name): \(String(describing: result))")
                case .wholeWords(let atLeast):
                    guard let result, let available = row.available else {
                        Issue.record("\(row.name): no width"); continue
                    }
                    let at = model.lines(at: result)
                    #expect(result >= atLeast, "\(row.name): \(result)")
                    #expect(at.broken == 0, "\(row.name): a word broke at \(result)")
                    #expect(at.count == model.lines(at: available).count, "\(row.name): line count")
                case .unchanged:
                    guard let available = row.available else {
                        Issue.record("\(row.name): no width"); continue
                    }
                    #expect(result == Self.widthBeforeTheFloor(available: available, model: model),
                            "\(row.name): \(String(describing: result))")
                }
            }
            ran += 1
        }
        #expect(ran == 8)
        #expect(BalancedLines.narrowestWidth(available: .infinity, single: 364, floor: 198) { _ in 10 }
                == .infinity)
    }

    @Test("The width is bounded, and unchanged wherever the widest run is at most half the line")
    func resultIsBounded() throws {
        var seed: UInt64 = 0x5EED_0B41
        func next(_ range: ClosedRange<Int>) -> Int {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return range.lowerBound + Int(z % UInt64(range.count))
        }
        var ran = 0, unchangedCases = 0, widerThanLine = 0
        for _ in 0..<500 {
            let words = (0..<next(1...6)).map { _ in (0..<next(1...10)).map { _ in CGFloat(next(4...40)) } }
            let model = WrappingModel(words: words, space: CGFloat(next(4...16)))
            let available = CGFloat(next(20...420)) + (next(0...1) == 1 ? 0.5 : 0)
            let floor = words.map { $0.reduce(0, +) }.max() ?? 0
            let result = try #require(BalancedLines.narrowestWidth(
                available: available, single: model.single, floor: floor, height: model.height))
            #expect(result >= min(available, floor), "\(words) at \(available): \(result)")
            #expect(result <= ceil(available), "\(words) at \(available): \(result)")
            if floor <= available / 2 {
                unchangedCases += 1
                #expect(result == Self.widthBeforeTheFloor(available: available, model: model),
                        "\(words) at \(available): \(result)")
            }
            if floor > available { widerThanLine += 1 }
            ran += 1
        }
        #expect(ran == 500)
        #expect(unchangedCases > 0 && widerThanLine > 0, "\(unchangedCases) unchanged, \(widerThanLine) wider")
    }
}
