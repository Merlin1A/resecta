import Foundation
import RedactionEngine
import Testing
@testable import ResectaApp

// A box's origin, read in one place: every way the app makes a box, through
// the real makers where the app has one, and the pin that keeps Scan from
// gaining a second kind of result with no category unseen.

@MainActor
struct BoxOriginTests {
    // MARK: - Makers

    private func rect(_ y: CGFloat) -> CGRect { CGRect(x: 0.1, y: y, width: 0.3, height: 0.04) }

    private func origin(_ state: RedactionState, _ id: UUID) -> BoxOrigin? {
        guard let region = state.regions.values.joined().first(where: { $0.id == id }) else { return nil }
        return BoxOrigin.of(region, metadata: state.regionMetadata[id])
    }

    private func typedResult(y: CGFloat = 0.1, term: String = "alpha") -> SearchResult {
        SearchResult(
            pageIndex: 0, normalizedRect: rect(y), matchedText: term, contextSnippet: "…\(term)…",
            source: .textLayer, term: term, isSelected: true
        )
    }

    private func scanResult(y: CGFloat = 0.3) -> SearchResult {
        SearchResult(
            pageIndex: 0, normalizedRect: rect(y), matchedText: "123-45-6789", contextSnippet: "…123-45-6789…",
            source: .textLayer, term: "SSN", isSelected: true, piiCategory: .ssn, piiConfidence: 0.9
        )
    }

    /// Built as Scan builds a hit for a pattern the user always flags.
    private func alwaysFlagRationale(_ pattern: String) -> MatchRationale {
        MatchRationale(
            ruleID: "user.alwaysFlag", signals: [.userAlwaysFlag(pattern: pattern)],
            preThresholdScore: 1.0, finalScore: 1.0
        )
    }

    private func alwaysFlagResult(y: CGFloat = 0.5) -> SearchResult {
        SearchResult(
            pageIndex: 0, normalizedRect: rect(y), matchedText: "ACME-7", contextSnippet: "…ACME-7…",
            source: .textLayer, term: "Custom", isSelected: true, piiCategory: nil, piiConfidence: nil,
            rationale: alwaysFlagRationale("ACME-7")
        )
    }

    /// Applies the given results through the real apply path and returns the new
    /// regions' ids, in the order of the results (each found by its matched text).
    private func apply(_ results: [SearchResult], to state: RedactionState) async -> [UUID] {
        let before = Set(state.regions.values.joined().map(\.id))
        let search = SearchState()
        search.results = results
        state.activeSearch = search
        _ = await state.applyFindings(.selectedSearchResults, undoManager: nil)
        let added = state.regions.values.joined().filter { !before.contains($0.id) }
        return results.compactMap { result in
            added.first(where: { state.regionMetadata[$0.id]?.matchedText == result.matchedText })?.id
        }
    }

    // MARK: - Cases

    @Test func drawnBox() {
        let state = RedactionState()
        let region = RedactionRegion(id: UUID(), normalizedRect: rect(0.2), source: .manual)
        state.addRegion(region, page: 0, undoManager: nil)
        #expect(origin(state, region.id) == .drawn)
    }

    @Test func duplicateOfAScanBox() async throws {
        let state = RedactionState()
        let scanned = try #require(await apply([scanResult()], to: state).first)
        state.duplicateRegion(scanned, page: 0, undoManager: nil)
        let copy = try #require(state.regions[0]?.first(where: { $0.id != scanned }))
        #expect(origin(state, copy.id) == .drawn)
        #expect(origin(state, scanned) == .scan(kind: .ssn))
    }

    @Test func wholePageReadsAsDrawn() {
        let state = RedactionState()
        let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), source: .manual)
        state.addRegion(region, page: 0, undoManager: nil)
        #expect(origin(state, region.id) == .drawn)
    }

    @Test func appliedSearchResult() async throws {
        let state = RedactionState()
        let id = try #require(await apply([typedResult(term: "alpha")], to: state).first)
        #expect(origin(state, id) == .search(term: "alpha"))
    }

    @Test func appliedScanResult() async throws {
        let state = RedactionState()
        let id = try #require(await apply([scanResult()], to: state).first)
        #expect(origin(state, id) == .scan(kind: .ssn))
    }

    @Test func appliedAlwaysFlagResult() async throws {
        let state = RedactionState()
        let id = try #require(await apply([alwaysFlagResult()], to: state).first)
        #expect(origin(state, id) == .scan(kind: nil))
    }

    enum Nudge: String, CaseIterable, Sendable { case withCategory, alwaysFlag, neither }

    @Test(arguments: Nudge.allCases)
    func acceptedNudge(_ nudge: Nudge) throws {
        let state = RedactionState()
        let result: SearchResult
        let expected: BoxOrigin
        switch nudge {
        case .withCategory:
            result = scanResult()
            expected = .scan(kind: .ssn)
        case .alwaysFlag:
            result = alwaysFlagResult()
            expected = .scan(kind: nil)
        case .neither:
            result = typedResult(term: "bravo")
            expected = .search(term: "bravo")
        }
        let region = try #require(state.acceptManualDrawNudge(result, undoManager: nil))
        #expect(origin(state, region.id) == expected, "\(nudge)")
    }

    @Test func searchMatchWithoutMetadata() {
        let region = RedactionRegion(id: UUID(), normalizedRect: rect(0.2), source: .searchMatch(term: "charlie"))
        #expect(BoxOrigin.of(region, metadata: nil) == .search(term: "charlie"))
    }

    /// Decoded from JSON written with the tags the region reads and writes. No app
    /// path decodes a region; this pins that every source has an answer.
    @Test func storedDetectedSources() throws {
        func decoded(_ source: [String: Any]) throws -> RedactionRegion {
            let json: [String: Any] = [
                "id": UUID().uuidString,
                "normalizedRect": [[0.1, 0.2], [0.3, 0.04]],
                "source": source,
            ]
            return try JSONDecoder().decode(RedactionRegion.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let kind = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(RedactionRegion.PIIKind.email), options: .fragmentsAllowed)
        let pii = try decoded(["type": "detectedPII", "kind": kind])
        let face = try decoded(["type": "detectedFace"])
        #expect(BoxOrigin.of(pii, metadata: nil) == .scan(kind: .email))
        #expect(BoxOrigin.of(face, metadata: nil) == .face)
    }

    @Test func originSurvivesEdits() async throws {
        let state = RedactionState()
        let drawn = RedactionRegion(id: UUID(), normalizedRect: rect(0.7), source: .manual)
        state.addRegion(drawn, page: 0, undoManager: nil)
        let applied = await apply([typedResult(y: 0.1, term: "alpha"), scanResult(y: 0.3)], to: state)
        try #require(applied.count == 2)
        let cases: [(UUID, BoxOrigin)] = [(drawn.id, .drawn), (applied[0], .search(term: "alpha")), (applied[1], .scan(kind: .ssn))]
        let undo = UndoManager()
        undo.groupsByEvent = false
        for (id, expected) in cases {
            let start = try #require(state.regions[0]?.first(where: { $0.id == id })?.normalizedRect)
            #expect(state.moveRegion(id, page: 0, newRect: start.offsetBy(dx: 0.05, dy: 0), undoManager: nil))
            #expect(origin(state, id) == expected, "after a move")
            #expect(state.resizeRegion(id, page: 0, newRect: start.insetBy(dx: -0.01, dy: -0.01), undoManager: nil))
            #expect(origin(state, id) == expected, "after a resize")
            undo.beginUndoGrouping()
            state.removeRegion(id, page: 0, undoManager: undo)
            undo.endUndoGrouping()
            #expect(origin(state, id) == nil, "deleted")
            undo.undo()
            #expect(origin(state, id) == expected, "after the Undo of a delete")
        }
    }

    @Test func sourceDecidesFirst() {
        let region = RedactionRegion(id: UUID(), normalizedRect: rect(0.2), source: .manual)
        let metadata = RegionMetadata(piiKind: .pii(.ssn), confidence: 0.9, matchedText: "123-45-6789", recognitionLevel: .fast)
        #expect(BoxOrigin.of(region, metadata: metadata) == .drawn)
    }

    /// Every Scan result that carries no category is one the user set to always
    /// flag: each `piiCategory: nil` in Scan's source is followed, inside the same
    /// `SearchResult(` call, by a `.userAlwaysFlag(` signal. A second kind of
    /// result with no category turns this red, so `BoxOrigin` learns of it.
    @Test func everyCategorylessScanResultIsAlwaysFlag() throws {
        let source = try loadRepoFile("Packages/RedactionEngine/Sources/RedactionEngine/Search/DocumentSearcher+PIIScan.swift")
        var checked = 0
        var searchFrom = source.startIndex
        while let hit = source.range(of: "piiCategory: nil", range: searchFrom..<source.endIndex) {
            let call = try #require(source.range(of: "SearchResult(", options: .backwards, range: source.startIndex..<hit.lowerBound),
                                    "a piiCategory: nil outside a SearchResult call")
            var depth = 0
            var end = call.upperBound
            var index = source.index(before: call.upperBound)
            while index < source.endIndex {
                if source[index] == "(" { depth += 1 }
                if source[index] == ")" { depth -= 1; if depth == 0 { end = index; break } }
                index = source.index(after: index)
            }
            #expect(end > hit.upperBound, "the call closes after its piiCategory: nil")
            #expect(source[call.lowerBound..<end].contains(".userAlwaysFlag("),
                    "a Scan result with no category and no always-flag signal")
            checked += 1
            searchFrom = hit.upperBound
        }
        #expect(checked >= 1, "the pin found no categoryless result to check")
    }

    private func loadRepoFile(_ relativePath: String, from file: StaticString = #filePath) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
