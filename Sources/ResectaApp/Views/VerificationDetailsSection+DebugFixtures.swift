#if DEBUG
import SwiftUI
import RedactionEngine

// Forged verification reports for the Verification Details list — every
// state the list can show, without a fixture run: the `#Preview`s below and
// the `--seedVerifiedReport=<name>` launch hook (`ResectaApp`) read them.
// Built through the engine's public initialisers with each row's identity
// set; the engine sentences are literals copied from the engine's
// templates. They can drift from the engine's own; nothing compares them.

enum VerificationDebugFixtures {
    /// Every fixture by its launch-hook name.
    static let all: [String: VerificationReport] = [
        "secureAllPass": secureAllPass,
        "secureScreenshot": secureScreenshot,
        "secureScanOnly": secureScanOnly,
        "searchableAllPass": searchableAllPass,
        "searchableAllRasterized": searchableAllRasterized,
        "searchableAttentionMixed": searchableAttentionMixed,
        "secureFail": secureFail,
        "searchableSkipInduced": searchableSkipInduced,
        "pageCountGate": pageCountGate,
        "secureWarningOnly": secureWarningOnly,
        "secureSkippedOff": secureSkippedOff,
        "searchableSkippedCancelled": searchableSkippedCancelled,
        "searchableRecheckReview": searchableRecheckReview,
        "searchableAttentionFull": searchableAttentionFull,
        "searchableAttentionLong": searchableAttentionLong,
        "secureAllFailed": secureAllFailed,
        "securePassRidingNote": securePassRidingNote,
    ]

    /// The run each fixture stands for, as the results screen reads it
    /// beside the report (the mode for the SKIPPED sentences, the run
    /// facts): page modes, fallback reasons, OCR-skipped pages.
    static func runInputs(for name: String) -> (modes: [PipelineMode],
                                                 reasons: [TextLayerDetector.FallbackReason?],
                                                 ocrSkippedPages: Set<Int>)? {
        switch name {
        case "secureSkippedOff": return (secure, [], [])
        case "searchableSkippedCancelled": return (searchable, [], [])
        case "searchableAttentionFull": return (mixed, mixedReasons, [2])
        default:
            guard let report = all[name], !report.perPageModes.isEmpty else { return nil }
            return (report.perPageModes, report.perPageFallbackReasons, [])
        }
    }

    // MARK: - The rows

    private static func row(
        _ identity: VerificationLayer, _ status: VerificationStatus = .pass,
        short: String = "No issues found.", detail: String = "", pages: [Int]? = nil,
        terms: [String]? = nil, lines: [SearchRecheckQueryLine]? = nil, cnv: Bool = false,
        seconds: Double = 0.04
    ) -> LayerResult {
        LayerResult(name: identity.name, symbolName: identity.symbolName, status: status,
                    shortDescription: short, detailDescription: detail, pageReferences: pages,
                    durationSeconds: seconds, reviewTermTexts: terms, layer: identity,
                    queryLines: lines, couldNotVerify: cnv)
    }

    private static let ocrRoute = "Text was read by OCR from the rendered pages."
    /// A searchable output: a text layer over the page image, read on both legs.
    private static let bothLegsRoute = "Text was read from the output's text layer and by OCR from the rendered pages."

    private static let recheckPass = row(
        .searchRecheck,
        short: "Re-ran 1 search on the output — no remaining matches in the text the app can read.",
        detail: "Search Re-check re-ran each applied search on the output through the search engine. \(ocrRoute)",
        lines: [SearchRecheckQueryLine(label: "\u{201C}Delia\u{201D}", foundCount: 2, foundHitCap: false,
                                       appliedCount: 2, remainingCount: 0, route: .ocr)],
        seconds: 0.6)

    private static let recheckPassBothLegs = row(
        .searchRecheck,
        short: "Re-ran 1 search on the output — no remaining matches in the text the app can read.",
        detail: "Search Re-check re-ran each applied search on the output through the search engine. \(bothLegsRoute)",
        lines: [SearchRecheckQueryLine(label: "\u{201C}Delia\u{201D}", foundCount: 2, foundHitCap: false,
                                       appliedCount: 2, remainingCount: 0, route: .mixed(textPages: 3, ocrPages: 3))],
        seconds: 0.6)

    private static let recheckIdle = row(
        .searchRecheck, .notApplicable("No searches were applied — the search re-check did not run."),
        short: "No searches were applied — the search re-check did not run.")

    private static let sweepPass = row(
        .detectionSweep,
        short: "Ran the detectors on the output — nothing further reported.",
        detail: "Detection Sweep ran every detector on the output. \(ocrRoute) Names and addresses are not swept.",
        lines: [SearchRecheckQueryLine(label: "Scan (17 detectors)", foundCount: 0, foundHitCap: false,
                                       appliedCount: 0, remainingCount: 0, route: .ocr)],
        seconds: 1.8)

    private static let sweepPassBothLegs = row(
        .detectionSweep,
        short: "Ran the detectors on the output — nothing further reported.",
        detail: "Detection Sweep ran every detector on the output. \(bothLegsRoute) Names and addresses are not swept.",
        lines: [SearchRecheckQueryLine(label: "Scan (17 detectors)", foundCount: 0, foundHitCap: false,
                                       appliedCount: 0, remainingCount: 0, route: .mixed(textPages: 3, ocrPages: 3))],
        seconds: 1.8)

    private static let sweepNoteMessage =
        "Ran the detectors on the output — 5 possible items remain on 2 pages: 1, 3. Open Scan to review."

    /// The screenshot's sweep: five possible items on pages 1 and 3.
    private static let sweepNote = row(
        .detectionSweep, .info(sweepNoteMessage), short: sweepNoteMessage,
        detail: "Detection Sweep ran every detector on the output. \(ocrRoute) Names and addresses are not swept. "
            + "5 possible items remain on 2 pages: 1, 3.",
        pages: [0, 2],
        lines: [SearchRecheckQueryLine(
            label: "Scan (17 detectors)", foundCount: 0, foundHitCap: false, appliedCount: 0,
            remainingCount: 5, route: .ocr,
            perTerm: [.init(term: "Email", found: nil, applied: nil, remaining: 2),
                      .init(term: "Phone", found: nil, applied: nil, remaining: 3)])],
        seconds: 2.3)

    private static let metadataPass = row(
        .metadataCheck,
        detail: "Producer and timestamps carry the writer's fixed values; no file-specific metadata is present.")

    private static let coreSecure: [VerificationLayer] = [
        .textExtraction, .ocrCheck, .binaryStringSearch, .structureCheck, .metadataCheck,
    ]
    private static func noTextLayerRow(_ identity: VerificationLayer) -> LayerResult {
        let message = "No page kept a text layer — every page was rasterized, so this check had nothing to check."
        return row(identity, .notApplicable(message), short: message)
    }

    private static let coreSearchable: [VerificationLayer] = [
        .textExtraction, .ocrCheck, .binaryStringSearch, .structureCheck, .metadataCheck,
        .spatialVerification, .characterCount, .fontVerification, .characterLineage, .operatorReExtraction,
    ]

    /// The run's rows in engine order, each passing unless `overrides` names it.
    private static func rows(_ core: [VerificationLayer], recheck: LayerResult, sweep: LayerResult,
                             _ overrides: [VerificationLayer: LayerResult] = [:]) -> [LayerResult] {
        core.map { overrides[$0] ?? ($0 == .metadataCheck ? metadataPass : row($0)) }
            + [overrides[.searchRecheck] ?? recheck, overrides[.detectionSweep] ?? sweep]
    }

    private static let secure: [PipelineMode] = [.secureRasterization, .secureRasterization, .secureRasterization]
    private static let searchable: [PipelineMode] = [.searchableRedaction, .searchableRedaction, .searchableRedaction]
    private static let mixed: [PipelineMode] = [.searchableRedaction, .searchableRedaction, .secureRasterization]
    private static let mixedReasons: [TextLayerDetector.FallbackReason?] = [nil, nil, .verticalText]

    // MARK: - The nine reports

    /// Secure, a typed search applied, the sweep reported nothing further.
    static let secureAllPass = VerificationReport(
        layers: rows(coreSecure, recheck: recheckPass, sweep: sweepPass),
        overallStatus: .pass, durationSeconds: 4.1, perPageModes: secure)

    /// The screenshot of record: the sweep's note with five possible items.
    static let secureScreenshot = VerificationReport(
        layers: rows(coreSecure, recheck: recheckPass, sweep: sweepNote),
        overallStatus: .pass, durationSeconds: 4.6, perPageModes: secure)

    /// A scan-only run: no typed search, so the re-check had nothing to check.
    static let secureScanOnly = VerificationReport(
        layers: rows(coreSecure, recheck: recheckIdle, sweep: sweepNote),
        overallStatus: .pass, durationSeconds: 4.0, perPageModes: secure)

    static let searchableAllPass = VerificationReport(
        layers: rows(coreSearchable, recheck: recheckPassBothLegs, sweep: sweepPassBothLegs),
        overallStatus: .pass, durationSeconds: 6.2, perPageModes: searchable)

    /// Searchable, every page rasterized: the three text-layer checks read
    /// no page.
    static let searchableAllRasterized = VerificationReport(
        layers: rows(coreSearchable, recheck: recheckPass, sweep: sweepPass, [
            .characterCount: noTextLayerRow(.characterCount),
            .fontVerification: noTextLayerRow(.fontVerification),
            .characterLineage: noTextLayerRow(.characterLineage),
        ]),
        overallStatus: .pass, durationSeconds: 5.1, perPageModes: secure)

    /// Needs review · could not verify · a warning · an idle re-check.
    static let searchableAttentionMixed = VerificationReport(
        layers: rows(coreSearchable, recheck: recheckIdle, sweep: sweepPass, [
            .binaryStringSearch: row(
                .binaryStringSearch, .attention(bytesAttention),
                short: bytesAttention, pages: [1], terms: ["Delia"]),
            .ocrCheck: row(.ocrCheck, .warn("OCR could not be run on 1 page"),
                           short: "OCR could not be run on 1 page", pages: [2], cnv: true, seconds: 1.2),
            .spatialVerification: row(.spatialVerification, .warn(graze), short: graze, pages: [1]),
            .fontVerification: row(.fontVerification, .warn("Could not inspect page fonts on page 3"),
                                   short: "Could not inspect page fonts on page 3", pages: [2], cnv: true),
        ]),
        overallStatus: .attention(bytesAttention),
        durationSeconds: 7.4, perPageModes: mixed)

    private static let bytesAttention = "Text matching your redactions is still readable on page 2 (1 instance)"
    private static let graze =
        "A character touches the edge of a redacted area on page 2. Its content is outside the redacted area."

    static let secureFail = VerificationReport(
        layers: rows(coreSecure, recheck: recheckPass, sweep: sweepPass, [
            .textExtraction: row(.textExtraction, .fail("Selectable text found on page 1"),
                                 short: "Selectable text found on page 1", pages: [0]),
        ]),
        overallStatus: .fail("Selectable text found on page 1"), durationSeconds: 3.9, perPageModes: secure)

    /// A verify-only run without the redaction run's per-page data: two
    /// checks skipped beside one note.
    static let searchableSkipInduced = VerificationReport(
        layers: rows(coreSearchable, recheck: recheckPass, sweep: sweepPass, [
            .characterCount: row(.characterCount, .skipped, short: "Skipped.",
                                 detail: "Character Count was not applicable for this pipeline mode."),
            .characterLineage: row(.characterLineage, .skipped, short: "Skipped.",
                                   detail: "Character Lineage was not applicable for this pipeline mode."),
            .ocrCheck: row(.ocrCheck, .info(fillArtifact), short: fillArtifact, pages: [0]),
        ]),
        overallStatus: .warn("Some verification checks were skipped — results may be incomplete"),
        durationSeconds: 5.5, perPageModes: searchable)

    private static let fillArtifact =
        "OCR detected likely fill artifacts within a redacted region on page 1 — no readable text recovered"

    /// The page-count gate, built by the engine's own factory.
    static let pageCountGate = VerificationOrchestrator.pageCountMismatchReport(
        sourcePageCount: 3, outputPageCount: 2, perPageModes: [], perPageFallbackReasons: [])!

    // MARK: - The forged reports beyond the nine

    /// WARN from a routine warning only: the one route to `Completed with
    /// Warnings`.
    static let secureWarningOnly = VerificationReport(
        layers: rows(coreSecure, recheck: recheckPass, sweep: sweepPass, [
            .structureCheck: row(.structureCheck, .warn("Structural findings: URI"),
                                 short: "Structural findings: URI"),
        ]),
        overallStatus: .warn("Structural findings: URI"), durationSeconds: 4.3, perPageModes: secure)

    /// SKIPPED: verification off in Settings, on a Secure run.
    static let secureSkippedOff = VerificationReport.skipped(reason: .autoVerifyOff)

    /// SKIPPED: the run was cancelled, on a Searchable run.
    static let searchableSkippedCancelled = VerificationReport.skipped(reason: .cancelled)

    /// Needs review from the Search Re-check alone: two searches still
    /// match, a page could not be checked.
    static let searchableRecheckReview: VerificationReport = {
        let message = "Re-ran 2 searches — 3 matches remain on pages 1, 2, "
            + "1 page could not be checked: 4 (too large to scan for text)"
        let recheck = row(
            .searchRecheck, .attention(message), short: message,
            detail: "Search Re-check re-ran each applied search on the output through the search engine. "
                + "Text was read from the output's text layer. 3 matches remain on pages 1, 2. "
                + "1 page could not be checked: 4 (too large to scan for text).",
            pages: [0, 1], terms: ["Delia", "\\d{4}"],
            lines: [
                SearchRecheckQueryLine(label: "\u{201C}Delia\u{201D}", foundCount: 4, foundHitCap: false,
                                       appliedCount: 2, remainingCount: 2, route: .textLayer),
                SearchRecheckQueryLine(label: "\u{201C}\\d{4}\u{201D}", foundCount: 3, foundHitCap: false,
                                       appliedCount: 2, remainingCount: 1, route: .textLayer),
            ],
            seconds: 0.8)
        return VerificationReport(
            layers: rows(coreSearchable, recheck: recheck, sweep: sweepPass),
            overallStatus: .attention(message), durationSeconds: 6.8,
            perPageModes: [.searchableRedaction, .searchableRedaction, .searchableRedaction, .searchableRedaction])
    }()

    /// The mixed report, fuller: two terms on two pages, the content
    /// stream search stopping at page 2 of 3, a fallback page.
    static let searchableAttentionFull: VerificationReport = {
        let twoTerms = "Text matching your redactions is still readable on pages 2, 3 (2 instances)"
        let inContent = "Text matching your redactions is still readable in page 2 content"
        return VerificationReport(
            layers: rows(coreSearchable, recheck: recheckIdle, sweep: sweepPass, [
                .binaryStringSearch: row(.binaryStringSearch, .attention(twoTerms), short: twoTerms,
                                         pages: [1, 2], terms: ["Delia", "Marco"]),
                .operatorReExtraction: row(.operatorReExtraction, .attention(inContent), short: inContent,
                                           pages: [1], terms: ["Delia"]),
                .ocrCheck: row(.ocrCheck, .warn("OCR could not be run on 1 page"),
                               short: "OCR could not be run on 1 page", pages: [2], cnv: true, seconds: 1.2),
                .spatialVerification: row(.spatialVerification, .warn(graze), short: graze, pages: [1]),
                .fontVerification: row(.fontVerification, .warn("Could not inspect page fonts on page 3"),
                                       short: "Could not inspect page fonts on page 3", pages: [2], cnv: true),
            ]),
            overallStatus: .attention(twoTerms), durationSeconds: 7.4,
            perPageModes: mixed, perPageFallbackReasons: mixedReasons)
    }()

    /// Long terms (one repeated with other spacing and case), a row on
    /// twelve pages, a fourteen-page run, minutes.
    static let searchableAttentionLong: VerificationReport = {
        var modes = Array(repeating: PipelineMode.searchableRedaction, count: 14)
        modes[12] = .secureRasterization
        var reasons = [TextLayerDetector.FallbackReason?](repeating: nil, count: 14)
        reasons[12] = .verticalText
        let ocrMessage = "Text matching your redactions is still readable on page 3 — read by OCR outside every redacted region"
        let bytesMessage = "Text matching your redactions is still readable on pages 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 (14 instances)"
        return VerificationReport(
            layers: rows(coreSearchable, recheck: recheckIdle, sweep: sweepPass, [
                .ocrCheck: row(.ocrCheck, .attention(ocrMessage), short: ocrMessage, pages: [2],
                               terms: ["Northwest Regional Office"], seconds: 296.2),
                .binaryStringSearch: row(.binaryStringSearch, .attention(bytesMessage), short: bytesMessage,
                                         pages: Array(1...12),
                                         terms: ["Margaret  Thompson-Rivera", "O'Brien-Castellanos Ltd",
                                                 "margaret thompson-rivera"]),
                .spatialVerification: row(.spatialVerification, .warn(graze), short: graze, pages: [1]),
                .fontVerification: row(.fontVerification, .warn("Could not inspect page fonts on page 3"),
                                       short: "Could not inspect page fonts on page 3", pages: [2], cnv: true),
            ]),
            overallStatus: .attention(ocrMessage), durationSeconds: 312.4,
            perPageModes: modes, perPageFallbackReasons: reasons)
    }()

    /// Nothing passed: five failures, the re-check needing review, the
    /// sweep unable to check.
    static let secureAllFailed: VerificationReport = {
        let recheckMessage = "Re-ran 1 search — 2 matches remain on page 1"
        let sweepMessage = "Ran the detectors on the output; 3 pages could not be checked: 1, 2, 3"
        return VerificationReport(
            layers: rows(coreSecure,
                recheck: row(.searchRecheck, .attention(recheckMessage), short: recheckMessage, pages: [0],
                             terms: ["Delia"],
                             lines: [SearchRecheckQueryLine(label: "\u{201C}Delia\u{201D}", foundCount: 4,
                                                            foundHitCap: false, appliedCount: 2,
                                                            remainingCount: 2, route: .ocr)],
                             seconds: 0.7),
                sweep: row(.detectionSweep, .warn(sweepMessage), short: sweepMessage, pages: [0, 1, 2],
                           lines: [SearchRecheckQueryLine(label: "Scan (17 detectors)", foundCount: 0,
                                                          foundHitCap: false, appliedCount: 0,
                                                          remainingCount: 0, route: .mixed(textPages: 0, ocrPages: 0))],
                           cnv: true, seconds: 1.9), [
                .textExtraction: row(.textExtraction, .fail("Selectable text found on page 1"),
                                     short: "Selectable text found on page 1", pages: [0]),
                .ocrCheck: row(.ocrCheck, .fail("Readable text detected within a redacted region on page 1"),
                               short: "Readable text detected within a redacted region on page 1", pages: [0]),
                .binaryStringSearch: row(.binaryStringSearch,
                                         .fail("Sensitive string found in output PDF structural data (2 matches)"),
                                         short: "Sensitive string found in output PDF structural data (2 matches)"),
                .structureCheck: row(.structureCheck,
                                     .fail("Multiple %%EOF markers (2) — incremental update may contain original content"),
                                     short: "Multiple %%EOF markers (2) — incremental update may contain original content"),
                .metadataCheck: row(.metadataCheck, .fail("Metadata key /Author present"),
                                    short: "Metadata key /Author present"),
            ]),
            overallStatus: .fail("Selectable text found on page 1"), durationSeconds: 4.4, perPageModes: secure)
    }()

    /// PASS with one note riding in the pass cluster — a twelve-check
    /// Searchable run (Character Count reads only Searchable pages).
    static let securePassRidingNote = VerificationReport(
        layers: rows(coreSearchable, recheck: recheckPass, sweep: sweepPass, [
            .characterCount: row(.characterCount, .info("3 character(s) near redaction boundaries."),
                                 short: "3 character(s) near redaction boundaries."),
        ]),
        overallStatus: .pass, durationSeconds: 6.0, perPageModes: searchable)

    // MARK: - Previews

    /// The whole results screen on a fixture, as a seeded launch shows it
    /// with an output (Share live, page links on).
    @MainActor
    static func section(_ report: VerificationReport) -> some View {
        VerificationResultsView(
            report: report, canExport: true, outputExists: true, isVerificationStale: false,
            previewAvailable: true, onExport: {}, onRunVerification: {})
            .environment(DocumentState())
            .environment(RedactionState())
    }
}

#Preview("Secure, all pass") { VerificationDebugFixtures.section(VerificationDebugFixtures.secureAllPass) }
#Preview("Secure, the screenshot") { VerificationDebugFixtures.section(VerificationDebugFixtures.secureScreenshot) }
#Preview("Secure, scan only") { VerificationDebugFixtures.section(VerificationDebugFixtures.secureScanOnly) }
#Preview("Searchable, all pass") { VerificationDebugFixtures.section(VerificationDebugFixtures.searchableAllPass) }
#Preview("Searchable, all rasterized") {
    VerificationDebugFixtures.section(VerificationDebugFixtures.searchableAllRasterized)
}
#Preview("Searchable, attention mixed") {
    VerificationDebugFixtures.section(VerificationDebugFixtures.searchableAttentionMixed)
}
#Preview("Secure, fail") { VerificationDebugFixtures.section(VerificationDebugFixtures.secureFail) }
#Preview("Searchable, skip-induced") {
    VerificationDebugFixtures.section(VerificationDebugFixtures.searchableSkipInduced)
}
#Preview("Page-count gate") { VerificationDebugFixtures.section(VerificationDebugFixtures.pageCountGate) }
#Preview("Dark, attention mixed") {
    VerificationDebugFixtures.section(VerificationDebugFixtures.searchableAttentionMixed)
        .preferredColorScheme(.dark)
}
#Preview("Accessibility 3, attention mixed") {
    VerificationDebugFixtures.section(VerificationDebugFixtures.searchableAttentionMixed)
        .dynamicTypeSize(.accessibility3)
}
#Preview("Progress rows") {
    VStack(spacing: ResectaTokens.Spacing.md) {
        ForEach(Array(VerificationDebugFixtures.searchableAttentionMixed.layers.prefix(6).enumerated()),
                id: \.offset) { index, layer in
            LayerResultRow(layer: layer, layerIndex: index + 1, isExpanded: false, onTap: {},
                           useIntermediateColors: true, isExpandable: false)
        }
    }
    .padding(ResectaTokens.Spacing.md)
}
#endif
