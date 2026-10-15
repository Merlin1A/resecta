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
    ]

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

    private static let recheckPass = row(
        .searchRecheck,
        short: "Re-ran 1 search on the output — no remaining matches in the text the app can read.",
        detail: "Search Re-check re-ran each applied search on the output through the search engine. \(ocrRoute)",
        lines: [SearchRecheckQueryLine(label: "\u{201C}Delia\u{201D}", foundCount: 2, foundHitCap: false,
                                       appliedCount: 2, remainingCount: 0, route: .ocr)],
        seconds: 0.6)

    private static let recheckIdle = row(
        .searchRecheck, .info("No searches were applied — the search re-check did not run."),
        short: "No searches were applied — the search re-check did not run.")

    private static let sweepPass = row(
        .detectionSweep,
        short: "Ran the detectors on the output — nothing further reported.",
        detail: "Detection Sweep ran every detector on the output. \(ocrRoute) Names and addresses are not swept.",
        lines: [SearchRecheckQueryLine(label: "Scan (17 detectors)", foundCount: 0, foundHitCap: false,
                                       appliedCount: 0, remainingCount: 0, route: .ocr)],
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
        layers: rows(coreSearchable, recheck: recheckPass, sweep: sweepPass),
        overallStatus: .pass, durationSeconds: 6.2, perPageModes: searchable)

    /// Searchable, every page rasterized: the three text-layer checks read
    /// no page.
    static let searchableAllRasterized = VerificationReport(
        layers: rows(coreSearchable, recheck: recheckPass, sweep: sweepPass),
        overallStatus: .pass, durationSeconds: 5.1, perPageModes: secure)

    /// Needs review · could not verify · a warning · an idle re-check.
    static let searchableAttentionMixed = VerificationReport(
        layers: rows(coreSearchable, recheck: recheckIdle, sweep: sweepPass, [
            .binaryStringSearch: row(
                .binaryStringSearch, .attention("Text matching your redactions is still readable on 1 page: 2 (1 instance)"),
                short: "Text matching your redactions is still readable on 1 page: 2 (1 instance)",
                pages: [1], terms: ["Delia"]),
            .ocrCheck: row(.ocrCheck, .warn("OCR could not be run on 1 page"),
                           short: "OCR could not be run on 1 page", pages: [2], cnv: true, seconds: 1.2),
            .spatialVerification: row(
                .spatialVerification, .warn("A character touches the edge of a redacted area on page 2"),
                short: "A character touches the edge of a redacted area on page 2", pages: [1]),
            .fontVerification: row(.fontVerification, .warn("Could not inspect page fonts on page 3"),
                                   short: "Could not inspect page fonts on page 3", pages: [2], cnv: true),
        ]),
        overallStatus: .attention("Text matching your redactions is still readable on 1 page: 2 (1 instance)"),
        durationSeconds: 7.4, perPageModes: mixed)

    static let secureFail = VerificationReport(
        layers: rows(coreSecure, recheck: recheckPass, sweep: sweepPass, [
            .textExtraction: row(.textExtraction, .fail("Text remains on 1 page"),
                                 short: "Text remains on 1 page", pages: [0]),
        ]),
        overallStatus: .fail("Text remains on 1 page"), durationSeconds: 3.9, perPageModes: secure)

    /// A verify-only run without the redaction run's per-page data: two
    /// checks skipped beside one note.
    static let searchableSkipInduced = VerificationReport(
        layers: rows(coreSearchable, recheck: recheckPass, sweep: sweepPass, [
            .characterCount: row(.characterCount, .skipped, short: "Skipped.",
                                 detail: "Character Count was not applicable for this pipeline mode."),
            .characterLineage: row(.characterLineage, .skipped, short: "Skipped.",
                                   detail: "Character Lineage was not applicable for this pipeline mode."),
            .ocrCheck: row(.ocrCheck, .info("A fill artifact was read on page 1."),
                           short: "A fill artifact was read on page 1."),
        ]),
        overallStatus: .warn("Some verification checks were skipped — results may be incomplete"),
        durationSeconds: 5.5, perPageModes: searchable)

    /// The page-count gate: one synthetic row with no identity.
    static let pageCountGate = VerificationReport(
        layers: [LayerResult(name: "Page Count Check", symbolName: "exclamationmark.triangle",
                             status: .fail("The output has 2 pages; the source has 3"),
                             shortDescription: "The output has 2 pages; the source has 3",
                             detailDescription: "", pageReferences: nil, durationSeconds: 0.01)],
        overallStatus: .fail("The output has 2 pages; the source has 3"), durationSeconds: 0.01)

    // MARK: - Previews

    @MainActor
    static func section(_ report: VerificationReport) -> some View {
        ScrollView {
            VerificationDetailsSection(report: report, deselectionSnapshot: nil,
                                       isExpanded: .constant(true), columnMaxWidth: 380)
                .padding(ResectaTokens.Spacing.md)
        }
        .environment(DocumentState())
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
