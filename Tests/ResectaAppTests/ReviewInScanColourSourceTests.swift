import Testing
import Foundation
@testable import ResectaApp

// "Review in Scan" is a teal word the app draws itself, so its words take
// the text teal, as the page chips beside it do, and not the tint. Read from
// the source, the way the screens' source-contract tests read theirs.

@Suite("Review in Scan colour source contract")
struct ReviewInScanColourSourceTests {

    static let rowPath = "Sources/ResectaApp/Views/LayerResultRow.swift"

    @Test("Review in Scan's words are drawn in the text teal")
    func reviewInScanUsesTheTextTeal() throws {
        let row = try loadRepoFile(Self.rowPath)
        // The visible button: from its declaration to its identifier.
        let id = try #require(row.range(of: ".accessibilityIdentifier(\"reviewInScanButton\")"))
        let start = try #require(row.range(
            of: "Button(Self.reviewInScanLabel, action: onReviewInScan)",
            options: .backwards, range: row.startIndex..<id.lowerBound))
        let declaration = row[start.lowerBound..<id.upperBound]
        #expect(declaration.contains(".foregroundStyle(ResectaTokens.BrandTeal.text)"),
                "\(declaration)")
        #expect(!declaration.contains(".tint("), "\(declaration)")
    }

    // MARK: - Helpers

    private func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func loadRepoFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }
}
