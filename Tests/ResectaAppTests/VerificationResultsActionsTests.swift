import Testing
import Foundation
import SwiftUI
@testable import ResectaApp
@testable import RedactionEngine

// The grouped results page's rules, read without a host: which capsule
// leads, how Share is drawn, which action rows show and in what order, when
// Share speaks its confirm hint (the Share tap's gate with the document's
// acknowledgements, never the rows), what the count ring shows, which group
// opens, how page links and the run section read, and the completion line.

@Suite("Verification results actions and layout", .tags(.display))
@MainActor
struct VerificationResultsActionsTests {

    typealias Actions = VerificationResultsActions
    typealias Fixtures = VerificationDebugFixtures

    static func report(_ status: VerificationStatus) -> VerificationReport {
        VerificationReport(layers: [], overallStatus: status, durationSeconds: 0)
    }

    // MARK: - The capsules

    @Test("Keep Editing leads on FAIL and ATTENTION, and whenever Share cannot share",
          arguments: [
            (VerificationStatus.pass, false), (.info("i"), false), (.warn("w"), false),
            (.attention("a"), true), (.fail("f"), true), (.skipped, false),
          ])
    func swapRule(status: VerificationStatus, swaps: Bool) {
        #expect(Actions.swapsPrimaryAction(report: Self.report(status), shareDisabled: false) == swaps)
        #expect(Actions.swapsPrimaryAction(report: Self.report(status), shareDisabled: true))
    }

    @Test("Share is filled teal; outlined red on FAIL and pink on ATTENTION under the filled Keep Editing")
    func shareCapsuleStyle() {
        #expect(Actions.shareCapsuleKind(report: Self.report(.pass), swapped: false) == .filled(.teal))
        #expect(Actions.shareCapsuleKind(report: Self.report(.skipped), swapped: false) == .filled(.teal))
        #expect(Actions.shareCapsuleKind(report: Self.report(.fail("f")), swapped: true) == .outlined(.red))
        #expect(Actions.shareCapsuleKind(report: Self.report(.attention("a")), swapped: true) == .outlined(.pink))
        // Disabled on a clean run: swapped, outlined — and grey, because the
        // style reads `isEnabled`.
        #expect(Actions.shareCapsuleKind(report: Self.report(.pass), swapped: true) == .outlined(.teal))
    }

    @Test("The action rows: Run Verification on a skipped report with its output, Keep Editing unless it leads, Preview with the output")
    func actionRowOrder() {
        #expect(Actions.actionRows(report: Self.report(.pass), outputExists: true, previewAvailable: true,
                                   swapped: false) == [.keepEditing, .preview])
        #expect(Actions.actionRows(report: Self.report(.fail("f")), outputExists: true, previewAvailable: true,
                                   swapped: true) == [.preview])
        #expect(Actions.actionRows(report: Self.report(.skipped), outputExists: true, previewAvailable: true,
                                   swapped: false) == [.runVerification, .keepEditing, .preview])
        // Output missing: Preview and Run Verification hide; swapped, the card is empty.
        #expect(Actions.actionRows(report: Self.report(.skipped), outputExists: false, previewAvailable: false,
                                   swapped: true) == [])
        // Stale: both stay.
        #expect(Actions.actionRows(report: Self.report(.skipped), outputExists: true, previewAvailable: true,
                                   swapped: true) == [.runVerification, .preview])
    }

    @Test("The undo footnote and the spoken Keep Editing label")
    func undoWords() {
        #expect(VerificationResultsView.undoFootnote == "Redact cleared undo; use Delete\u{00A0}Region instead.")
        #expect(VerificationResultsView.keepEditingAccessibilityLabel
                == "Keep Editing. Return to the editor to adjust regions, then run Redact again. "
                + "Redact cleared undo; use Delete Region instead.")
    }

    @Test("The undo words are drawn once, beside Keep Editing")
    func undoWordsAreDrawnOnceBesideKeepEditing() throws {
        typealias Place = Actions.UndoWordsPlace
        // (seeded report, Share disabled, output exists, Preview available, where the words go)
        let rows: [(String, Bool, Bool, Bool, Place)] = [
            ("secureAllPass", false, true, true, .onKeepEditingRow),        // Keep Editing is a row
            ("secureFail", false, true, true, .underCard),                  // it leads: failed
            ("searchableAttentionFull", false, true, true, .underCard),     // it leads: needs review
            ("secureAllPass", true, true, true, .underCard),                // it leads: Share disabled, the PDF present
            ("secureAllPass", true, false, false, .centredUnderReason),     // it leads: the PDF gone, no rows
            ("secureSkippedOff", false, true, true, .onKeepEditingRow),     // a row, after Run Verification
        ]
        var ran = 0
        for (name, disabled, output, preview, place) in rows {
            let report = try #require(Fixtures.all[name], "no seeded report \(name)")
            let places = Actions.undoWordsPlaces(report: report, shareDisabled: disabled,
                                                 outputExists: output, previewAvailable: preview)
            #expect(places == [place], "\(name) disabled \(disabled) output \(output) preview \(preview)")
            ran += 1
        }
        #expect(ran == 6)
        // The skipped report's rows put Keep Editing after Run Verification.
        let skipped = try #require(Fixtures.all["secureSkippedOff"])
        #expect(Actions.actionRows(report: skipped, outputExists: true, previewAvailable: true,
                                   swapped: false) == [.runVerification, .keepEditing, .preview])
    }

    @Test("Over every state, the undo words have one place, and it is beside Keep Editing")
    func undoWordsOnePlaceInEveryState() {
        let statuses: [VerificationStatus] = [.pass, .info("i"), .warn("w"), .attention("a"), .fail("f"), .skipped]
        var cases = 0
        for status in statuses {
            for disabled in [false, true] {
                for output in [false, true] {
                    for preview in [false, true] {
                        let report = Self.report(status)
                        let places = Actions.undoWordsPlaces(report: report, shareDisabled: disabled,
                                                             outputExists: output, previewAvailable: preview)
                        let swapped = Actions.swapsPrimaryAction(report: report, shareDisabled: disabled)
                        let rows = Actions.actionRows(report: report, outputExists: output,
                                                      previewAvailable: preview, swapped: swapped)
                        #expect(places.count == 1)
                        // On the row exactly when Keep Editing is a row; centred
                        // exactly when there is no card.
                        #expect(places.contains(.onKeepEditingRow) == rows.contains(.keepEditing))
                        #expect(places.contains(.centredUnderReason) == rows.isEmpty)
                        #expect(places.contains(.onKeepEditingRow) == !swapped)
                        cases += 1
                    }
                }
            }
        }
        #expect(cases == 48)
    }

    // MARK: - The Share hint (moved here with Share)

    static func willConfirm(_ report: VerificationReport, _ doc: DocumentState = DocumentState(),
                            canExport: Bool = true, concealed: [Int] = []) -> Bool {
        Actions.shareWillConfirm(report: report, canExport: canExport, documentState: doc, concealedPages: concealed)
    }

    /// One reason Share asks, with the document state that raises it and the
    /// gate's kind for it.
    struct HintRow {
        let name: String
        let report: VerificationReport
        let formFields: Int
        let concealed: [Int]
        let kind: String

        func document() -> DocumentState {
            let doc = DocumentState()
            doc.sourceFilledFormFieldCount = formFields
            return doc
        }

        /// The row's own acknowledgement, set.
        func acknowledged() -> DocumentState {
            let doc = document()
            switch kind {
            case "failOrAttention": doc.failShareAcknowledged = true
            case "skipped": doc.skippedShareAcknowledged = true
            case "incompleteWarn": doc.incompleteWarnShareAcknowledged = true
            case "possibleItems": doc.possibleItemsShareAcknowledged = true
            case "concealedAnnotations": doc.concealedAnnotationsShareAcknowledged = true
            default: Issue.record("no acknowledgement for \(kind)")
            }
            return doc
        }
    }

    static let hintRows: [HintRow] = [
        HintRow(name: "a failed check", report: Fixtures.secureFail, formFields: 0, concealed: [], kind: "failOrAttention"),
        HintRow(name: "a skipped run", report: Fixtures.secureSkippedOff, formFields: 0, concealed: [], kind: "skipped"),
        HintRow(name: "an incomplete warning", report: Fixtures.searchableSkipInduced, formFields: 0, concealed: [],
                kind: "incompleteWarn"),
        HintRow(name: "possible items left", report: Fixtures.secureScreenshot, formFields: 0, concealed: [],
                kind: "possibleItems"),
        HintRow(name: "form values not carried", report: Fixtures.secureAllPass, formFields: 4, concealed: [],
                kind: "possibleItems"),
        HintRow(name: "covered text in the original", report: Fixtures.secureAllPass, formFields: 0, concealed: [0],
                kind: "concealedAnnotations"),
    ]

    @Test("The hint text is spoken only — one sentence, no promise")
    func hintText() {
        #expect(Actions.shareConfirmHint == "Asks you to confirm before sharing.")
    }

    @Test("The Share hint is spoken for each of the five confirm families")
    func hintForEachFamily() {
        #expect(Self.hintRows.count == 6)
        for row in Self.hintRows {
            let doc = row.document()
            #expect(Self.willConfirm(row.report, doc, concealed: row.concealed), "\(row.name)")
            #expect(DocumentEditorView.shareConfirmKind(
                report: row.report, documentState: doc, concealedPages: row.concealed)?.id == row.kind, "\(row.name)")
        }
    }

    @Test("No hint once the family is acknowledged, when Share is disabled, or when nothing asks")
    func noHintWhenNoConfirmOpens() {
        #expect(Self.hintRows.count == 6)
        for row in Self.hintRows {
            #expect(!Self.willConfirm(row.report, row.acknowledged(), concealed: row.concealed), "\(row.name), acknowledged")
            #expect(!Self.willConfirm(row.report, row.document(), canExport: false, concealed: row.concealed),
                    "\(row.name), Share disabled")
        }
        let quiet = [Fixtures.secureAllPass, Fixtures.secureWarningOnly, Fixtures.securePassRidingNote]
        #expect(quiet.count == 3)
        for report in quiet {
            #expect(!Self.willConfirm(report))
        }
    }

    @Test("The hint and the Share tap's gate agree on every seeded report")
    func hintAgreesWithTheGate() {
        #expect(Fixtures.all.count == 18)
        var differFromThreeFamilies: Set<String> = []
        for (name, report) in Fixtures.all {
            for concealed in [[], [0]] as [[Int]] {
                let doc = DocumentState()
                let gate = DocumentEditorView.shareConfirmKind(report: report, documentState: doc, concealedPages: concealed)
                #expect(Self.willConfirm(report, doc, concealed: concealed) == (gate != nil), "\(name), pages \(concealed)")
            }
            let threeFamilies = DocumentEditorView.shareNeedsFailConfirm(report: report, acknowledged: false)
                || DocumentEditorView.shareNeedsSkippedConfirm(report: report, acknowledged: false)
                || DocumentEditorView.shareNeedsIncompleteWarnConfirm(report: report, acknowledged: false)
            if Self.willConfirm(report) != threeFamilies { differFromThreeFamilies.insert(name) }
        }
        #expect(differFromThreeFamilies == ["secureScreenshot", "secureScanOnly"])
    }

    @Test("The hint reads the covered pages of the results screen's covered-text item")
    func hintReadsTheCoveredTextPages() {
        #expect(Actions.concealedPages(in: [.coveredTextInOriginal(pages: [2, 5]), .filledFormValuesNotCarried(count: 1)]) == [2, 5])
        #expect(Actions.concealedPages(in: [.filledFormValuesNotCarried(count: 3)]) == [])
        #expect(Actions.concealedPages(in: []) == [])
    }

    @Test("Before the results screen has derived its findings, covered text alone raises no hint")
    func noCoveredTextHintBeforeTheFirstDerivation() {
        #expect(!Self.willConfirm(Fixtures.secureAllPass, DocumentState(), concealed: Actions.concealedPages(in: [])))
        #expect(Self.willConfirm(Fixtures.secureAllPass, DocumentState(),
                                 concealed: Actions.concealedPages(in: [.coveredTextInOriginal(pages: [0])])))
    }

    @Test("The results screen hands Share's hint the covered pages of its findings")
    func resultsScreenPassesTheCoveredPages() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/ResectaApp/Views/VerificationResultsView.swift"),
                                encoding: .utf8)
        let argument = "concealedPages: VerificationResultsActions.concealedPages(in: findings)"
        #expect(source.components(separatedBy: argument).count == 2, "the argument appears exactly once")
        let call = try #require(source.range(of: "VerificationResultsActions("))
        let padding = try #require(source.range(of: ".padding(.top, ResectaTokens.Results.blockGap)",
                                                range: call.upperBound..<source.endIndex))
        let at = try #require(source.range(of: argument))
        #expect(call.upperBound <= at.lowerBound && at.upperBound <= padding.lowerBound,
                "the argument lies inside the call, before the padding that follows it")
    }

    // MARK: - The count ring

    @Test("The ring: P of T with T the checks that had something to check, the verdict's tone; SKIPPED draws the slot")
    func ringContent() {
        #expect(VerificationMasthead.ringContent(report: Fixtures.searchableAllRasterized)
                == .count(passed: 11, total: 11, tone: .pass))
        #expect(VerificationMasthead.ringContent(report: Fixtures.searchableAttentionMixed)
                == .count(passed: 9, total: 13, tone: .attention))
        #expect(VerificationMasthead.ringContent(report: Fixtures.secureWarningOnly)
                == .count(passed: 7, total: 8, tone: .warn))
        #expect(VerificationMasthead.ringContent(report: Fixtures.pageCountGate)
                == .count(passed: 0, total: 1, tone: .fail))
        #expect(VerificationMasthead.ringContent(report: Fixtures.secureAllFailed)
                == .count(passed: 0, total: 8, tone: .fail))
        #expect(VerificationMasthead.ringContent(report: Fixtures.secureSkippedOff) == .skipped)
        #expect(VerificationMasthead.ringContent(report: Self.report(.info("i"))) == .count(passed: 0, total: 0, tone: .pass))
    }

    @Test("The ring of a result that no longer stands: the same count, its arc in the caption grey; a run whose checks did not run keeps its slot")
    func ringWhenTheResultDoesNotStand() {
        let states: [(name: String, outputExists: Bool, isStale: Bool)] = [
            ("standing", true, false), ("boxes changed", true, true), ("PDF gone", false, false), ("both", false, true),
        ]
        #expect(Fixtures.all.count == 18)
        var rows = 0
        for (name, report) in Fixtures.all.sorted(by: { $0.key < $1.key }) {
            let today = VerificationMasthead.ringContent(report: report)
            for state in states {
                let shown = VerificationMasthead.ringContent(
                    report: report, outputExists: state.outputExists, isStale: state.isStale)
                rows += 1
                switch today {
                case .skipped:
                    #expect(shown == .skipped, "\(name), \(state.name)")
                case let .count(passed, total, tone):
                    #expect(tone != .noLongerStands, "\(name): a standing ring keeps its verdict's tone")
                    let stands = state.outputExists && !state.isStale
                    #expect(shown == (stands ? today : .count(passed: passed, total: total, tone: .noLongerStands)),
                            "\(name), \(state.name)")
                case .running:
                    Issue.record("\(name): a report's ring is never the running one")
                }
            }
        }
        #expect(rows == 18 * 4)
        #expect(CountRing.arcColor(.noLongerStands) == ResectaTokens.SemanticColor.supportText)
    }

    @Test("The figure is 22 pt below ten checks and 20 pt from ten; the arc is P over T")
    func ringMetrics() {
        #expect(CountRing.figureSize(total: 7) == 22)
        #expect(CountRing.figureSize(total: 12) == 20)
        #expect(abs(CountRing.progress(passed: 7, total: 12) - 7.0 / 12.0) < 1e-9)
        #expect(CountRing.progress(passed: 0, total: 0) == 0)
    }

    @Test("The PASS note pair points below on the grouped layout")
    func passNotePair() {
        #expect(VerificationResultsView.mastheadSubtitle(report: Fixtures.secureScreenshot)
                == "Read the note below before you share the PDF.")
        #expect(VerificationResultsView.mastheadSubtitle(report: Fixtures.securePassRidingNote)
                == "Read the note below before you share the PDF.")
    }

    // MARK: - Sections

    @Test("The cluster opens by default only for riding notes with nothing above")
    func clusterRules() {
        func partition(_ report: VerificationReport) -> VerificationLayerPartition {
            VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
        }
        #expect(VerificationDetailsSection.clusterOpensByDefault(partition(Fixtures.securePassRidingNote)))
        #expect(!VerificationDetailsSection.clusterOpensByDefault(partition(Fixtures.secureScreenshot)))
        #expect(!VerificationDetailsSection.clusterOpensByDefault(partition(Fixtures.searchableAllRasterized)))
    }

    @Test("The list row holds every check but the plain warnings, on every run that has checks")
    func listRowHoldsThePassedChecks() throws {
        func partition(_ report: VerificationReport) -> VerificationLayerPartition {
            VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
        }
        var examined = 0, joined = 0, warned = 0
        for (name, report) in Fixtures.all {
            let p = partition(report)
            // Every check but a plain warning, which has its own card.
            let expected = report.layers.indices.filter { p.outcomes[$0] != .warning }
            #expect(VerificationDetailsSection.listRowMembers(p) == expected, "\(name)")
            if !p.nothingToCheck.isEmpty { joined += 1 }
            if expected.count < report.layers.count { warned += 1 }
            examined += 1
        }
        print("[list-row] seeded reports \(examined), with checks that had nothing to check in the row \(joined), "
              + "with a plain warning outside it \(warned)")
        #expect(examined == 18)
        #expect(joined == 6, "the seeded reports whose row takes in checks that had nothing to check")
        #expect(warned == 4, "the seeded reports with a plain warning outside the row")
        // A run where every check passed: one row holding every check, closed.
        let clean = partition(Fixtures.secureAllPass)
        #expect(VerificationDetailsSection.listRowMembers(clean) == Array(Fixtures.secureAllPass.layers.indices))
        #expect(clean.clusterTitle == "8 checks passed")
        #expect(!VerificationDetailsSection.clusterOpensByDefault(clean))
        // A riding note with nothing above still opens on arrival.
        #expect(VerificationDetailsSection.clusterOpensByDefault(partition(Fixtures.securePassRidingNote)))
    }

    @Test("The details draw no headed list of checks; the groups come before the list row")
    func noHeadedListOfChecks() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/VerificationDetailsSection.swift"), encoding: .utf8)
        #expect(!source.contains("header: \"Checks\""))
        #expect(!source.contains("layout: .bare"))
        let groups = try #require(source.range(of: "ForEach(Self.groups(partition)"))
        let row = try #require(source.range(of: "passCluster(partition)"))
        #expect(groups.lowerBound < row.lowerBound)
    }

    @Test("Page Modes: one line per mode with ranges; shown when mixed or any page fell back")
    func pageModeLines() {
        var modes = [PipelineMode](repeating: .searchableRedaction, count: 40)
        modes[12] = .secureRasterization
        modes[14] = .secureRasterization
        #expect(VerificationResultsView.pageModeLines(modes: modes) == [
            "Searchable · pages 1\u{2013}12, 14, and 16\u{2013}40",
            "Rasterized · pages 13 and 15",
        ])
        #expect(VerificationResultsView.pageModeLines(modes: [.searchableRedaction, .searchableRedaction, .secureRasterization])
                == ["Searchable · pages 1 and 2", "Rasterized · page 3"])
        #expect(VerificationResultsView.showsPageModes(report: Fixtures.searchableAttentionMixed))
        #expect(VerificationResultsView.showsPageModes(report: Fixtures.searchableAttentionFull))
        #expect(!VerificationResultsView.showsPageModes(report: Fixtures.secureAllPass))
    }

    @Test("A page link past the document's end is dropped; an unknown page count admits it")
    func pageInDocument() {
        #expect(VerificationResultsView.isPageInDocument(0, pageCount: 1))
        #expect(!VerificationResultsView.isPageInDocument(1, pageCount: 1))
        #expect(!VerificationResultsView.isPageInDocument(-1, pageCount: 3))
        #expect(VerificationResultsView.isPageInDocument(7, pageCount: 0))
    }

    // MARK: - Rows

    @Test("Chips: up to five on the collapsed row, else four and +n more; the full set opened")
    func chipCap() {
        #expect(LayerResultRow.collapsedChipPages([1, 2, 3, 4, 5]) == [1, 2, 3, 4, 5])
        #expect(LayerResultRow.collapsedChipPages(Array(1...12)) == [1, 2, 3, 4])
        #expect(LayerResultRow.moreChipsText(Array(1...12)) == "+8\u{00A0}more")
        #expect(LayerResultRow.moreChipsText([1, 2, 3]) == nil)
        let long = Fixtures.searchableAttentionLong.layers[2]
        let model = VerificationRowModel(layer: long, perPageModes: Fixtures.searchableAttentionLong.perPageModes,
                                         pagesOnChips: true)
        let items = LayerResultRow.groupedExpandedItems(model: model, layer: long, pagesOnChips: true)
        #expect(items.contains(.pageChips(Array(1...12))))
        #expect(!LayerResultRow.groupedExpandedItems(model: model, layer: long, pagesOnChips: false)
            .contains(where: { if case .pageChips = $0 { true } else { false } }))
    }

    @Test("With page links, the composed captions drop their page phrase; the term lead carries the remedy")
    func pagesOnChipsCaptions() {
        let mixed = Fixtures.searchableAttentionMixed.layers[2]
        let chips = VerificationRowModel(layer: mixed, perPageModes: [], pagesOnChips: true)
        #expect(chips.caption == "\u{201C}Delia\u{201D} is still readable.")
        #expect(chips.lead == ["It matches text you redacted. Use text\u{00A0}search to redact the rest."])
        let paged = VerificationRowModel(layer: mixed, perPageModes: [], pagesOnChips: false)
        #expect(paged.caption == "\u{201C}Delia\u{201D} is still readable on\u{00A0}page\u{00A0}2.")
        let sweep = Fixtures.secureScreenshot.layers.first { $0.layer == .detectionSweep }!
        #expect(VerificationRowModel(layer: sweep, perPageModes: [], pagesOnChips: true).caption
                == "5 possible items remain.")
        let recheck = Fixtures.searchableRecheckReview.layers[11]
        #expect(VerificationRowModel(layer: recheck, perPageModes: [], pagesOnChips: true).caption
                == "Your searches \u{201C}Delia\u{201D} and \u{201C}\\d{4}\u{201D} still have 3 matches.")
    }

    @Test("The grouped mark: the outcome's colour on a failure, a review or a warning; grey on a note, a could-not-verify and nothing to check")
    func markColours() {
        #expect(LayerResultRow.groupedMarkColor(.failed) == VerificationOutcome.failed.textColor)
        #expect(LayerResultRow.groupedMarkColor(.needsReview) == VerificationOutcome.needsReview.textColor)
        for outcome in [VerificationOutcome.note, .couldNotVerify, .nothingToCheck] {
            #expect(LayerResultRow.groupedMarkColor(outcome) == ResectaTokens.SemanticColor.supportText)
        }
    }

    @Test("An engine caption's trailing page keeps its noun; held text is left alone")
    func gluedPageTail() {
        #expect(LayerResultRow.gluedPageTail("Could not inspect page fonts on page 3")
                == "Could not inspect page fonts on\u{00A0}page\u{00A0}3")
        #expect(LayerResultRow.gluedPageTail("OCR could not be run on 1 page") == "OCR could not be run on 1 page")
        #expect(LayerResultRow.gluedPageTail("on\u{00A0}page\u{00A0}2.") == "on\u{00A0}page\u{00A0}2.")
    }

    // MARK: - The completion line

    @Test("The completion line names the duration; the ring states the count")
    func completionLine() {
        #expect(VerificationResultsView.completionLineText(report: Fixtures.secureAllPass) == "Completed in 4.1 seconds.")
        #expect(VerificationResultsView.completionLineText(report: Fixtures.searchableAttentionLong)
                == "Completed in 5 min 12 s.")
        #expect(VerificationResultsView.completionLineText(report: Fixtures.pageCountGate)
                == "Stopped at the Page Count check.")
        let quick = VerificationReport(
            layers: [LayerResult(name: "L", symbolName: "shield", status: .pass, shortDescription: "",
                                 detailDescription: "", pageReferences: nil, durationSeconds: 0)],
            overallStatus: .pass, durationSeconds: 0.04)
        #expect(VerificationResultsView.completionLineText(report: quick) == "Completed in under 0.1 seconds.")
    }
}
