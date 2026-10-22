import Testing
import Foundation
import SwiftUI
@testable import ResectaApp
@testable import RedactionEngine

// `VerificationRowModel` — what each Verification Details row says, derived
// from the engine's structured fields. The derivation table below is an
// ORACLE written out by hand, one rule per status × identity; it is never
// built by calling the production derivation, so a drift on either side
// fails here.

// MARK: - The derivation table's axes

nonisolated enum RowModelStatusAxis: String, CaseIterable, Sendable {
    case pass, info, warn, attention, fail, skipped

    var status: VerificationStatus {
        switch self {
        case .pass:      .pass
        case .info:      .info("An info line.")
        case .warn:      .warn("A warn line.")
        case .attention: .attention("An attention line.")
        case .fail:      .fail("A fail line.")
        case .skipped:   .skipped
        }
    }
}

nonisolated enum RowModelModesAxis: String, CaseIterable, Sendable {
    case empty, allRasterized, allSearchable, mixed

    var modes: [PipelineMode] {
        switch self {
        case .empty:         []
        case .allRasterized: [.secureRasterization, .secureRasterization]
        case .allSearchable: [.searchableRedaction, .searchableRedaction]
        case .mixed:         [.searchableRedaction, .secureRasterization]
        }
    }
}

/// One cell's expected outcome, as a rule over the axes the cell varies.
nonisolated enum RowModelRule: Sendable {
    case always(VerificationOutcome)
    /// Keyed on the could-not-verify flag.
    case byFlag(off: VerificationOutcome, on: VerificationOutcome)
    /// Keyed on whether the layer carries query lines.
    case byLines(none: VerificationOutcome, some: VerificationOutcome)
    /// Keyed on the run's page modes: every page rasterized vs any other list.
    case byCoverage(allRasterized: VerificationOutcome, otherwise: VerificationOutcome)

    func expected(lines: Bool, modes: RowModelModesAxis, flag: Bool) -> VerificationOutcome {
        switch self {
        case .always(let o): o
        case .byFlag(let off, let on): flag ? on : off
        case .byLines(let none, let some): lines ? some : none
        case .byCoverage(let raster, let other): modes == .allRasterized ? raster : other
        }
    }
}

/// THE ORACLE — status → identity ("nil" = no identity) → rule. 6 × 13 rows.
nonisolated let rowModelOracle: [RowModelStatusAxis: [String: RowModelRule]] = [
    .pass: [
        "textExtraction": .always(.passed),
        "ocrCheck": .always(.passed),
        "binaryStringSearch": .always(.passed),
        "structureCheck": .always(.passed),
        "metadataCheck": .always(.passed),
        "spatialVerification": .always(.passed),
        "characterCount": .byCoverage(allRasterized: .nothingToCheck, otherwise: .passed),
        "fontVerification": .byCoverage(allRasterized: .nothingToCheck, otherwise: .passed),
        "characterLineage": .byCoverage(allRasterized: .nothingToCheck, otherwise: .passed),
        "operatorReExtraction": .always(.passed),
        "searchRecheck": .always(.passed),
        "detectionSweep": .always(.passed),
        "nil": .always(.passed),
    ],
    .info: [
        "textExtraction": .always(.note),
        "ocrCheck": .always(.note),
        "binaryStringSearch": .always(.nothingToCheck),
        "structureCheck": .always(.note),
        "metadataCheck": .always(.note),
        "spatialVerification": .always(.note),
        "characterCount": .always(.note),
        "fontVerification": .always(.note),
        "characterLineage": .always(.note),
        "operatorReExtraction": .always(.nothingToCheck),
        "searchRecheck": .byLines(none: .nothingToCheck, some: .note),
        "detectionSweep": .byLines(none: .nothingToCheck, some: .note),
        "nil": .always(.note),
    ],
    .warn: [
        "textExtraction": .byFlag(off: .warning, on: .couldNotVerify),
        "ocrCheck": .byFlag(off: .warning, on: .couldNotVerify),
        "binaryStringSearch": .byFlag(off: .warning, on: .couldNotVerify),
        "structureCheck": .byFlag(off: .warning, on: .couldNotVerify),
        "metadataCheck": .byFlag(off: .warning, on: .couldNotVerify),
        "spatialVerification": .byFlag(off: .warning, on: .couldNotVerify),
        "characterCount": .byFlag(off: .warning, on: .couldNotVerify),
        "fontVerification": .byFlag(off: .warning, on: .couldNotVerify),
        "characterLineage": .byFlag(off: .warning, on: .couldNotVerify),
        "operatorReExtraction": .byFlag(off: .warning, on: .couldNotVerify),
        "searchRecheck": .byFlag(off: .warning, on: .couldNotVerify),
        "detectionSweep": .byFlag(off: .warning, on: .couldNotVerify),
        "nil": .byFlag(off: .warning, on: .couldNotVerify),
    ],
    .attention: [
        "textExtraction": .always(.needsReview),
        "ocrCheck": .always(.needsReview),
        "binaryStringSearch": .always(.needsReview),
        "structureCheck": .always(.needsReview),
        "metadataCheck": .always(.needsReview),
        "spatialVerification": .always(.needsReview),
        "characterCount": .always(.needsReview),
        "fontVerification": .always(.needsReview),
        "characterLineage": .always(.needsReview),
        "operatorReExtraction": .always(.needsReview),
        "searchRecheck": .always(.needsReview),
        "detectionSweep": .always(.needsReview),
        "nil": .always(.needsReview),
    ],
    .fail: [
        "textExtraction": .always(.failed),
        "ocrCheck": .always(.failed),
        "binaryStringSearch": .always(.failed),
        "structureCheck": .always(.failed),
        "metadataCheck": .always(.failed),
        "spatialVerification": .always(.failed),
        "characterCount": .always(.failed),
        "fontVerification": .always(.failed),
        "characterLineage": .always(.failed),
        "operatorReExtraction": .always(.failed),
        "searchRecheck": .always(.failed),
        "detectionSweep": .always(.failed),
        "nil": .always(.failed),
    ],
    .skipped: [
        "textExtraction": .always(.couldNotVerify),
        "ocrCheck": .always(.couldNotVerify),
        "binaryStringSearch": .always(.couldNotVerify),
        "structureCheck": .always(.couldNotVerify),
        "metadataCheck": .always(.couldNotVerify),
        "spatialVerification": .always(.couldNotVerify),
        "characterCount": .always(.couldNotVerify),
        "fontVerification": .always(.couldNotVerify),
        "characterLineage": .always(.couldNotVerify),
        "operatorReExtraction": .always(.couldNotVerify),
        "searchRecheck": .always(.couldNotVerify),
        "detectionSweep": .always(.couldNotVerify),
        "nil": .always(.couldNotVerify),
    ],
]

nonisolated struct RowModelCell: Sendable, CustomTestStringConvertible {
    let status: RowModelStatusAxis
    let identity: VerificationLayer?
    let hasLines: Bool
    let modes: RowModelModesAxis
    let flag: Bool

    var testDescription: String {
        "\(status) · \(identity?.rawValue ?? "nil") · lines \(hasLines) · \(modes) · cnv \(flag)"
    }

    /// Every cell: 6 statuses × 13 identities × 2 line states × 4 mode
    /// lists × 2 flag values = 1,248.
    static let all: [RowModelCell] = {
        let identities: [VerificationLayer?] = VerificationLayer.allCases.map { $0 } + [nil]
        var cells: [RowModelCell] = []
        for status in RowModelStatusAxis.allCases {
            for identity in identities {
                for hasLines in [false, true] {
                    for modes in RowModelModesAxis.allCases {
                        for flag in [false, true] {
                            cells.append(RowModelCell(status: status, identity: identity,
                                                      hasLines: hasLines, modes: modes, flag: flag))
                        }
                    }
                }
            }
        }
        return cells
    }()
}

@Suite("Verification row model", .tags(.display))
@MainActor
struct VerificationRowModelTests {

    static let sweepLine = SearchRecheckQueryLine(
        label: "Scan (17 detectors)", foundCount: 0, foundHitCap: false,
        appliedCount: 0, remainingCount: 2, route: .ocr)

    static func layer(
        _ status: VerificationStatus, identity: VerificationLayer?,
        short: String = "Engine short line.", detail: String = "Engine detail.",
        pages: [Int]? = nil, terms: [String]? = nil,
        lines: [SearchRecheckQueryLine]? = nil, cnv: Bool = false
    ) -> LayerResult {
        LayerResult(name: identity?.name ?? "Page Count Check", symbolName: "shield",
                    status: status, shortDescription: short, detailDescription: detail,
                    pageReferences: pages, durationSeconds: 0, reviewTermTexts: terms,
                    layer: identity, queryLines: lines, couldNotVerify: cnv)
    }

    // MARK: - The derivation

    @Test("The derivation table — every status × identity × query lines × page modes × flag cell",
          arguments: RowModelCell.all)
    func derivationMatchesTheOracle(cell: RowModelCell) throws {
        let rule = try #require(rowModelOracle[cell.status]?[cell.identity?.rawValue ?? "nil"])
        let expected = rule.expected(lines: cell.hasLines, modes: cell.modes, flag: cell.flag)
        let layer = Self.layer(cell.status.status, identity: cell.identity,
                               lines: cell.hasLines ? [Self.sweepLine] : nil, cnv: cell.flag)
        #expect(VerificationRowModel.outcome(for: layer, perPageModes: cell.modes.modes) == expected)
        #expect(VerificationRowModel(layer: layer, perPageModes: cell.modes.modes).outcome == expected)
    }

    @Test("The oracle covers 1,248 cells over 78 rules")
    func oracleCoversEveryCell() {
        #expect(RowModelCell.all.count == 1_248)
        #expect(rowModelOracle.values.reduce(0) { $0 + $1.count } == 78)
    }

    @Test("Items remain only on a Detection Sweep note that carries query lines")
    func hasItemsRemainingOnlyOnTheSweepNoteWithLines() {
        for identity in VerificationLayer.allCases {
            for status in RowModelStatusAxis.allCases {
                for lines in [nil, [Self.sweepLine]] {
                    let layer = Self.layer(status.status, identity: identity, lines: lines)
                    let expected = identity == .detectionSweep && status == .info && lines != nil
                    #expect(VerificationRowModel(layer: layer, perPageModes: []).hasItemsRemaining == expected,
                            "\(identity) \(status) lines \(lines != nil)")
                }
            }
        }
    }

    @Test("The Layer 7 excess warning reads Warning; the two Layer 8 warnings read Could not verify")
    func postEngineFailVisibleRowsClassify() {
        let excess = Self.layer(
            .warn("Character count excess on page 2: output has 120, expected 100"),
            identity: .characterCount, cnv: false)
        let fonts = Self.layer(.warn("Could not inspect page fonts on page 3"),
                               identity: .fontVerification, cnv: true)
        let resources = Self.layer(
            .warn("Page 1 has no page-level /Resources — font verification skipped"),
            identity: .fontVerification, cnv: true)
        let modes: [PipelineMode] = [.searchableRedaction]
        #expect(VerificationRowModel(layer: excess, perPageModes: modes).outcome == .warning)
        #expect(VerificationRowModel(layer: fonts, perPageModes: modes).outcome == .couldNotVerify)
        #expect(VerificationRowModel(layer: resources, perPageModes: modes).outcome == .couldNotVerify)
    }

    // MARK: - The copy

    static let titles: [(VerificationLayer?, String)] = [
        (.textExtraction, "Text Layer & Annotations"),
        (.ocrCheck, "OCR of Page Images"),
        (.binaryStringSearch, "Terms in Text & Bytes"),
        (.structureCheck, "Active Content & Structure"),
        (.metadataCheck, "Document Metadata"),
        (.spatialVerification, "Character Positions"),
        (.characterCount, "Character Count"),
        (.fontVerification, "Monospace Fonts"),
        (.characterLineage, "Character Sequence"),
        (.operatorReExtraction, "Terms in Content Streams"),
        (.searchRecheck, "Search Re-check"),
        (.detectionSweep, "Detection Sweep"),
        (nil, "Page Count"),
    ]

    @Test("Every identity has its plain-language title; the page-count gate reads Page Count")
    func titleMapCoversEveryIdentity() {
        #expect(Self.titles.count == VerificationLayer.allCases.count + 1)
        for (identity, title) in Self.titles {
            #expect(VerificationRowModel.title(for: Self.layer(.pass, identity: identity)) == title)
        }
    }

    @Test("An identity-less row named for another check keeps its engine name")
    func identityLessRowKeepsItsName() {
        let row = LayerResult(name: "Binary String Search", symbolName: "shield", status: .pass,
                              shortDescription: "x", detailDescription: "", pageReferences: nil,
                              durationSeconds: 0)
        #expect(VerificationRowModel.title(for: row) == "Binary String Search")
        #expect(VerificationRowModel.rule(for: row) == nil)
    }

    static let oneLiners: [VerificationLayer: String] = [
        .textExtraction: "Checks Rasterized-page text and markup.",
        .ocrCheck: "Reads page images against redactions.",
        .binaryStringSearch: "Searches text and bytes for your terms.",
        .structureCheck: "Checks file structure for active content.",
        .metadataCheck: "Checks metadata for leftover fields.",
        .spatialVerification: "Measures characters against regions.",
        .characterCount: "Compares character counts with the record.",
        .fontVerification: "Checks fonts against Courier and Menlo.",
        .characterLineage: "Compares kept characters with the record.",
        .operatorReExtraction: "Searches text commands for your terms.",
        .searchRecheck: "Re-runs your searches on the redacted PDF.",
        .detectionSweep: "Runs the detectors on the redacted PDF.",
    ]

    @Test("Every explainer is one line of at most 42 characters")
    func explainersFitOneLine() {
        for identity in VerificationLayer.allCases {
            let line = VerificationRowModel.explainer(for: identity)
            #expect(line == Self.oneLiners[identity])
            #expect(!line.isEmpty && line.count <= 42, "\(identity): \(line.count)")
            #expect(line.hasSuffix("."))
        }
        #expect(VerificationRowModel.explainer(for: .spatialVerification, perPageModes: [.secureRasterization])
                == "Checks Rasterized pages for a text layer.")
    }

    @Test("Every rule is at most 110 characters; the sweep's carries no limit sentence")
    func rulesFitTheBudget() {
        for identity in VerificationLayer.allCases {
            let rule = VerificationRowModel.rule(for: identity)
            #expect(!rule.isEmpty && rule.count <= 110, "\(identity): \(rule.count)")
        }
        #expect(VerificationRowModel.rule(for: .detectionSweep)
                == "The detectors must report nothing beyond the items you chose to leave.")
        #expect(VerificationRowModel.rule(for: Self.layer(.fail("x"), identity: nil))
                == "Compares the PDF's page count with the original's. The other checks run only when they match.")
    }

    @Test("The six checks that can have nothing to check say why")
    func nothingToCheckReasons() {
        let expected: [VerificationLayer: String] = [
            .searchRecheck: "No searches to re-run.",
            .detectionSweep: "No scan to re-run.",
            .binaryStringSearch: "No captured text to search for.",
            .operatorReExtraction: "No captured text to search for.",
            .characterCount: "No Searchable pages to check.",
            .fontVerification: "No Searchable pages to check.",
            .characterLineage: "No Searchable pages to check.",
        ]
        for identity in VerificationLayer.allCases {
            #expect(VerificationRowModel.nothingToCheckReason(for: identity) == expected[identity])
        }
    }

    /// Every app string the rows can show.
    static var appStrings: [String] {
        var strings = VerificationLayer.allCases.flatMap { identity in
            [VerificationRowModel.title(for: layer(.pass, identity: identity)),
             VerificationRowModel.explainer(for: identity),
             VerificationRowModel.rule(for: identity),
             VerificationRowModel.nothingToCheckReason(for: identity) ?? ""]
        }
        strings += VerificationOutcome.allCases.map(\.word)
        strings += VerificationOutcome.allCases.compactMap { $0.headerClause(count: 2) }
        strings += [VerificationRowModel.skippedCaption, VerificationRowModel.skippedLead,
                    VerificationRowModel.pageCountGateRule, "Findings", "Could not verify", "Notes",
                    "Nothing to check", "Checks", "Page Count"]
        return strings.filter { !$0.isEmpty }
    }

    @Test("No row string makes an outcome promise")
    func appStringsAreMechanismWorded() throws {
        let stems = try Regex(#"\b(guarantee[ds]?|ensure[ds]?|impossible|find(?:s|ing)?|catch(?:es|ing)?|perfectly|flawlessly|best)\b|100%"#).ignoresCase() // LegalPhrases:safe (test data — the ban list itself)
        for string in Self.appStrings {
            let lower = string.lowercased()
            for term in LegalPhrases.bannedTerms {
                #expect(!lower.contains(term), "\(string) contains \(term)")
            }
            #expect(string.firstMatch(of: stems) == nil, "\(string)")
        }
    }

    // MARK: - The caption, the detail, the spoken label

    @Test("A passing row captions its one-liner; a row with no identity its engine line")
    func passCaption() {
        let ocr = VerificationRowModel(layer: Self.layer(.pass, identity: .ocrCheck), perPageModes: [])
        #expect(ocr.caption == "Reads page images against redactions.")
        let gate = VerificationRowModel(layer: Self.layer(.pass, identity: nil, short: "No issues found."),
                                        perPageModes: [])
        #expect(gate.caption == "No issues found.")
        #expect(gate.explainer == nil)
    }

    @Test("A skipped check reads Could not verify, captions its state, leads with its cause, hides the engine detail")
    func skippedRow() {
        for identity in [VerificationLayer.characterCount, .characterLineage] {
            let model = VerificationRowModel(layer: Self.layer(.skipped, identity: identity), perPageModes: [])
            #expect(model.outcome == .couldNotVerify)
            #expect(model.caption == "Skipped. No record to compare with.")
            #expect(model.lead == ["Only a full Redact run saves that record."])
            #expect(model.showsEngineDetail == false)
        }
    }

    @Test("Only a skipped check hides the engine detail", arguments: RowModelStatusAxis.allCases)
    func engineDetailShownUnlessSkipped(status: RowModelStatusAxis) {
        let model = VerificationRowModel(layer: Self.layer(status.status, identity: .ocrCheck), perPageModes: [])
        #expect(model.showsEngineDetail == (status != .skipped))
    }

    @Test("The sweep note's caption counts the run's own sweep and names its pages")
    func sweepNoteCaption() {
        let two = Self.layer(.info("… Open Scan to review."), identity: .detectionSweep,
                             pages: [0, 2], lines: [Self.sweepLine])
        #expect(VerificationRowModel(layer: two, perPageModes: []).caption
                == "2 possible items remain on pages 1\u{00A0}and\u{00A0}3.")
        let one = SearchRecheckQueryLine(label: "Scan (17 detectors)", foundCount: 0, foundHitCap: false,
                                         appliedCount: 0, remainingCount: 1, route: .ocr)
        #expect(VerificationRowModel(layer: Self.layer(.info("x"), identity: .detectionSweep, pages: [4],
                                                       lines: [one]), perPageModes: []).caption
                == "1 possible item remains on\u{00A0}page\u{00A0}5.")
        let applied = SearchRecheckQueryLine(label: "Scan (17 detectors)", foundCount: 6, foundHitCap: false,
                                             appliedCount: 4, remainingCount: 2, route: .ocr)
        #expect(VerificationRowModel(layer: Self.layer(.info("x"), identity: .detectionSweep, pages: [1],
                                                       lines: [applied]), perPageModes: []).caption
                == "Further possible items remain on\u{00A0}page\u{00A0}2.")
    }

    @Test("A needs-review caption quotes the terms and is privacy-sensitive; no other caption is")
    func needsReviewCaptionIsPrivacySensitive() {
        let review = VerificationRowModel(
            layer: Self.layer(.attention("x"), identity: .binaryStringSearch, pages: [1], terms: ["Delia"]),
            perPageModes: [])
        #expect(review.caption == "\u{201C}Delia\u{201D} is still readable on\u{00A0}page\u{00A0}2. "
                + "It matches text you redacted. Use text\u{00A0}search to redact the rest.")
        #expect(review.captionIsPrivacySensitive)
        for status in RowModelStatusAxis.allCases where status != .attention {
            let model = VerificationRowModel(layer: Self.layer(status.status, identity: .ocrCheck, terms: ["Delia"]),
                                             perPageModes: [])
            #expect(model.captionIsPrivacySensitive == false)
        }
    }

    @Test("The OCR Check's fragment arm captions with its own sentence and remedy — the box, not a search; the whole-term arm is unchanged")
    func fragmentCaption() {
        func result(_ terms: [String], pages: [Int]?, fragment: Bool) -> LayerResult {
            LayerResult(name: VerificationLayer.ocrCheck.name, symbolName: "shield", status: .attention("x"),
                        shortDescription: "Engine short line.", detailDescription: "", pageReferences: pages,
                        durationSeconds: 0, reviewTermTexts: terms, layer: .ocrCheck, reviewIsFragment: fragment)
        }
        let one = VerificationRowModel(layer: result(["123-45-6789"], pages: [1], fragment: true), perPageModes: [])
        #expect(one.outcome == .needsReview)
        #expect(one.caption == "Part of \u{201C}123-45-6789\u{201D} is readable beside a redaction box on\u{00A0}page\u{00A0}2. Adjust the box and redact again.")
        #expect(one.captionIsPrivacySensitive)
        let two = VerificationRowModel(layer: result(["Delia", "Hartwell"], pages: [0, 2], fragment: true), perPageModes: [])
        #expect(two.caption == "Parts of \u{201C}Delia\u{201D} and \u{201C}Hartwell\u{201D} are readable beside redaction boxes on pages 1\u{00A0}and\u{00A0}3. Adjust the boxes and redact again.")
        let whole = VerificationRowModel(layer: result(["Delia"], pages: [1], fragment: false), perPageModes: [])
        #expect(whole.caption == "\u{201C}Delia\u{201D} is still readable on\u{00A0}page\u{00A0}2. It matches text you redacted. Use text\u{00A0}search to redact the rest.")
        #expect(LayerResultRow.rowSubtitleText(layer: result(["123-45-6789"], pages: [1], fragment: true))
                == "Part of \u{201C}123-45-6789\u{201D} is readable beside a redaction box on\u{00A0}page\u{00A0}2. Adjust the box and redact again.")
        #expect(LayerResultRow.rowSubtitleIsPrivacySensitive(layer: result(["123-45-6789"], pages: [1], fragment: true)))
    }

    @Test("The spoken label is the title, the status word and the caption")
    func spokenLabelPerOutcome() {
        let cases: [(LayerResult, [PipelineMode], String)] = [
            (Self.layer(.pass, identity: .ocrCheck), [],
             "OCR of Page Images, Passed. Reads page images against redactions."),
            (Self.layer(.pass, identity: .characterCount), [.secureRasterization],
             "Character Count, Nothing to check. No Searchable pages to check."),
            (Self.layer(.info("x"), identity: .ocrCheck, short: "Fill artifact on page 1."), [],
             "OCR of Page Images, Note. Fill artifact on page 1."),
            (Self.layer(.warn("x"), identity: .structureCheck, short: "A second %%EOF."), [],
             "Active Content & Structure, Warning. A second %%EOF."),
            (Self.layer(.warn("x"), identity: .ocrCheck, short: "OCR could not be run on 1 page", cnv: true), [],
             "OCR of Page Images, Could not verify. OCR could not be run on 1 page."),
            (Self.layer(.attention("x"), identity: .searchRecheck, short: "Text remains."), [],
             "Search Re-check, Needs review. Text remains."),
            (Self.layer(.fail("x"), identity: nil, short: "Page count changed."), [],
             "Page Count, Failed. Page count changed."),
        ]
        for (layer, modes, label) in cases {
            #expect(VerificationRowModel(layer: layer, perPageModes: modes).spokenLabel == label)
        }
    }

    @Test("Share asks first exactly for Could not verify, Needs review and Failed")
    func gatesSharing() {
        #expect(VerificationOutcome.allCases.filter(\.gatesSharing) == [.couldNotVerify, .needsReview, .failed])
    }

    // MARK: - The summary line

    static let secureChecks: [VerificationLayer] = [
        .textExtraction, .ocrCheck, .binaryStringSearch, .structureCheck, .metadataCheck,
        .searchRecheck, .detectionSweep,
    ]
    static let secure: [PipelineMode] = [.secureRasterization, .secureRasterization]
    static let searchable: [PipelineMode] = [.searchableRedaction, .searchableRedaction]

    /// A report over `checks`, every row passing except those in `rows`.
    static func report(_ checks: [VerificationLayer], _ modes: [PipelineMode],
                       _ overall: VerificationStatus = .pass,
                       _ rows: [VerificationLayer: LayerResult] = [:]) -> VerificationReport {
        VerificationReport(layers: checks.map { rows[$0] ?? layer(.pass, identity: $0) },
                           overallStatus: overall, durationSeconds: 1, perPageModes: modes)
    }

    static let sweepNote = layer(.info("x"), identity: .detectionSweep, pages: [0, 2], lines: [sweepLine])
    static let idleRecheck = layer(.info("x"), identity: .searchRecheck)
    static let all = VerificationLayer.allCases

    /// The eleven summary lines of the merged design, one per report shape.
    static let summaries: [(VerificationReport, String)] = [
        (report(secureChecks, secure), "7 of 7 checks passed"),
        (report(secureChecks, secure, .pass, [.detectionSweep: sweepNote]), "6 of 7 checks passed · 1\u{00A0}note"),
        (report(secureChecks, secure, .pass, [.detectionSweep: sweepNote, .searchRecheck: idleRecheck]),
         "5 of 7 checks passed · 1\u{00A0}note · 1\u{00A0}had nothing to check"),
        (report(all, searchable), "12 of 12 checks passed"),
        (report(all, secure), "9 of 12 checks passed · 3\u{00A0}had nothing to check"),
        (report(all, searchable, .warn("x"), [
            .spatialVerification: layer(.warn("x"), identity: .spatialVerification),
            .ocrCheck: layer(.info("x"), identity: .ocrCheck)]),
         "10 of 12 checks passed · 1\u{00A0}warning · 1\u{00A0}note"),
        (report(all, searchable, .warn("x"), [
            .ocrCheck: layer(.warn("x"), identity: .ocrCheck, cnv: true), .searchRecheck: idleRecheck]),
         "10 of 12 checks passed · 1\u{00A0}could not verify · 1\u{00A0}had nothing to check"),
        (report(all, searchable, .attention("x"), [
            .binaryStringSearch: layer(.attention("x"), identity: .binaryStringSearch, terms: ["Delia"]),
            .ocrCheck: layer(.warn("x"), identity: .ocrCheck, cnv: true),
            .spatialVerification: layer(.warn("x"), identity: .spatialVerification),
            .searchRecheck: idleRecheck]),
         "8 of 12 checks passed · 1\u{00A0}needs review · 1\u{00A0}warning · 1\u{00A0}could not verify"
            + " · 1\u{00A0}had nothing to check"),
        (report(secureChecks, secure, .fail("x"), [.metadataCheck: layer(.fail("x"), identity: .metadataCheck)]),
         "6 of 7 checks passed · 1\u{00A0}failed"),
        (report(all, searchable, .warn("x"), [
            .characterCount: layer(.skipped, identity: .characterCount),
            .characterLineage: layer(.skipped, identity: .characterLineage),
            .ocrCheck: layer(.info("x"), identity: .ocrCheck)]),
         "9 of 12 checks passed · 2\u{00A0}could not verify · 1\u{00A0}note"),
        (VerificationReport(layers: [layer(.fail("x"), identity: nil)], overallStatus: .fail("x"),
                            durationSeconds: 0),
         "0 of 1 check passed · 1\u{00A0}failed"),
    ]

    @Test("The summary line counts only passing checks and names every other outcome")
    func elevenSummaryLines() {
        #expect(Self.summaries.count == 11)
        for (report, expected) in Self.summaries {
            #expect(VerificationResultsView.detailsSummaryText(for: report) == expected)
        }
    }

    @Test("Every clause, singular and plural, in screen order after the passed base")
    func clausesInOrderSingularAndPlural() {
        let one: [VerificationLayer: LayerResult] = [
            .textExtraction: Self.layer(.fail("x"), identity: .textExtraction),
            .ocrCheck: Self.layer(.attention("x"), identity: .ocrCheck),
            .binaryStringSearch: Self.layer(.warn("x"), identity: .binaryStringSearch, cnv: true),
            .structureCheck: Self.layer(.warn("x"), identity: .structureCheck),
            .metadataCheck: Self.layer(.info("x"), identity: .metadataCheck),
            .searchRecheck: Self.idleRecheck,
        ]
        #expect(VerificationResultsView.detailsSummaryText(for: Self.report(Self.secureChecks, Self.secure,
                                                                            .fail("x"), one))
                == "1 of 7 checks passed · 1\u{00A0}failed · 1\u{00A0}needs review · 1\u{00A0}warning"
                + " · 1\u{00A0}could not verify · 1\u{00A0}note · 1\u{00A0}had nothing to check")
        let pairs: [VerificationLayer: LayerResult] = [
            .textExtraction: Self.layer(.fail("x"), identity: .textExtraction),
            .ocrCheck: Self.layer(.fail("x"), identity: .ocrCheck),
            .binaryStringSearch: Self.layer(.attention("x"), identity: .binaryStringSearch),
            .operatorReExtraction: Self.layer(.attention("x"), identity: .operatorReExtraction),
            .structureCheck: Self.layer(.warn("x"), identity: .structureCheck, cnv: true),
            .characterLineage: Self.layer(.skipped, identity: .characterLineage),
            .metadataCheck: Self.layer(.warn("x"), identity: .metadataCheck),
            .spatialVerification: Self.layer(.warn("x"), identity: .spatialVerification),
            .characterCount: Self.layer(.info("x"), identity: .characterCount),
            .detectionSweep: Self.sweepNote,
            .searchRecheck: Self.idleRecheck,
        ]
        #expect(VerificationResultsView.detailsSummaryText(for: Self.report(Self.all, Self.secure, .fail("x"), pairs))
                == "0 of 12 checks passed · 2\u{00A0}failed · 2\u{00A0}need review · 2\u{00A0}warnings"
                + " · 2\u{00A0}could not verify · 2\u{00A0}notes · 2\u{00A0}had nothing to check")
    }

    // MARK: - The expanded block

    @Test("The expanded block per outcome: the lead, the explainer unless the caption is it, the rule, the detail unless skipped")
    func expandedBlockItemsPerOutcome() {
        typealias Item = LayerResultRow.ExpandedItem
        func items(_ layer: LayerResult, _ modes: [PipelineMode] = [], pages: Bool = true) -> [Item] {
            LayerResultRow.expandedItems(model: VerificationRowModel(layer: layer, perPageModes: modes),
                                         layer: layer, opensPages: pages)
        }
        let took = Item.timing("Took under 0.1 s")
        let ocr = Item.explainer("Reads page images against redactions.")
        let ocrRule = Item.rule(VerificationRowModel.rule(for: .ocrCheck))
        // Passed: the caption already is the explainer — never shown twice.
        #expect(items(Self.layer(.pass, identity: .ocrCheck)) == [ocrRule, .detail("Engine detail."), took])
        // Every other outcome opens with the explainer, then the rule.
        #expect(items(Self.layer(.warn("x"), identity: .ocrCheck, pages: [1]))
                == [ocr, ocrRule, .detail("Engine detail."), .pageChips([1]), took])
        #expect(items(Self.layer(.warn("x"), identity: .ocrCheck, cnv: true))
                == [ocr, ocrRule, .detail("Engine detail."), took])
        #expect(items(Self.layer(.attention("x"), identity: .ocrCheck, pages: [0], terms: ["t"]), pages: false)
                == [ocr, ocrRule, .detail("Engine detail."), took])
        #expect(items(Self.layer(.fail("x"), identity: .ocrCheck)) == [ocr, ocrRule, .detail("Engine detail."), took])
        #expect(items(Self.layer(.info("x"), identity: .ocrCheck)) == [ocr, ocrRule, .detail("Engine detail."), took])
        #expect(items(Self.layer(.pass, identity: .characterCount), [.secureRasterization])
                == [.explainer("Compares character counts with the record."),
                    .rule(VerificationRowModel.rule(for: .characterCount)), .detail("Engine detail."), took])
        // Skipped: the lead first; no engine detail (it names a reason that does not apply).
        #expect(items(Self.layer(.skipped, identity: .characterLineage))
                == [.lead("Only a full Redact run saves that record."),
                    .explainer("Compares kept characters with the record."),
                    .rule(VerificationRowModel.rule(for: .characterLineage)), took])
        // The sweep note: its lines and its pages; its time is the re-check's.
        #expect(items(Self.sweepNote)
                == [.explainer("Runs the detectors on the redacted PDF."),
                    .rule(VerificationRowModel.rule(for: .detectionSweep)), .detail("Engine detail."),
                    .queryLines, .pageChips([0, 2]), .timing("Timed with Search Re-check")])
        // The page-count gate: no explainer; its rule; the caption is the engine's line.
        #expect(items(Self.layer(.fail("x"), identity: nil, detail: ""))
                == [.rule(VerificationRowModel.pageCountGateRule), took])
    }

    @Test("Terms in Content Streams says where its scan stopped when later pages exist")
    func contentStreamStopLine() {
        let row = Self.layer(.attention("x"), identity: .operatorReExtraction, pages: [1], terms: ["Delia"])
        let modes: [PipelineMode] = [.searchableRedaction, .searchableRedaction, .searchableRedaction]
        #expect(VerificationRowModel(layer: row, perPageModes: modes).lead
                == ["Scanning stopped at page 2. Later pages were not searched."])
        #expect(VerificationRowModel(layer: row, perPageModes: Array(modes.prefix(2))).lead == [])
        #expect(VerificationRowModel(layer: row, perPageModes: []).lead == [])
    }

    @Test("Review terms are normalised: whitespace collapsed, case duplicates dropped")
    func reviewTermsNormalised() {
        #expect(VerificationRowModel.normalizedTerms(["Margaret  Thompson", "O'Brien\nLtd", "margaret thompson", " "])
                == ["Margaret Thompson", "O'Brien Ltd"])
        #expect(VerificationRowModel.reviewSentence(termTexts: ["Delia", "Fox", "Lane"], pages: [0, 1, 2])
                == "\u{201C}Delia\u{201D}, \u{201C}Fox\u{201D}, and \u{201C}Lane\u{201D} are still readable "
                + "on pages 1, 2,\u{00A0}and\u{00A0}3. They match text you redacted. "
                + "Use text\u{00A0}search to redact the rest.")
        #expect(VerificationRowModel.reviewSentence(termTexts: ["acme"], pages: nil)
                == "\u{201C}acme\u{201D} is still readable in the PDF. It matches text you redacted. "
                + "Use text\u{00A0}search to redact the rest.")
    }

    @Test("A Search Re-check that needs review names its searches, the matches and the pages")
    func recheckReviewCaption() {
        func line(_ label: String, _ remaining: Int) -> SearchRecheckQueryLine {
            SearchRecheckQueryLine(label: label, foundCount: 4, foundHitCap: false, appliedCount: 2,
                                   remainingCount: remaining, route: .textLayer)
        }
        let one = VerificationRowModel(
            layer: Self.layer(.attention("x"), identity: .searchRecheck, pages: [1], terms: ["Delia"],
                              lines: [line("\u{201C}Delia\u{201D}", 1), line("\u{201C}Fox\u{201D}", 0)]),
            perPageModes: [])
        #expect(one.caption == "Your search \u{201C}Delia\u{201D} still has 1 match on\u{00A0}page\u{00A0}2.")
        #expect(one.lead == ["Run it again with OCR on to redact the rest."])
        #expect(one.captionIsPrivacySensitive)
        let two = VerificationRowModel(
            layer: Self.layer(.attention("x"), identity: .searchRecheck, pages: [0, 1],
                              lines: [line("\u{201C}Delia\u{201D}", 2), line("\u{201C}\\d{4}\u{201D}", 1)]),
            perPageModes: [])
        #expect(two.caption == "Your searches \u{201C}Delia\u{201D} and \u{201C}\\d{4}\u{201D} still have 3 matches "
                + "on pages 1\u{00A0}and\u{00A0}2.")
        #expect(two.lead == ["Run them again with OCR on to redact the rest."])
    }

    @Test("The spoken pages: up to five, then four and a count")
    func spokenPages() {
        #expect(VerificationRowModel.spokenPages([2]) == "Page 3.")
        #expect(VerificationRowModel.spokenPages([0, 2]) == "Pages 1 and 3.")
        #expect(VerificationRowModel.spokenPages([1, 2, 3]) == "Pages 2, 3, and 4.")
        #expect(VerificationRowModel.spokenPages(Array(1...12)) == "Pages 2, 3, 4, 5, and 8 more.")
        #expect(VerificationRowModel.spokenPages([]) == nil)
    }

    @Test("Each outcome has its outline mark")
    func markSymbols() {
        #expect(VerificationOutcome.allCases.map(\.markSymbolName) == [
            "checkmark.circle", "minus.circle", "info.circle", "exclamationmark.circle",
            "questionmark.circle", "eye.circle", "xmark.circle",
        ])
    }
}
