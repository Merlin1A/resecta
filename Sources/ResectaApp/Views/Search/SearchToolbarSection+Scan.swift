import SwiftUI
import RedactionEngine

// The Scan interface's options panel and the OCR controls row both
// interfaces share, as an extension of `SearchToolbarSection`. The base
// file keeps the view's state, the standard options, the chip strips
// and the substrate; this file reads the search state and the document
// state the base declares. The members the two files read across the
// cut are internal rather than private: `documentState` and the
// category-chips row in the base, and these two views, which the base's
// `body` and its standard options mount.

extension SearchToolbarSection {

    // MARK: - Scan Options

    var scanOptions: some View {
        VStack(spacing: ResectaTokens.Spacing.xs) {
            // The role subtitle moved from here into
            // the pre-scan empty state
            // (`SearchEmptyStateCopy.description(for: .piiScanPreScan)`).
            //
            // The per-run Confidence slider that lived here is retired:
            // Settings' Detection Sensitivity preset is the one
            // engine-level control, and the confidence sort is the
            // review-side confidence tool (the Select-where ≥75/≥90
            // predicates retired with the footer menu).

            // Category chips — pre-scan detector selection over
            // `enabledPIICategories` — plus the trailing re-run
            // affordance. Toggling narrows the NEXT run; runs stay
            // trigger-driven (no auto re-run on chip change).
            // The strip is retired for 1.0 — dark behind
            // `scanCategoryStripEnabled` (the ↻ re-run relocated to
            // the sheet's search-bar row; the "no categories" notice
            // below goes unreachable with it, since the strip is the
            // only UI that can empty the selection). Machinery and
            // tests stay compiled.
            if SearchState.scanCategoryStripEnabled {
                scanChipsRow
            }

            // An empty selection means the next run scans everything —
            // say so where the chips would otherwise read as "nothing".
            if searchState.enabledPIICategories.isEmpty {
                HStack {
                    Text("No categories selected \u{2014} the next scan runs all detectors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, ResectaTokens.Spacing.md)
            }

            // The whole OCR block (toggle + controls row) renders
            // only when a page can actually route to OCR; on all-`.rich`
            // documents the engine never runs OCR, so the controls carry
            // no information there. Fail-open on an unknown map.
            if Self.piiScanOCRBlockShouldShow(
                anyPageAwaitsOCR: documentState.textLayerStatus.values
                    .contains { $0 != .rich },
                statusKnown: !documentState.textLayerStatus.isEmpty
            ) {
                // Include OCR toggle for the scan run
                HStack {
                    Toggle("Include OCR Pages", isOn: $searchState.options.includeOCR)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        // Disable while a run is in flight.
                        .disabled(Self.optionControlsDisabled(isSearching: searchState.isSearching))
                        .accessibilityLabel("Include scanned page text")
                    Spacer()
                }
                .padding(.horizontal, ResectaTokens.Spacing.md)

                // Mirror the source-filter + OCR
                // confidence slider into the Scan interface. Reuses
                // the same `ocrControlsRow` component so the gating helpers
                // (`ocrControlsShouldShow`, `ocrSliderShouldBeDisabled`,
                // `awaitingOCRResultsCaption`) stay canonical across modes.
                ocrControlsRow
            }
        }
    }

    // MARK: - OCR Controls (shared by standardSearchOptions + piiScanOptions)

    /// Shared source filter + OCR confidence slider.
    /// Visibility gate via `ocrControlsShouldShow(includeOCR:)`; disabled
    /// state via `ocrSliderShouldBeDisabled(hasOCRResults:)`. Caption
    /// text comes from `awaitingOCRResultsCaption`. Used by both
    /// `standardSearchOptions` (text/regex/multi-term) and
    /// `piiScanOptions` (PII Scan).
    @ViewBuilder
    var ocrControlsRow: some View {
        if Self.ocrControlsShouldShow(includeOCR: searchState.options.includeOCR) {
            let isDisabled = Self.ocrSliderShouldBeDisabled(
                hasOCRResults: searchState.hasOCRResults
            )
            HStack(spacing: ResectaTokens.Spacing.md) {
                Picker("Source", selection: $searchState.sourceFilter) {
                    ForEach(SourceFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Filter by source")

                if searchState.sourceFilter != .textOnly {
                    HStack(spacing: 4) {
                        Text("OCR ≥\(Int(searchState.minimumOCRConfidence * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                        Slider(value: $searchState.minimumOCRConfidence, in: 0...1, step: 0.05)
                            .frame(maxWidth: 120)
                            .accessibilityLabel("Minimum OCR confidence")
                    }
                }
            }
            .padding(.horizontal, ResectaTokens.Spacing.md)
            .disabled(isDisabled)

            if isDisabled {
                // The caption is conditional: "awaiting" only
                // when at least one page will actually route to OCR.
                let caption = Self.ocrDisabledCaption(
                    anyPageAwaitsOCR: documentState.textLayerStatus.values
                        .contains { $0 != .rich }
                )
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ResectaTokens.Spacing.md)
                    // The caption is a full sentence that may open with
                    // an acronym ("OCR not needed …") — lowercasing it
                    // produced "ocr not needed" in the spoken label.
                    .accessibilityLabel("OCR controls disabled: \(caption)")
            }
        }
    }
}
