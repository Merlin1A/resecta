import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The honesty invariants between the Verification Details list and the
// share-risk confirms: the confirms only ever widen; a row reads as gating
// Share exactly when Share asks first; a check that could not verify part
// of the output is never folded into a calm group; no title, word, header
// or confirm line carries the user's own text; every line that does is
// marked privacy-sensitive.

@Suite("Verification share honesty", .tags(.display))
@MainActor
struct VerificationShareHonestyTests {

    static func layer(_ status: VerificationStatus, _ identity: VerificationLayer?, cnv: Bool = false,
                      terms: [String]? = nil, lines: [SearchRecheckQueryLine]? = nil,
                      pages: [Int]? = nil) -> LayerResult {
        LayerResult(name: identity?.name ?? "Page Count Check", symbolName: "shield", status: status,
                    shortDescription: "Short line.", detailDescription: "Detail line.",
                    pageReferences: pages, durationSeconds: 0, reviewTermTexts: terms,
                    layer: identity, queryLines: lines, couldNotVerify: cnv)
    }

    /// A routine warning beside a skipped check: the shape the skipped-checks
    /// confirm used to let through.
    static let mixedRoutineWarnAndSkip = VerificationReport(
        layers: [layer(.pass, .textExtraction), layer(.warn("w"), .structureCheck),
                 layer(.skipped, .characterCount)],
        overallStatus: .warn("w"), durationSeconds: 0)

    /// The nine forged reports, the mixed shape, and the share-gate shapes.
    static var reports: [VerificationReport] {
        Array(VerificationDebugFixtures.all.values) + [
            mixedRoutineWarnAndSkip,
            // A routine warning alone · a could-not-verify warning alone ·
            // skipped checks alone · a needs review · a pass.
            VerificationReport(layers: [layer(.pass, .ocrCheck), layer(.warn("w"), .metadataCheck)],
                               overallStatus: .warn("w"), durationSeconds: 0),
            VerificationReport(layers: [layer(.pass, .ocrCheck), layer(.warn("w"), .ocrCheck, cnv: true)],
                               overallStatus: .warn("w"), durationSeconds: 0),
            VerificationReport(layers: [layer(.skipped, .characterCount), layer(.skipped, .characterLineage)],
                               overallStatus: .warn("w"), durationSeconds: 0),
            VerificationReport(layers: [layer(.attention("a"), .binaryStringSearch, terms: ["x"])],
                               overallStatus: .attention("a"), durationSeconds: 0),
            VerificationReport(layers: [layer(.pass, .ocrCheck)], overallStatus: .pass, durationSeconds: 0),
        ]
    }

    // MARK: - (i) The confirms only widen

    @Test("Every report the earlier predicates confirmed still confirms")
    func confirmsOnlyWiden() {
        for report in Self.reports {
            // The three predicates as they read before this change, copied
            // as the reference.
            let failBefore = (report.overallStatus.isFail || report.overallStatus.isAttention) && !false
            let skippedBefore = report.overallStatus.isSkipped && !false
            let incompleteBefore: Bool = {
                guard report.overallStatus.isWarn else { return false }
                let warnCount = report.layers.filter(\.status.isWarn).count
                let skippedCount = report.layers.filter(\.status.isSkipped).count
                if warnCount == 0 && skippedCount > 0 { return true }
                return report.layers.contains(where: CouldNotVerifyWarn.matches)
            }()
            #expect(DocumentEditorView.shareNeedsFailConfirm(report: report, acknowledged: false) == failBefore)
            #expect(DocumentEditorView.shareNeedsSkippedConfirm(report: report, acknowledged: false) == skippedBefore)
            if incompleteBefore {
                #expect(DocumentEditorView.shareNeedsIncompleteWarnConfirm(report: report, acknowledged: false))
            }
        }
    }

    // MARK: - (ii) A gating row ⇔ a confirm

    @Test("A row reads as gating Share exactly when one of the three confirms fires")
    func gateEquivalence() {
        for report in Self.reports where !report.layers.isEmpty {
            let gated = report.layers.contains {
                VerificationRowModel.outcome(for: $0, perPageModes: report.perPageModes).gatesSharing
            }
            let confirms = DocumentEditorView.shareNeedsFailConfirm(report: report, acknowledged: false)
                || DocumentEditorView.shareNeedsSkippedConfirm(report: report, acknowledged: false)
                || DocumentEditorView.shareNeedsIncompleteWarnConfirm(report: report, acknowledged: false)
            #expect(gated == confirms, "\(VerificationResultsView.detailsSummaryText(for: report))")
        }
    }

    @Test("A routine warning beside a skipped check asks before sharing")
    func mixedRoutineWarnAndSkipConfirms() {
        #expect(DocumentEditorView.shareNeedsIncompleteWarnConfirm(
            report: Self.mixedRoutineWarnAndSkip, acknowledged: false))
        #expect(!DocumentEditorView.shareNeedsIncompleteWarnConfirm(
            report: Self.mixedRoutineWarnAndSkip, acknowledged: true))
    }

    // MARK: - (iii) Could not verify stays visible

    @Test("Every could-not-verify or skipped check sits in Could not verify, and the summary names it")
    func couldNotVerifyStaysVisible() {
        for report in Self.reports {
            let partition = VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
            let incomplete = report.layers.indices.filter {
                CouldNotVerifyWarn.matches(report.layers[$0]) || report.layers[$0].status.isSkipped
            }
            #expect(partition.couldNotVerify == incomplete)
            #expect(Set(incomplete).isDisjoint(with: partition.cluster + partition.notes + partition.nothingToCheck))
            #expect(VerificationResultsView.detailsSummaryText(for: report).contains("could not verify")
                    == !incomplete.isEmpty)
        }
    }

    @Test("The Could not verify group renders above the notes and the pass cluster")
    func couldNotVerifyGroupRendersAboveTheCluster() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/VerificationDetailsSection.swift"), encoding: .utf8)
        let order = ["ForEach(Self.groups(partition)", "passCluster(partition)"].map { source.range(of: $0)?.lowerBound }
        #expect(!order.contains(nil))
        #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted())
        let layers = [Self.layer(.fail("f"), .textExtraction), Self.layer(.skipped, .characterCount),
                      Self.layer(.info("i"), .detectionSweep, lines: [SearchRecheckQueryLine(
                          label: "Scan (17 detectors)", foundCount: 0, foundHitCap: false, appliedCount: 0,
                          remainingCount: 2, route: .ocr)], pages: [0]),
                      Self.layer(.notApplicable("i"), .searchRecheck), Self.layer(.pass, .structureCheck)]
        let partition = VerificationLayerPartition(layers: layers, perPageModes: [])
        #expect(VerificationDetailsSection.groups(partition).map(\.header)
                == ["Findings", "Could not verify", "Notes", "Nothing to check"])
    }

    // MARK: - (iv) Content-free

    static let sentinel = "QZSENTINEL"

    @Test("No title, word, header, cluster title or confirm line carries the user's text")
    func displayStringsAreContentFree() {
        let typed = SearchRecheckQueryLine(
            label: "\u{201C}\(Self.sentinel)\u{201D}", foundCount: 2, foundHitCap: false, appliedCount: 1,
            remainingCount: 1, route: .ocr,
            perTerm: [.init(term: Self.sentinel, found: 2, applied: 1, remaining: 1)])
        let sweep = SearchRecheckQueryLine(
            label: "Scan (17 detectors)", foundCount: 0, foundHitCap: false, appliedCount: 0,
            remainingCount: 2, route: .ocr, perTerm: [.init(term: Self.sentinel, found: nil, applied: nil, remaining: 2)])
        let layers = [
            Self.layer(.attention("a"), .searchRecheck, terms: [Self.sentinel], lines: [typed], pages: [0]),
            Self.layer(.attention("a"), .binaryStringSearch, terms: [Self.sentinel], pages: [1]),
            Self.layer(.info("i"), .detectionSweep, lines: [sweep], pages: [0, 1]),
            Self.layer(.warn("w"), .ocrCheck, cnv: true, terms: [Self.sentinel]),
            Self.layer(.skipped, .characterCount),
            Self.layer(.pass, .structureCheck),
        ]
        let report = VerificationReport(layers: layers, overallStatus: .attention("a"), durationSeconds: 0)
        let partition = VerificationLayerPartition(layers: layers, perPageModes: [])
        var shown = [VerificationResultsView.detailsSummaryText(for: report), partition.clusterTitle,
                     "Findings", "Could not verify", "Notes", "Nothing to check"]
        shown += DocumentEditorView.atRiskItemLines(report: report)
        shown += DocumentEditorView.couldNotVerifyItemLines(report: report)
        for layer in layers {
            let model = VerificationRowModel(layer: layer, perPageModes: [])
            shown += [model.title, model.outcome.word, model.explainer ?? ""]
            if let caption = model.caption {
                if caption.contains(Self.sentinel) {
                    #expect(model.captionIsPrivacySensitive, "\(caption)")
                } else {
                    shown.append(caption)
                }
            }
        }
        for line in shown {
            #expect(!line.contains(Self.sentinel), "\(line)")
        }
    }

    // MARK: - (v) Matched or typed text is privacy-sensitive

    @Test("Source pin: the row marks its caption and both query-line sites privacy-sensitive")
    func rowMarksMatchedTextPrivacySensitive() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/LayerResultRow.swift"), encoding: .utf8)
        #expect(source.components(separatedBy: ".privacySensitive(model.captionIsPrivacySensitive)").count - 1 == 1)
        #expect(source.components(separatedBy: ".privacySensitive(Self.queryLinesArePrivacySensitive)").count - 1 == 2)
        #expect(LayerResultRow.queryLinesArePrivacySensitive)
    }
}
