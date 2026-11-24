import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

/// The card of plain warnings under its heading; the sentence under the
/// title of a passing run, by the Findings rows, the hand-drawn boxes and
/// the notes in view; and the order of the blocks under the buttons.
@MainActor
struct ResultsOrderAndSentenceTests {
    typealias View = VerificationResultsView
    typealias Section = VerificationDetailsSection
    typealias Fixtures = VerificationDebugFixtures

    static let passReport = VerificationReport(
        layers: [LayerResult(name: "Character Count", symbolName: "number", status: .pass, shortDescription: "",
                             detailDescription: "", pageReferences: nil, durationSeconds: 0, layer: .characterCount)],
        overallStatus: .pass, durationSeconds: 0)

    static func source(_ file: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/\(file)"), encoding: .utf8)
    }

    // MARK: - The warnings' heading

    @Test("The plain warnings' card is headed Warnings · n, spoken as a header; its rows show no outcome word")
    func warningsHeading() throws {
        let p = VerificationLayerPartition(layers: Fixtures.secureWarningOnly.layers,
                                           perPageModes: Fixtures.secureWarningOnly.perPageModes)
        let groups = Section.groups(p)
        #expect(groups.map(\.header) == ["Warnings"])
        let count = try #require(groups.first).indices.count
        #expect(VerificationLayerPartition.sectionHeader("Warnings", count: 1) == "Warnings · 1")
        #expect(VerificationLayerPartition.sectionHeaderSpoken("Warnings", count: 1) == "Warnings, 1.")
        #expect(count >= 1)
        let source = try Self.source("VerificationDetailsSection.swift")
        let loop = try #require(source.range(of: "ForEach(Self.groups(partition)"))
        let rows = try #require(source.range(of: "layerRows(group.indices, layout: .lead, showsStatusWord: false)",
                                              range: loop.upperBound..<source.endIndex))
        #expect(source[loop.upperBound..<rows.lowerBound].count < 700, "the card's rows are drawn without the word")
    }

    // MARK: - The passing sentence

    @Test("The passing sentence: findings, then hand-drawn boxes, then the notes in view, then Preview")
    func passingSentenceTable() {
        typealias Row = (findings: Int, boxes: Int, notes: Int, output: Bool, sentence: String)
        let rows: [Row] = [
            (1, 0, 0, true, "Read the finding below before you share the PDF."),  // LegalPhrases:safe (approved row words, test data)
            (1, 3, 2, true, "Read the finding below before you share the PDF."),  // LegalPhrases:safe (approved row words, test data)
            (3, 0, 0, true, "Read the findings below before you share the PDF."),
            (2, 1, 0, false, "Read the findings below before you share the PDF."),
            (0, 1, 0, true, "No check could read what 1 hand-drawn box covers."),
            (0, 2, 0, true, "No check could read what 2 hand-drawn boxes cover."),
            (0, 12, 0, true, "No check could read what 12 hand-drawn boxes cover."),
            (0, 1, 2, true, "No check could read what 1 hand-drawn box covers."),
            (0, 0, 1, true, "Read the note below before you share the PDF."),
            (0, 0, 2, true, "Read the notes below before you share the PDF."),
            (0, 0, 0, true, "Look over the redacted PDF in Preview before you share it."),
            (0, 0, 0, false, View.outputMissingSentence),
        ]
        for (index, row) in rows.enumerated() {
            #expect(View.passingSentence(findingRows: row.findings, handDrawnBoxes: row.boxes, notes: row.notes,
                                         outputExists: row.output) == row.sentence, "row \(index)")
        }
        print("[passing-sentence] rows \(rows.count)")
        #expect(rows.count == 12)
        // The passing arm is that function of the screen's numbers.
        #expect(View.mastheadSubtitle(report: Self.passReport, findingRows: 2, handDrawnBoxes: 1)
                == "Read the findings below before you share the PDF.")
        #expect(View.mastheadSubtitle(report: Self.passReport, handDrawnBoxes: 1)
                == "No check could read what 1 hand-drawn box covers.")
        #expect(View.mastheadSubtitle(report: Fixtures.securePassRidingNote)
                == "Read the note below before you share the PDF.")
    }

    @Test("The screen hands the masthead its Findings rows: the sweep's items left on a pass are one")
    func theScreenCountsItsFindingsRows() {
        for report in [Fixtures.secureScreenshot, Fixtures.secureScanOnly] {
            let rows = View.findingRowCount(report: report, findings: [])
            #expect(rows == 1)
            #expect(View.mastheadSubtitle(report: report, findingRows: rows)
                    == "Read the finding below before you share the PDF.")  // LegalPhrases:safe (approved row words, test data)
        }
        let items: [ResultsFinding] = [.coveredTextInOriginal(pages: [0]), .filledFormValuesNotCarried(count: 3),
                                       .handRegionsOnPagesWithoutText(regionPages: [1])]
        #expect(View.findingRowCount(report: Self.passReport, findings: items) == 2)
        #expect(View.handDrawnBoxCount(in: items) == 1)
        let source = try? Self.source("VerificationResultsView.swift")
        #expect(source?.contains("findingRows: Self.findingRowCount(report: report, findings: findings)") == true)
        #expect(source?.contains("handDrawnBoxes: Self.handDrawnBoxCount(in: findings)") == true)
    }

    // MARK: - Hand-drawn boxes

    @Test("Hand-drawn boxes: one, two, twelve, two on one page; never on a failed run")
    func handDrawnSentence() {
        #expect(View.handDrawnBoxCount(in: [.handRegionsOnPagesWithoutText(regionPages: [3, 3])]) == 2)
        #expect(View.handDrawnBoxCount(in: [.handRegionsOnPagesWithoutText(regionPages: Array(repeating: 0, count: 12))])
                == 12)
        #expect(View.handDrawnBoxCount(in: []) == 0)
        let twoOnOnePage = View.handDrawnBoxCount(in: [.handRegionsOnPagesWithoutText(regionPages: [3, 3])])
        #expect(View.mastheadSubtitle(report: Self.passReport, handDrawnBoxes: twoOnOnePage)
                == "No check could read what 2 hand-drawn boxes cover.")
        for report in [Fixtures.secureFail, Fixtures.searchableAttentionMixed, Fixtures.secureWarningOnly] {
            #expect(View.mastheadSubtitle(report: report, handDrawnBoxes: 2)
                    == View.mastheadSubtitle(report: report, handDrawnBoxes: 0), "\(report.overallStatus)")
            #expect(View.mastheadSubtitle(report: report, handDrawnBoxes: 2)?.contains("hand-drawn") == false)
        }
    }

    // MARK: - The order under the buttons

    @Test("The order under the buttons: the hand-drawn row first; on Checks Passed the findings before the small print")
    func orderUnderTheButtons() {
        typealias B = ResultsBlock
        let tail: Set<B> = [.facts, .checksList]
        // (present, Checks Passed, the findings first, expected)
        let rows: [(Set<B>, Bool, Bool, [B])] = [
            (tail.union([.smallPrint]), true, true, [.smallPrint, .facts, .checksList]),
            (tail.union([.handDrawnBoxes, .smallPrint]), true, true, [.handDrawnBoxes, .smallPrint, .facts, .checksList]),
            (tail.union([.findings, .smallPrint]), true, true, [.findings, .smallPrint, .facts, .checksList]),
            (tail.union([.findings, .smallPrint]), true, false, [.smallPrint, .findings, .facts, .checksList]),
            (tail.union([.handDrawnBoxes, .findings, .smallPrint]), true, true,
             [.handDrawnBoxes, .findings, .smallPrint, .facts, .checksList]),
            (tail.union([.handDrawnBoxes, .findings, .smallPrint, .warnings]), false, true,
             [.handDrawnBoxes, .findings, .warnings, .facts, .checksList]),
        ]
        for (index, row) in rows.enumerated() {
            #expect(B.order(present: row.0, checksPassed: row.1, findingsFirst: row.2) == row.3, "row \(index)")
        }
        #expect(rows.count == 6)
        #expect(B.findingsBeforeTheSmallPrint)
        #expect(B.smallPrintFollowsFindings([.findings, .smallPrint, .facts]))
        #expect(!B.smallPrintFollowsFindings([.smallPrint, .findings, .facts]))
        #expect(!B.smallPrintFollowsFindings([.findings, .facts]))
    }

    @Test("Source pin: the views draw the blocks in that order and no other")
    func theViewsFollowTheOrder() throws {
        let results = try Self.source("VerificationResultsView.swift")
        let hand = try #require(results.range(of: "ResultsFindingsSection("))
        let small = try #require(results.range(of: "ResultsScopeNote(report: report, sentences: smallPrint)"))
        let section = try #require(results.range(of: "VerificationDetailsSection("))
        #expect(hand.lowerBound < small.lowerBound && small.lowerBound < section.lowerBound)
        #expect(results.components(separatedBy: "ResultsScopeNote(").count == 2)
        let details = try Self.source("VerificationDetailsSection.swift")
        #expect(details.components(separatedBy: "ResultsScopeNote(").count == 2)
        let rows = try #require(details.range(of: "findingRows(problems)"))
        let note = try #require(details.range(of: "ResultsScopeNote(report: report, sentences: smallPrintAfterFindings)"))
        let groups = try #require(details.range(of: "ForEach(Self.groups(partition)"))
        #expect(rows.lowerBound < note.lowerBound && note.lowerBound < groups.lowerBound)
    }

    @Test("The blocks present on the seeded reports")
    func blocksPresent() {
        let none = View.blocksPresent(report: Fixtures.secureAllPass, findings: [], smallPrint: [])
        #expect(none == [.facts, .checksList])
        let hand = View.blocksPresent(report: Fixtures.secureAllPass,
                                      findings: [.handRegionsOnPagesWithoutText(regionPages: [0])], smallPrint: [])
        #expect(hand.contains(.handDrawnBoxes) && !hand.contains(.findings))
        let small = View.blocksPresent(report: Fixtures.secureAllPass, findings: [], smallPrint: ["A sentence."])
        #expect(small.contains(.smallPrint))
        let failed = View.blocksPresent(report: Fixtures.secureFail, findings: [], smallPrint: ["A sentence."])
        #expect(!failed.contains(.smallPrint) && failed.contains(.findings))
        let warned = View.blocksPresent(report: Fixtures.secureWarningOnly, findings: [], smallPrint: [])
        #expect(warned.contains(.warnings) && !warned.contains(.findings))
    }
}
