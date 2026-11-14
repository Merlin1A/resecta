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
