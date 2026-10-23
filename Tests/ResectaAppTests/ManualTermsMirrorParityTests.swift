import Testing
import CoreGraphics
import Foundation
@testable import ResectaApp

// The verification corpus mirror carries its own copy of the manual-term
// stop list and admission rule (the engine test tree cannot import the app).
// This pin reads both sources and holds them in lockstep: the same entries,
// the same rule; a word added on either side alone fails here. The second
// pin holds the capture's two geometry constants (the removal halo, the
// edge tolerance) equal to the engine's internal values they copy.

@Suite("Manual-term stop list: the mirror's copy")
struct ManualTermsMirrorParityTests {

    @Test("The corpus mirror's stop list and admission rule equal the app's")
    func mirrorStopListMatchesTheApp() throws {
        let app = try loadRepoFile("Sources/ResectaApp/State/ManualTermStopWords.swift")
        let mirror = try loadRepoFile(
            "Packages/RedactionEngine/Tests/RedactionEngineTests/CorpusTests/VerificationCorpusStopWords.swift")
        let appWords = try words(in: app)
        let mirrorWords = try words(in: mirror)
        #expect(appWords.count == ManualTermStopWords.words.count)
        #expect(appWords == mirrorWords, "app \(appWords.symmetricDifference(mirrorWords))")
        #expect(try rule(in: app) == rule(in: mirror), "the admission rule differs")
    }

    @Test("The capture's removal halo and edge tolerance equal the engine's constants")
    func haloConstantsMatchTheEngine() throws {
        let filter = try loadRepoFile(
            "Packages/RedactionEngine/Sources/RedactionEngine/Pipeline/CharacterFilter.swift")
        let spans = try loadRepoFile(
            "Packages/RedactionEngine/Sources/RedactionEngine/Search/TextLayerSpans.swift")
        #expect(try constant("safetyMarginPoints", in: filter) == ManualCapturePageWords.removalHaloPoints,
                "the removal halo is the Searchable filter's safety margin")
        #expect(try constant("edgeTolerancePoints", in: spans) == ManualCapturePageWords.edgeTolerancePoints,
                "the edge tolerance is the engine's word-span tolerance")
    }

    // MARK: - Helpers

    private func constant(_ name: String, in source: String) throws -> CGFloat {
        let regex = try NSRegularExpression(pattern: #"let "# + name + #": CGFloat = ([0-9.]+)"#)
        let range = NSRange(source.startIndex..., in: source)
        let match = try #require(regex.firstMatch(in: source, range: range), "\(name) not found")
        let text = try #require(Range(match.range(at: 1), in: source).map { String(source[$0]) })
        return try #require(Double(text).map { CGFloat($0) })
    }

    private func words(in source: String) throws -> Set<String> {
        let list = try #require(section(of: source, from: "static let words: Set<String> = [", upTo: "\n    ]"))
        let regex = try NSRegularExpression(pattern: #""([^"]+)""#)
        let range = NSRange(list.startIndex..., in: list)
        return Set(regex.matches(in: list, range: range).compactMap { match in
            Range(match.range(at: 1), in: list).map { String(list[$0]) }
        })
    }

    private func rule(in source: String) throws -> String {
        try #require(section(of: source, from: "static func admits(_ token: String) -> Bool {", upTo: "\n    }"))
    }

    private func section(of text: String, from start: String, upTo end: String) -> String? {
        guard let startRange = text.range(of: start),
              let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[startRange.upperBound..<endRange.lowerBound])
    }

    private func loadRepoFile(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
