import Foundation
import Testing
@testable import ResectaApp

// When Search's content leaves the screen, its session is torn down only
// when the sheet really went: not when the session is parked for the Home
// close dialog, and not when the screen-capture cover replaced the content.
@Suite("Search teardown rule")
@MainActor
struct SearchTeardownRuleTests {

    struct Row {
        let parked: Bool
        let covered: Bool
        let tearsDown: Bool
    }

    static let rows: [Row] = [
        Row(parked: false, covered: false, tearsDown: true),
        Row(parked: true, covered: false, tearsDown: false),
        Row(parked: false, covered: true, tearsDown: false),
        Row(parked: true, covered: true, tearsDown: false),
    ]

    @Test("Search's content leaving tears the session down only when it is neither parked nor covered")
    func tearsDownOnlyWhenNeitherParkedNorCovered() {
        #expect(Self.rows.count == 4)
        for row in Self.rows {
            #expect(SearchAndRedactSheet.contentLeavingTearsDown(parked: row.parked, covered: row.covered) == row.tearsDown,
                    "parked \(row.parked), covered \(row.covered)")
        }
    }

    static let guardLine =
        "guard Self.contentLeavingTearsDown(parked: searchState.parkedForHomeClose, covered: captureMonitor.isShielded) else { return }"

    @Test("Search's teardown asks one function whether to tear down")
    func teardownAsksOneFunction() throws {
        let block = try Self.teardownBlock()
        let guards = block.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("guard ")
        }
        #expect(guards.count == 1, "guards between .onDisappear and searchState.clear(): \(guards)")
        #expect(guards.first?.trimmingCharacters(in: .whitespaces) == Self.guardLine)
        let guardAt = try #require(block.range(of: Self.guardLine)).lowerBound
        for call in ["searchState.cancelSearchWithoutAwait()", "searchState.clearLivePreview()"] {
            let at = try #require(block.range(of: call), "\(call) is not in the teardown").lowerBound
            #expect(guardAt < at, "\(call) comes before the guard")
        }
    }

    @Test("While the cover is up the message host still clears the sheet")
    func messageHostClearsTheSheetUnderTheCover() throws {
        let block = try Self.teardownBlock()
        #expect(block.contains("toastBottomClearance(sheetPresented: captureMonitor.isShielded)"))
        #expect(!block.contains("sheetPresented: false"))
    }

    /// The hub file's text from `.onDisappear {` to `searchState.clear()`.
    static func teardownBlock(from file: StaticString = #filePath) throws -> Substring {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/ResectaApp/Views/SearchAndRedactSheet.swift"), encoding: .utf8)
        let start = try #require(source.range(of: ".onDisappear {"), "no .onDisappear in the hub file")
        let end = try #require(source.range(of: "searchState.clear()", range: start.upperBound..<source.endIndex),
                               "no searchState.clear() after .onDisappear")
        return source[start.lowerBound..<end.upperBound]
    }
}
