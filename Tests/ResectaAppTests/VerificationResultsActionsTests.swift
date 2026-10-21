import Testing
import Foundation
import SwiftUI
@testable import ResectaApp
@testable import RedactionEngine

// The grouped results page's rules, read without a host: which capsule
// leads, how Share is drawn, which action rows show and in what order, when
// Share speaks its confirm hint (the live confirm predicates with their
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

    // MARK: - The Share hint (moved here with Share)

    static func willConfirm(_ report: VerificationReport, canExport: Bool = true,
                            fail: Bool = false, skipped: Bool = false, incomplete: Bool = false) -> Bool {
        Actions.shareWillConfirm(report: report, canExport: canExport, failAcknowledged: fail,
                                 skippedAcknowledged: skipped, incompleteWarnAcknowledged: incomplete)
    }

    @Test("The hint text is spoken only — one sentence, no promise")
    func hintText() {
        #expect(Actions.shareConfirmHint == "Asks you to confirm before sharing.")
    }

    @Test("The hint follows the confirm families: FAIL, ATTENTION, SKIPPED, the incomplete WARN")
    func hintWhereAConfirmOpens() {
        #expect(Self.willConfirm(Fixtures.secureFail))
        #expect(Self.willConfirm(Fixtures.searchableAttentionMixed))
        #expect(Self.willConfirm(Fixtures.secureSkippedOff))
        #expect(Self.willConfirm(Fixtures.searchableSkipInduced))
        #expect(!Self.willConfirm(Fixtures.secureAllPass))
        #expect(!Self.willConfirm(Fixtures.secureWarningOnly))
        #expect(!Self.willConfirm(Fixtures.securePassRidingNote))
    }

    @Test("No hint once the family is acknowledged — after a completed share — or when Share is disabled")
    func noHintWhenNoConfirmOpens() {
        #expect(!Self.willConfirm(Fixtures.secureFail, fail: true))
        #expect(!Self.willConfirm(Fixtures.searchableAttentionMixed, fail: true))
        #expect(!Self.willConfirm(Fixtures.secureSkippedOff, skipped: true))
        #expect(!Self.willConfirm(Fixtures.searchableSkipInduced, incomplete: true))
        for report in [Fixtures.secureFail, Fixtures.secureSkippedOff, Fixtures.searchableSkipInduced] {
            #expect(!Self.willConfirm(report, canExport: false))
        }
        for (_, report) in Fixtures.all {
            let predicates = DocumentEditorView.shareNeedsFailConfirm(report: report, acknowledged: false)
                || DocumentEditorView.shareNeedsSkippedConfirm(report: report, acknowledged: false)
                || DocumentEditorView.shareNeedsIncompleteWarnConfirm(report: report, acknowledged: false)
            #expect(Self.willConfirm(report) == predicates)
        }
    }

    // MARK: - The count ring

    @Test("The ring: P of T with T every check, the verdict's tone; SKIPPED draws the slot")
    func ringContent() {
        #expect(VerificationMasthead.ringContent(report: Fixtures.searchableAllRasterized)
                == .count(passed: 9, total: 12, tone: .pass))
        #expect(VerificationMasthead.ringContent(report: Fixtures.searchableAttentionMixed)
                == .count(passed: 7, total: 12, tone: .attention))
        #expect(VerificationMasthead.ringContent(report: Fixtures.secureWarningOnly)
                == .count(passed: 6, total: 7, tone: .warn))
        #expect(VerificationMasthead.ringContent(report: Fixtures.pageCountGate)
                == .count(passed: 0, total: 1, tone: .fail))
        #expect(VerificationMasthead.ringContent(report: Fixtures.secureAllFailed)
                == .count(passed: 0, total: 7, tone: .fail))
        #expect(VerificationMasthead.ringContent(report: Fixtures.secureSkippedOff) == .skipped)
        #expect(VerificationMasthead.ringContent(report: Self.report(.info("i"))) == .count(passed: 0, total: 0, tone: .pass))
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

    @Test("A wholly clean run is the Checks list; the cluster opens by default only for riding notes with nothing above")
    func clusterRules() {
        func partition(_ report: VerificationReport) -> VerificationLayerPartition {
            VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
        }
        #expect(VerificationDetailsSection.isEveryCheckPassed(partition(Fixtures.secureAllPass)))
        #expect(!VerificationDetailsSection.isEveryCheckPassed(partition(Fixtures.searchableAllRasterized)))
        #expect(VerificationDetailsSection.clusterOpensByDefault(partition(Fixtures.securePassRidingNote)))
        #expect(!VerificationDetailsSection.clusterOpensByDefault(partition(Fixtures.secureScreenshot)))
        #expect(!VerificationDetailsSection.clusterOpensByDefault(partition(Fixtures.searchableAllRasterized)))
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
        let sweep = Fixtures.secureScreenshot.layers.last!
        #expect(VerificationRowModel(layer: sweep, perPageModes: [], pagesOnChips: true).caption
                == "5 possible items remain.")
        let recheck = Fixtures.searchableRecheckReview.layers[10]
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
