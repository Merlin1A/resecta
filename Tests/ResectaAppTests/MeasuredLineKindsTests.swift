import Testing
import Foundation
@testable import ResectaApp

// The measured sentence's slot: the four kinds of line in their fixed order,
// joined by the one joining rule (one name alone; two with "and"; three or
// more with a comma before the "and"), and no sentence for an empty list.
// Every expected sentence below is the approved wording, byte for byte. The
// kinds of each row are given in reverse order: the fixed order decides.

@Suite("The measured sentence's slot")
struct MeasuredLineKindsTests {

    nonisolated struct Row: CustomTestStringConvertible, Sendable {
        let kinds: [MeasuredLineKinds.Kind]
        let sentence: String?
        var testDescription: String { sentence ?? "no kind: no sentence" }
    }

    nonisolated static let rows: [Row] = [
        Row(kinds: [.leftAlignedParagraph], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a left-aligned paragraph."),
        Row(kinds: [.justifiedParagraph], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a justified paragraph."),
        Row(kinds: [.startsWithLabel], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines that start with a label."),
        Row(kinds: [.tableCells], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines in table cells."),
        Row(kinds: [.justifiedParagraph, .leftAlignedParagraph], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a left-aligned paragraph and lines of a justified paragraph."),
        Row(kinds: [.startsWithLabel, .leftAlignedParagraph], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a left-aligned paragraph and lines that start with a label."),
        Row(kinds: [.tableCells, .leftAlignedParagraph], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a left-aligned paragraph and lines in table cells."),
        Row(kinds: [.startsWithLabel, .justifiedParagraph], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a justified paragraph and lines that start with a label."),
        Row(kinds: [.tableCells, .justifiedParagraph], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a justified paragraph and lines in table cells."),
        Row(kinds: [.tableCells, .startsWithLabel], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines that start with a label and lines in table cells."),
        Row(kinds: [.startsWithLabel, .justifiedParagraph, .leftAlignedParagraph], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a left-aligned paragraph, lines of a justified paragraph, and lines that start with a label."),
        Row(kinds: [.tableCells, .justifiedParagraph, .leftAlignedParagraph], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a left-aligned paragraph, lines of a justified paragraph, and lines in table cells."),
        Row(kinds: [.tableCells, .startsWithLabel, .leftAlignedParagraph], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a left-aligned paragraph, lines that start with a label, and lines in table cells."),
        Row(kinds: [.tableCells, .startsWithLabel, .justifiedParagraph], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a justified paragraph, lines that start with a label, and lines in table cells."),
        Row(kinds: [.tableCells, .startsWithLabel, .justifiedParagraph, .leftAlignedParagraph], sentence: "In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a left-aligned paragraph, lines of a justified paragraph, lines that start with a label, and lines in table cells."),
        Row(kinds: [], sentence: nil),
    ]

    @Test("The table holds the fifteen lists of one to four kinds and the empty list")
    func tableLength() {
        #expect(Self.rows.count == 16)
        #expect(Set(Self.rows.map { Set($0.kinds) }).count == 16, "every list is a different set of kinds")
    }

    @Test("Each list of kinds gives its approved sentence", arguments: rows)
    func sentence(_ row: Row) {
        #expect(MeasuredLineKinds.sentence(for: row.kinds) == row.sentence)
    }
}
