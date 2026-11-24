import Testing
import Foundation
@testable import ResectaApp

// The Search and Scan sheet's text tiers. Small text a person reads in the
// sheet's files takes the darker support grey, never the system's secondary
// or tertiary colour, which measure under the contrast floor at these sizes.
// Symbols, outlines, fills and disabled controls keep the system grey: they
// are the exact allow-list below, with a count for each line, so a line that
// leaves the list must lower its entry. The sheet's own teal words take the
// teal text tier. These read the source; they do not measure a colour.

@Suite("Search sheet text tiers")
struct SearchSheetTextTierTests {

    static let files = [
        "Views/SearchAndRedactSheet.swift",
        "Views/SearchResultRow.swift",
        "Views/SearchResultRow+Contracts.swift",
        "Views/Search/SearchToolbarSection.swift",
        "Views/Search/SearchToolbarSection+Scan.swift",
        "Views/Search/SearchResultsSection.swift",
        "Views/Search/SearchSheetHeaderSection.swift",
        "Views/Search/SearchFooterSection.swift",
        "Views/Search/SavedSearchListSheet.swift",
        "Views/Search/SearchResultsBanners.swift",
        "Views/Search/SearchAndRedactSheet+CompactApply.swift",
        "Views/Search/SearchAndRedactSheet+SearchBar.swift",
        "Views/Search/SearchAndRedactSheet+GrabberPulse.swift",
        "Views/Search/SearchAndRedactSheet+ResultNavigation.swift",
        "Views/Search/SearchAndRedactSheet+LivePreview.swift",
        "Views/Search/SearchAndRedactSheet+DegradeBanner.swift",
        "Views/Search/SearchAndRedactSheet+SaveRegex.swift",
        "Views/Search/SearchModal.swift",
    ]

    /// The lines that keep the system grey: (file, line trimmed, how many, why).
    static let allowList: [(file: String, line: String, count: Int, reason: String)] = [
        ("Views/Search/SearchAndRedactSheet+SearchBar.swift", ".foregroundStyle(.secondary)", 1, "the stop glyph in the field"),
        ("Views/Search/SearchAndRedactSheet+GrabberPulse.swift", ".fill(Color.secondary.opacity(0.4))", 1, "the grabber's fill"),
        ("Views/SearchResultRow.swift",
         ".foregroundStyle(result.isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))", 1,
         "the empty selection circle"),
        ("Views/SearchResultRow.swift", ".foregroundStyle(.secondary)", 1, "the row's arrow"),
        ("Views/Search/SearchToolbarSection.swift",
         ".overlay(Capsule().strokeBorder(isTinted ? ResectaTokens.BrandTeal.tint : Color.secondary.opacity(0.3)))", 1,
         "the menu chip's outline"),
        ("Views/Search/SearchToolbarSection.swift", ".foregroundStyle(.secondary)", 1, "the saved-pattern menu's glyph"),
        ("Views/Search/SearchResultsSection.swift", ".foregroundStyle(.secondary)", 1, "the live row's eye glyph"),
        ("Views/Search/SearchSheetHeaderSection.swift", "? AnyShapeStyle(.tertiary)", 1, "Apply when it is disabled"),
        ("Views/Search/SearchAndRedactSheet+CompactApply.swift", ".foregroundStyle(.secondary)", 1,
         "Applied on the parked strip, a disabled control"),
    ]

    private static func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Lines that are not whole-line comments, trimmed of their indentation.
    private static func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    @Test("No system grey on text in the Search sheet's files")
    func noSystemGreyOnText() throws {
        #expect(Self.files.count == 18)
        #expect(Self.allowList.reduce(0) { $0 + $1.count } == 9)
        var found: [String: Int] = [:]
        for file in Self.files {
            let text = try Self.source(file)
            #expect(!text.isEmpty, "\(file) read as empty")
            for line in Self.codeLines(text) where line.contains(".secondary") || line.contains(".tertiary") {
                found["\(file) | \(line)", default: 0] += 1
            }
        }
        var allowed: [String: Int] = [:]
        for entry in Self.allowList { allowed["\(entry.file) | \(entry.line)", default: 0] += entry.count }
        for (key, count) in found.sorted(by: { $0.key < $1.key }) {
            #expect(count == (allowed[key] ?? 0), "\(key): \(count) in the source, \(allowed[key] ?? 0) allowed")
        }
        for (key, count) in allowed.sorted(by: { $0.key < $1.key }) where found[key] == nil {
            Issue.record("\(key): allowed \(count), but no such line is in the source")
        }
    }

    @Test("The sheet's own teal words use the text tier")
    func tealWordsUseTheTextTier() throws {
        let header = Self.codeLines(try Self.source("Views/Search/SearchSheetHeaderSection.swift"))
        #expect(!header.contains { $0.contains(".foregroundStyle(.tint)") })
        #expect(!header.contains { $0.contains("AnyShapeStyle(.tint)") })

        let row = Self.codeLines(try Self.source("Views/SearchResultRow.swift"))
        #expect(!row.contains { $0.contains(".foregroundStyle(.tint)") })
        #expect(row.filter { $0.contains("AnyShapeStyle(.tint)") }.count == 1, "only the ticked circle keeps the tint")

        let hub = try Self.source("Views/Search/SearchAndRedactSheet+SearchBar.swift")
        let start = try #require(hub.range(of: "static func circularIconLabel("))
        let end = try #require(hub.range(of: "\n    }\n", range: start.upperBound..<hub.endIndex))
        #expect(!hub[start.upperBound..<end.lowerBound].contains(".foregroundStyle(.tint)"),
                "the round buttons' glyphs use the text tier")
    }
}
