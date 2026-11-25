import Testing
import Foundation
@testable import ResectaApp

// The results screen's even rhythm, read from the source: every headerless
// block sits one block gap below the block above, Keep Editing's second
// line is the size of every other row's, and the results screen draws the
// trust line the running screen draws.
@Suite("Verification results: the even rhythm", .tags(.display))
struct VerificationEvenRhythmTests {

    @Test("Every block in the details section sits one block gap below the block above")
    func blocksShareOneGap() throws {
        let source = try Self.repoFile("Sources/ResectaApp/Views/VerificationDetailsSection.swift")
        let start = try #require(source.range(of: "    var body: some View {"))
        let end = try #require(source.range(of: "// MARK: - The rules", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        #expect(!body.contains("ResectaTokens.Spacing.xl"))
        let sections = body.components(separatedBy: "GroupedSection").count - 1
        let gaps = body.components(separatedBy: ".padding(.top, ResectaTokens.Results.blockGap)").count - 1
        #expect(sections >= 3, "the body draws its sections")
        #expect(gaps == sections, "each section is padded by the block gap")
    }

    @Test("Keep Editing's second line is subheadline, as every other row's")
    func actionRowSecondLine() throws {
        let source = try Self.repoFile("Sources/ResectaApp/Views/VerificationResultsActions.swift")
        let row = try #require(source.range(of: "struct ResultsActionRow"))
        let subtitle = try #require(source.range(of: "Text(subtitle)", range: row.upperBound..<source.endIndex))
        let font = try #require(source.range(of: ".font(", range: subtitle.upperBound..<source.endIndex))
        #expect(source[font.lowerBound...].hasPrefix(".font(.subheadline)"))
    }

    @Test("The results screen draws the shared trust line")
    func resultsTrustLine() throws {
        let source = try Self.repoFile("Sources/ResectaApp/Views/VerificationResultsView.swift")
        #expect(source.contains("TrustLine("))
        #expect(!source.contains("Text(\"On-device"))
    }

    private static func repoFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
