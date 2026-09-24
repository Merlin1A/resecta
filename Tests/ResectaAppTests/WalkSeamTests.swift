import Testing
import Foundation
@testable import ResectaApp

// The ONE walk-navigation seam (`SearchAndRedactSheet+Walk.swift`):
// source-slice pins, the estate idiom (`CompactDetentAnchoredRowTests`,
// `TouchTargetFloorTests`). Every caller names the seam; no sheet file
// outside it asks the canvas to scroll; the former inline copies are
// gone.

@Suite("Walk seam")
struct WalkSeamTests {

    @Test("The seam lives in +Walk.swift and is the only canvas-scroll requester among the sheet files")
    func seamIsTheOnlyRequester() throws {
        let walk = try loadRepoFile("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+Walk.swift")
        #expect(walk.contains("func focusWalk(on id: UUID?, parking: Bool)"))
        #expect(walk.contains("func focusWalk(onPage page: Int, normalizedRect: CGRect, parking: Bool)"))
        #expect(walk.contains("requestCanvasScroll("))
        #expect(walk.contains("anchor: parking ? .center : .visible"))
        for path in [
            "Sources/ResectaApp/Views/SearchAndRedactSheet.swift",
            "Sources/ResectaApp/Views/Search/SearchResultsSection.swift",
            "Sources/ResectaApp/Views/Search/ScanReviewSection.swift",
            "Sources/ResectaApp/Views/Search/SearchAndRedactSheet+Trigger.swift",
            "Sources/ResectaApp/Views/Search/SearchAndRedactSheet+CompactApply.swift",
        ] {
            let source = try loadRepoFile(path)
            #expect(!source.contains("requestCanvasScroll("),
                    "\(path) must route canvas scrolls through the walk seam")
            #expect(!source.contains("navigateToCurrentResult"),
                    "\(path) must not carry the retired inline seam")
        }
    }

    @Test("Every caller names the seam: the chevrons, the results section wiring, the review row tap")
    func everyCallerNamesTheSeam() throws {
        let hub = try loadRepoFile("Sources/ResectaApp/Views/SearchAndRedactSheet.swift")
        let cluster = try slice(hub,
                                from: "private func resultNavCluster(",
                                to: "private var resultNavCounter: some View {")
        #expect(cluster.components(separatedBy: "focusWalk(on: searchState.currentResult?.id, parking: true)").count - 1 == 2,
                "both chevrons step then focus through the seam")
        #expect(hub.contains("onFocusWalk: focusWalk(on:parking:)"),
                "the results section is wired to the seam")
        #expect(hub.contains("focusWalk(onPage: page, normalizedRect: normalizedRect, parking: true)"),
                "the review row tap routes through the seam's canvas half")
        let section = try loadRepoFile("Sources/ResectaApp/Views/Search/SearchResultsSection.swift")
        #expect(section.contains("let onFocusWalk: (UUID, Bool) -> Void"))
        #expect(section.contains("onFocusWalk(result.id, true)"), "the row tap parks through the seam")
        #expect(section.components(separatedBy: "onFocusWalk(id, false)").count - 1 == 2,
                "J and K keep the keyboard rule through the seam")
        #expect(!section.contains("selectedDetent = .compactFloat"),
                "the section no longer writes the parking detent itself")
    }

    // MARK: - Helpers (TouchTargetFloorTests' loadRepoFile idiom)

    private struct SliceMissing: Error {}

    private func slice(_ source: String, from start: String, to end: String) throws -> Substring {
        guard let s = source.range(of: start),
              let e = source.range(of: end, range: s.upperBound..<source.endIndex)
        else { throw SliceMissing() }
        return source[s.lowerBound..<e.lowerBound]
    }

    private func loadRepoFile(
        _ relativePath: String, from file: StaticString = #filePath
    ) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}
