import Testing
import Foundation
import SwiftUI
@testable import ResectaApp

// Pin the compact float detent's pure-function height (fixed handle hug
// — title + result-nav cluster, plus the per-item Apply — clamped to
// the available height), the handle composition (source scan), and the
// detent-identity contract the anchored-row mechanism relies on.
// The ScrollViewReader anchor itself is driven from a SwiftUI
// `.onChange` and cannot run in a unit test without a UI host — these
// tests cover the parts that can be isolated as values.

@Suite("Compact float detent")
struct CompactDetentAnchoredRowTests {
    @Test("Hug height is constant across screen heights")
    func hugHeightConstantAcrossScreens() {
        // iPhone SE (568pt) / iPhone 17 (~844pt) / iPad-class (1024pt):
        // the title-only hug does not scale with the screen.
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 568) == CompactFloatDetent.hugHeight)
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 844) == CompactFloatDetent.hugHeight)
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 1024) == CompactFloatDetent.hugHeight)
    }

    @Test("Hug constant matches the compact handle contract")
    func hugConstantMatchesContract() {
        // 15-pt grabber inset + the controls row's 46-pt layout floor +
        // breathing room: the row alone, the smallest attached hug. Was
        // 60 under the title-only handle, 72 under the cluster handle,
        // 80 with the per-item Apply on board, 108 (120 at accessibility
        // sizes) while the match line sat over the row.
        #expect(CompactFloatDetent.hugHeight == 101)
        #expect(CompactFloatDetent.hugHeight
                == CompactFloatDetent.grabberInset + ResectaTokens.TouchTarget.minimum
                + CompactFloatDetent.bottomInset)
    }

    @Test("The hug sits in the attached sheet regime — ON its edge (≥ 101 on iOS 26)")
    func hugStaysInTheAttachedRegime() {
        // Measured on the iPhone 17 sim: up to 100 the system draws a
        // floating capsule at a growing scale (0.877 → 0.957, the
        // grabber hidden from ≈94); from 101 an attached sheet at 0.96,
        // where the 46-pt frames show at 44.2 pt. The hug sits on the
        // edge itself; the on-sim regime check re-ran at this value.
        #expect(CompactFloatDetent.hugHeight >= 101)
    }

    @Test("The type-size hug: one hug for every size — the row is the same height at accessibility sizes")
    func hugFollowsTheTypeSize() {
        #expect(CompactFloatDetent.hug(for: .large) == CompactFloatDetent.hugHeight)
        #expect(CompactFloatDetent.hug(for: .xxxLarge) == CompactFloatDetent.hugHeight)
        #expect(CompactFloatDetent.hug(for: .accessibility1) == CompactFloatDetent.hugHeight)
        #expect(CompactFloatDetent.hug(for: .accessibility5) == CompactFloatDetent.hugHeight)
    }

    @Test("The compact handle mounts the result-nav pair at the parked site, which carries the nav ids")
    func compactStripCarriesResultNavCluster() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/SearchAndRedactSheet.swift")
        // The strip's body lives in the +CompactStrip extension file.
        let stripFile = try loadRepoFile("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+CompactStrip.swift")
        let strip = try slice(stripFile,
                              from: "var compactFloatStrip: some View {",
                              to: "var compactStripTitle: some View {")
        #expect(strip.contains("site: .parked"),
                "compactFloatStrip must mount the shared result-nav builders at the parked site")
        #expect(strip.contains("accessibilityIdentifier(\"compactFloatStrip\")"),
                "compactFloatStrip must keep its identifier")
        // The chevron builder both sites share carries the ids — so the
        // compact handle carries resultNavNext by construction.
        let pair = try slice(source,
                             from: "func resultNavButton(",
                             to: "func resultNavCounter(")
        #expect(pair.contains("accessibilityIdentifier(\"resultNavNext\")"),
                "resultNavButton must carry the resultNavNext identifier")
        #expect(pair.contains("accessibilityIdentifier(\"resultNavPrevious\")"),
                "resultNavButton must carry the resultNavPrevious identifier")
    }

    @Test("The compact handle mounts the per-item Apply, which carries applyCurrentResultButton")
    func compactStripCarriesApplyCurrentResultButton() throws {
        let stripFile = try loadRepoFile("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+CompactStrip.swift")
        let strip = try slice(stripFile,
                              from: "var compactFloatStrip: some View {",
                              to: "var compactStripTitle: some View {")
        // Both branches of the strip mount the builder …
        let mounts = strip.components(separatedBy: "applyCurrentResultButton(").count - 1
        #expect(mounts >= 2,
                "compactFloatStrip must mount applyCurrentResultButton in both the AX HStack branch and the ZStack branch")
        // … and the builder — split into `+CompactApply.swift` under the
        // M-6 hub cap — carries the id, the TEXT form, the filled
        // capsule and the shared floor token.
        let builder = try loadRepoFile("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+CompactApply.swift")
        #expect(builder.contains("func applyCurrentResultButton("),
                "the per-item Apply builder must live in +CompactApply.swift")
        #expect(builder.contains("accessibilityIdentifier(\"applyCurrentResultButton\")"),
                "the per-item Apply must carry the applyCurrentResultButton identifier")
        #expect(builder.contains("Text(\"Apply\")"),
                "the per-item Apply is the TEXT form")
        #expect(builder.contains("ResectaTokens.BrandTeal.fill, in: Capsule()"),
                "the per-item Apply is the filled capsule")
        #expect(builder.contains("ResectaTokens.TouchTarget.minimum"),
                "the per-item Apply must reference the shared 46-pt floor token")
        // VoiceOver's read of the current match — kind · page · text —
        // rides the button's value now that the strip draws no line.
        #expect(builder.contains("accessibilityValue("),
                "the per-item Apply / Select must carry the walk summary as its accessibility value")
    }

    @Test("The bottom toast hosts lift by the hug while the sheet is parked at the compact float")
    func toastClearanceFollowsTheHug() {
        // The clearance is the bottom-chrome model's (`ParkedChromeLayout`);
        // with the page bar hidden by the live walk it is the hug alone.
        func clearance(_ detent: PresentationDetent) -> CGFloat {
            ParkedChromeLayout(
                sheetPresented: true, detent: detent, walkLive: true,
                pageCount: 3, sizeClass: .compact, phase: .editing,
                hugHeight: CompactFloatDetent.hug(for: .large)
            ).toastClearance
        }
        #expect(clearance(.compactFloat) == CompactFloatDetent.hugHeight)
        #expect(clearance(.medium) == 0)
        #expect(clearance(.large) == 0)
    }

    @Test("Clamped to the available height when it is below the hug")
    func clampsToAvailableHeight() {
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 40) == 40)
        #expect(CompactFloatDetent.compactHeight(maxDetentValue: 568) == CompactFloatDetent.hugHeight)
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
