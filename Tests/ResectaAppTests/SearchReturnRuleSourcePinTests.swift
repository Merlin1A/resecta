import Testing
import Foundation
@testable import ResectaApp

// Two pins on source text, for two mistakes no behavior test can see.
//
// The Return rule (`SearchState.returnStartsRun`) compares what the field
// would search for with what the last run searched for. That holds only
// while (1) the run records what it searched for on the line after the
// one that builds its engine query, with nothing between that could let
// the two differ, and (2) the record holds every session member the
// engine query is built from. Each pin names its source file once; a
// change that moves the code moves the name with it.

@Suite("Return rule: source pins")
struct SearchReturnRuleSourcePinTests {

    /// The file that holds the run's setup (`prepareSearchRun()`).
    static let runSetupFile = "Views/Search/SearchAndRedactSheet+Trigger.swift"
    /// The file that holds `buildSearchMode()`.
    static let queryBuilderFile = "Views/SearchAndRedactSheet.swift"
    /// The file that holds `currentRunShape`.
    static let shapeFile = "State/SearchState+ReturnRule.swift"

    static let queryLine = "let mode = buildSearchMode()"
    static let recordLine = "searchState.lastRunShape = searchState.currentRunShape"

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The lines of the first declaration that starts with `opening`, up
    /// to the line that closes it at the same indentation.
    private func body(of opening: String, in text: String) throws -> [Substring] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = try #require(
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(opening) },
            "\(opening) was not found")
        let indent = lines[start].prefix { $0 == " " }
        let end = try #require(
            lines[(start + 1)...].firstIndex { $0 == indent + "}" },
            "the end of \(opening) was not found")
        return Array(lines[(start + 1)..<end])
    }

    /// The code of each line, its comment cut off: a whole-line comment
    /// reads as empty, and a trailing `//` comment is dropped. (The bodies
    /// pinned here hold no string literal with `//` in it.)
    private func code(_ lines: [Substring]) -> [String] {
        lines.map { line in
            let text = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)
            return text.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Every name a stretch of code reads a member of (`name.member`). An
    /// enum case written with a leading dot (`.text(…)`) is not a read: no
    /// name stands before its dot.
    private func receivers(in lines: [Substring]) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: "(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)\\.[A-Za-z_]")
        var found = Set<String>()
        for line in code(lines) {
            let range = NSRange(line.startIndex..., in: line)
            for match in pattern.matches(in: line, range: range) {
                if let name = Range(match.range(at: 1), in: line) { found.insert(String(line[name])) }
            }
        }
        return found
    }

    /// The session members a stretch of code reads, by name.
    private func members(readFrom receiver: String, in lines: [Substring]) -> Set<String> {
        var found = Set<String>()
        for text in code(lines) {
            if text.isEmpty { continue }
            var rest = Substring(text)
            while let range = rest.range(of: receiver + ".") {
                let name = rest[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { found.insert(String(name)) }
                rest = rest[range.upperBound...]
            }
        }
        return found
    }

    @Test("The run records what it searched for on the line after the one that builds its query")
    func recordSitsBesideTheQuery() throws {
        let lines = try source(Self.runSetupFile)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let queryLines = lines.indices.filter { lines[$0] == Self.queryLine }
        #expect(queryLines.count == 1, "expected one line building the query, saw \(queryLines.count)")
        let at = try #require(queryLines.first)
        let next = try #require(lines[(at + 1)...].first { !$0.isEmpty }, "nothing follows the query line")
        #expect(next.hasPrefix(Self.recordLine), "after the query line comes: \(next)")
        #expect(lines.filter { $0.hasPrefix(Self.recordLine) }.count == 1, "the record is written in more than one place")
    }

    @Test("The record holds every session member the query is built from")
    func shapeHoldsTheQueryInputs() throws {
        let builderBody = try body(of: "func buildSearchMode() -> SearchMode {", in: try source(Self.queryBuilderFile))
        // The session is the one object the query is built from: an input
        // read from any other object would pass the member check below.
        let readFrom = try receivers(in: builderBody)
        #expect(readFrom == ["searchState"], "buildSearchMode() reads members of \(readFrom.sorted())")
        let builder = members(readFrom: "searchState", in: builderBody)
        #expect(builder == ["options", "searchModeType", "queryText", "searchTerms", "effectiveScanCategories"],
                "buildSearchMode() reads \(builder.sorted())")

        let shape = code(try body(of: "var currentRunShape: SearchRunShape {", in: try source(Self.shapeFile)))
        let names = ["searchModeType", "queryText", "searchTerms", "options"]
        let read = Set(names.filter { name in shape.contains { $0.contains(name) } })
        #expect(read == Set(names), "currentRunShape reads \(read.sorted())")

        // Scan's kinds are the one input the record leaves out: Scan has
        // no field, so the rule is never asked there.
        #expect(builder.subtracting(read) == ["effectiveScanCategories"])
    }
}
