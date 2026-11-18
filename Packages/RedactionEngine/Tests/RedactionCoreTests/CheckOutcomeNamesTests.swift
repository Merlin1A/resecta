import Foundation
import Testing
import RedactionCore

/// The names a check reports in, and the row each reads as.
@Suite struct CheckOutcomeNamesTests {

    /// Every fault name with the row it must read as. A fault that reads
    /// Passed or Nothing to check would hide a check that could not finish.
    static let faultRows: [FaultName: RowClass] = [
        .noRecord: .skipped,
        .noResult: .couldNotVerify,
        .unreadableInput: .couldNotVerify,
        .evidenceShort: .couldNotVerify,
        .wrongSubject: .couldNotVerify,
    ]

    @Test("Every outcome kind and fault name reads as its own row; none reads Passed but a completed unit")
    func everyNameHasItsRowClass() {
        #expect(Set(Self.faultRows.keys) == Set(FaultName.allCases), "every fault name is in the table")
        for fault in FaultName.allCases {
            #expect(OutcomeKind.fault(fault).rowClass == Self.faultRows[fault], "\(fault)")
        }
        #expect(OutcomeKind.completed.rowClass == .passed)
        #expect(OutcomeKind.issue.rowClass == .needsReview)
        #expect(OutcomeKind.inconclusive(CheckRule("a rule")).rowClass == .couldNotVerify)
    }

    // MARK: - The mapping table of the page-image check, as data

    /// What a line's unit is.
    enum UnitShape: Equatable {
        case document, page, box
        /// Every box of one page, one answer each.
        case everyBoxOfPage
    }

    struct Line {
        let reports: String
        let unit: UnitShape
        let kind: OutcomeKind
        let reads: RowClass
    }

    static let reportedRectangle = CheckRule("reported rectangle")

    /// One line per row: what the page-image check reports, the unit it is
    /// about, its kind, and the row that reads. The check's own tests read
    /// this table against its results.
    static let lines: [Line] = [
        Line(reports: "the page image is accepted and its walk ends on its end marker",
             unit: .page, kind: .completed, reads: .passed),
        Line(reports: "a header or walk rule refuses it; a named limit is passed; the page has no image, or two",
             unit: .page, kind: .fault(.unreadableInput), reads: .couldNotVerify),
        Line(reports: "the image's hash differs from the recorded one; its bytes are not in the checked file",
             unit: .page, kind: .fault(.wrongSubject), reads: .couldNotVerify),
        Line(reports: "there is no record of the run",
             unit: .document, kind: .fault(.noRecord), reads: .skipped),
        Line(reports: "every block of the box's unit is exactly the fill (a box reported larger is completed, with that note)",
             unit: .box, kind: .completed, reads: .passed),
        Line(reports: "a block that is not the fill",
             unit: .box, kind: .issue, reads: .needsReview),
        Line(reports: "the reported rectangle does not contain the rule's, and every required block is the fill",
             unit: .box, kind: .inconclusive(reportedRectangle), reads: .couldNotVerify),
        Line(reports: "the record holds no reported rectangle for the box, and every required block is the fill",
             unit: .box, kind: .inconclusive(reportedRectangle), reads: .couldNotVerify),
        Line(reports: "the frame matches no quality tier of its page",
             unit: .everyBoxOfPage, kind: .inconclusive(CheckRule("quality tier")), reads: .couldNotVerify),
        Line(reports: "the box maps to no pixel and is not wholly off its page",
             unit: .box, kind: .inconclusive(CheckRule("maps to no pixel")), reads: .couldNotVerify),
        Line(reports: "blocks examined differ from blocks expected",
             unit: .box, kind: .fault(.evidenceShort), reads: .couldNotVerify),
        Line(reports: "the run's plan holds a box the result does not mention",
             unit: .box, kind: .fault(.noResult), reads: .couldNotVerify),
    ]

    @Test("The page-image check's mapping table: twelve lines, each reading as its row; no record is the document's alone")
    func pageImageCheckTable() {
        #expect(Self.lines.count == 12)
        for line in Self.lines {
            #expect(line.kind.rowClass == line.reads, "\(line.reports)")
        }
        // "No record" has one meaning: the run has no record at all.
        let noRecord = Self.lines.filter { $0.kind == .fault(.noRecord) }
        #expect(noRecord.count == 1)
        #expect(noRecord.allSatisfy { $0.unit == .document })
        #expect(Self.lines.filter { $0.unit == .document }.allSatisfy { $0.kind == .fault(.noRecord) })
        // A box with no reported rectangle is judged as one whose report
        // does not contain the paint: the same kind, by the same rule.
        #expect(Self.lines[6].kind == Self.lines[7].kind)
    }

    // MARK: - The mapping has no default arm

    @Test("The row mapping's body holds no default arm, so no name can read Passed unseen")
    func rowMappingHasNoDefaultArm() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RedactionCore/Verification/CheckOutcomeNames.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(source.range(of: "package var rowClass: RowClass {"), "the mapping is where this pin reads it")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"), "the mapping's body ends")
        let body = rest[..<end.lowerBound]
        try #require(body.contains("switch self"), "the body read is the mapping's switch")
        #expect(!body.contains("default"), "the mapping must name every case")
        #expect(!body.contains("@unknown"), "the mapping must name every case")
    }
}
