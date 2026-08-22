import Testing
import Foundation
import SwiftUI
@testable import ResectaApp

// UXC-33 (RB-24) — partial revival of DC-023's
// `Anim.resolvedTransition(standard:reduceMotion:)`, removed by the W1
// dead-code wave (ref `0f9fc672`) as never-read even though RB-24 had
// already ruled "wire through the resolver". This suite pins:
//
//  1. Reachability of `resolvedTransition` against both Reduce-Motion
//     flags, mirroring `ToastReduceMotionTests`'s posture for
//     `Anim.resolved` (the actual `AnyTransition` swap is opaque —
//     `AnyTransition` is not Equatable — so these assert reachability,
//     not value equality).
//  2. A source-scanning pin (mirrors `HonestySurfacesTests.loadRepoFile`)
//     asserting every `.move(edge` occurrence under
//     `Sources/ResectaApp/Views` sits inside a `resolvedTransition(`
//     call — a regression to a raw, unresolved `.move(edge` transition
//     trips this rather than silently reverting the Reduce-Motion fix.

@Suite("Transition resolver adoption (UXC-33)")
struct TransitionResolverTests {

    @Test("resolvedTransition with Reduce Motion off returns the standard transition (reachable)")
    func resolvedTransitionReduceMotionOff() {
        let resolved = ResectaTokens.Anim.resolvedTransition(
            standard: .move(edge: .top),
            reduceMotion: false
        )
        // AnyTransition is not Equatable — pin reachability, mirroring
        // ToastReduceMotionTests's posture for `Anim.resolved`.
        _ = resolved
    }

    @Test("resolvedTransition with Reduce Motion on returns a transition (reachable)")
    func resolvedTransitionReduceMotionOn() {
        let resolved = ResectaTokens.Anim.resolvedTransition(
            standard: .move(edge: .top),
            reduceMotion: true
        )
        _ = resolved
    }

    @Test("resolvedTransition is reachable with an asymmetric standard transition (both flags)")
    func resolvedTransitionAsymmetricReachable() {
        let standard = AnyTransition.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
        )
        _ = ResectaTokens.Anim.resolvedTransition(standard: standard, reduceMotion: false)
        _ = ResectaTokens.Anim.resolvedTransition(standard: standard, reduceMotion: true)
    }

    // MARK: - Source-scanning pin

    @Test("Every .move(edge site under Sources/ResectaApp/Views sits inside a resolvedTransition( call")
    func allMoveEdgeSitesRideTheResolver() throws {
        let viewsRoot = repoRoot().appendingPathComponent("Sources/ResectaApp/Views")
        let swiftFiles = try Self.swiftFiles(under: viewsRoot)
        #expect(!swiftFiles.isEmpty, "expected a non-empty .swift file list under Sources/ResectaApp/Views")

        var totalMoveEdgeSites = 0
        for fileURL in swiftFiles {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let (count, violations) = Self.moveEdgeViolations(in: source)
            totalMoveEdgeSites += count
            #expect(violations.isEmpty,
                    "\(fileURL.lastPathComponent): \(violations.joined(separator: "; "))")
        }
        // The ref's own count — a drift here means either a site was
        // added/removed elsewhere, or (more likely) a comment mentioning
        // `.move(edge` inflated the count; keep this in sync deliberately.
        #expect(totalMoveEdgeSites == 11,
                "expected 11 `.move(edge` sites under Sources/ResectaApp/Views, found \(totalMoveEdgeSites)")
    }

    /// For every occurrence of a REAL `.move(edge: .something)` call in
    /// `source`, the NEAREST preceding marker — whichever of
    /// `resolvedTransition(` or a bare `.transition(` appears closer to
    /// it — must be `resolvedTransition(`. This is intentionally
    /// distance-agnostic (no paren-balancing): the contract is "this
    /// `.move(edge` is wrapped by the resolver, not a bare
    /// `.transition(` call", which the closer-marker comparison captures
    /// without a full parser.
    ///
    /// The needle is `.move(edge: .` (colon, SPACE, dot) rather than the
    /// bare `.move(edge:` prefix so prose mentions in doc comments — this
    /// very file, `ResectaTokens.swift`, `LayerResultRow.swift`, and
    /// `VerificationResultsView.swift` all narrate `` `.move(edge:)` ``
    /// (no trailing space + case value) — never count as sites or skew
    /// the 11-site total.
    static func moveEdgeViolations(in source: String) -> (count: Int, violations: [String]) {
        let needle = ".move(edge: ."
        var violations: [String] = []
        var count = 0
        var searchStart = source.startIndex
        while let needleRange = source.range(of: needle, range: searchStart..<source.endIndex) {
            count += 1
            let prefix = source[source.startIndex..<needleRange.lowerBound]
            let lastResolved = prefix.range(of: "resolvedTransition(", options: .backwards)
            let lastBareTransition = prefix.range(of: ".transition(", options: .backwards)
            switch (lastResolved, lastBareTransition) {
            case (nil, _):
                let offset = source.distance(from: source.startIndex, to: needleRange.lowerBound)
                violations.append("no resolvedTransition( precedes .move(edge at offset \(offset)")
            case (.some(let resolvedRange), .some(let bareRange))
                where bareRange.lowerBound > resolvedRange.lowerBound:
                let offset = source.distance(from: source.startIndex, to: needleRange.lowerBound)
                violations.append("a bare .transition( sits closer than resolvedTransition( before .move(edge at offset \(offset)")
            default:
                break
            }
            searchStart = needleRange.upperBound
        }
        return (count, violations)
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }

    private func repoRoot(from file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }
}
