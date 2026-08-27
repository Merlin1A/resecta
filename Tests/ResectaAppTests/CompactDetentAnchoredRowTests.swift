import Testing
import Foundation
import SwiftUI
@testable import ResectaApp

// WU-28 → WA/D-75 → UXC-44 → UXC-51: pin the compact float detent's
// pure-function height (fixed handle hug — title + result-nav
// cluster since UXC-44, plus the per-item Apply since UXC-51 —
// clamped to the available height), the amended handle composition
// (source scan), and the detent-identity contract the anchored-row
// mechanism relies on.
// The ScrollViewReader anchor itself is driven from a SwiftUI
// `.onChange` and cannot run in a unit test without a UI host — these
// tests cover the parts that can be isolated as values.

@Suite("Compact float detent (WU-28)")
struct CompactDetentAnchoredRowTests {
    @Test("Hug height is constant across screen heights")
    func hugHeightConstantAcrossScreens() {
        // iPhone SE (568pt) / iPhone 17 (~844pt) / iPad-class (1024pt):
        // the title-only hug does not scale with the screen.
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 568) == CompactFloatDetent.hugHeight)
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 844) == CompactFloatDetent.hugHeight)
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 1024) == CompactFloatDetent.hugHeight)
    }

    @Test("Hug constant matches the WA/D-75 handle contract as amended by UXC-44 and UXC-51")
    func hugConstantMatchesContract() {
        // UXC-51 (D-128, RB-123 item 8; REV-18): 15-pt grabber inset +
        // the handle row's 46-pt layout floor (Apply · title · cluster)
        // + breathing room — the handle grows slightly with the Apply
        // on board, tuned on the iPhone 17 and 17e sims. Was 60 under
        // the D-75 title-only handle, 72 under the UXC-44 cluster
        // handle.
        #expect(CompactFloatDetent.hugHeight == 80)
    }

    @Test("The compact handle mounts the result-nav cluster, which carries resultNavNext (UXC-44 amends D-75)")
    func compactStripCarriesResultNavCluster() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/SearchAndRedactSheet.swift")
        // The strip's body: from its declaration to the next MARK.
        let strip = try slice(source,
                              from: "private var compactFloatStrip: some View {",
                              to: "// MARK: - Search Bar")
        #expect(strip.contains("resultNavCluster("),
                "compactFloatStrip must mount the shared result-nav cluster builder")
        #expect(strip.contains("accessibilityIdentifier(\"compactFloatStrip\")"),
                "compactFloatStrip must keep its identifier")
        // The builder both sites share carries the ids — so the compact
        // handle carries resultNavNext by construction.
        let cluster = try slice(source,
                                from: "private func resultNavCluster(",
                                to: "private var resultNavCounter: some View {")
        #expect(cluster.contains("accessibilityIdentifier(\"resultNavNext\")"),
                "resultNavCluster must carry the resultNavNext identifier")
        #expect(cluster.contains("accessibilityIdentifier(\"resultNavPrevious\")"),
                "resultNavCluster must carry the resultNavPrevious identifier")
    }

    @Test("The compact handle mounts the per-item Apply, which carries applyCurrentResultButton (UXC-51 amends D-75 again)")
    func compactStripCarriesApplyCurrentResultButton() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/SearchAndRedactSheet.swift")
        let strip = try slice(source,
                              from: "private var compactFloatStrip: some View {",
                              to: "// MARK: - Search Bar")
        // Both branches of the strip mount the builder …
        let mounts = strip.components(separatedBy: "applyCurrentResultButton\n").count - 1
        #expect(mounts >= 2,
                "compactFloatStrip must mount applyCurrentResultButton in both the AX HStack branch and the ZStack branch")
        // … and the builder — split into `+CompactApply.swift` under the
        // M-6 hub cap — carries the id, the ruled TEXT form and the
        // shared floor token.
        let builder = try loadRepoFile("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+CompactApply.swift")
        #expect(builder.contains("var applyCurrentResultButton: some View {"),
                "the per-item Apply builder must live in +CompactApply.swift")
        #expect(builder.contains("accessibilityIdentifier(\"applyCurrentResultButton\")"),
                "the per-item Apply must carry the applyCurrentResultButton identifier")
        #expect(builder.contains("Text(\"Apply\")"),
                "the per-item Apply is the ruled TEXT form (RB-123 item 4)")
        #expect(builder.contains("ResectaTokens.TouchTarget.minimum"),
                "the per-item Apply must reference the shared 46-pt floor token (RB-67)")
    }

    @Test("The bottom toast host lifts by the hug while the sheet is parked at the compact float (UXC-51)")
    func toastClearanceFollowsTheHug() {
        #expect(SearchAndRedactSheet.toastBottomClearance(for: .compactFloat) == CompactFloatDetent.hugHeight)
        #expect(SearchAndRedactSheet.toastBottomClearance(for: .medium) == 0)
        #expect(SearchAndRedactSheet.toastBottomClearance(for: .large) == 0)
    }

    @Test("Clamped to the available height when it is below the hug")
    func clampsToAvailableHeight() {
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 40) == 40)
    }

    @Test("compactFloat detent is distinct from .medium and .large")
    func compactFloatIsDistinctDetent() {
        let compact: PresentationDetent = .compactFloat
        #expect(compact != .medium)
        #expect(compact != .large)
    }

    @Test("compactFloat detent equals itself")
    func compactFloatIdentity() {
        let a: PresentationDetent = .compactFloat
        let b: PresentationDetent = .compactFloat
        #expect(a == b)
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
