import SwiftUI
import RedactionEngine

// W9 — "Scan coverage" disclosure shown above the results list after a
// PII scan. Read-only summary of what the scan evaluated and what passed.
//
// WU-16 (session-8): Disclosure auto-opens when the view appears
// (`@State isExpanded = true`) — the auto-open gate at
// `SearchResultsSection.swift:26-31` already conditions the view on a
// completed scan, so the disclosure shows summaries the moment the scan
// lands. Initializer accepts an `initialExpanded:` override so tests can
// pin both states. A "Share Snapshot" action inside the body builds
// counts-only CSV+JSON via `MatchExportService.shareCoverageSnapshot` —
// matched text never appears in the snapshot (privacy floor).
//
// Per-category confidence-distribution histogram
// lands inside the existing per-category sub-disclosure. Bin derivation
// is pure (see `confidenceBinCounts(results:category:bandCount:)`) and
// view-side — engine package is NOT touched. 5 fixed
// bands cover `[0.0, 0.2, 0.4, 0.6, 0.8, 1.0]`; the last band is
// inclusive of 1.0. Results without `piiConfidence` are excluded.
// The histogram is hidden when all bins are empty so categories with
// counts-but-no-confidence don't render zero-height bars.

struct CoverageReportView: View {
    let report: CoverageReport
    /// Drives view-side histogram bin derivation.
    /// Defaults to empty so legacy call sites
    /// (`CoverageSnapshotTests`) continue to compile without surfacing the
    /// histogram. The PII Scan call site at
    /// `SearchResultsSection.swift:84` threads `searchState.results`.
    let results: [SearchResult]
    /// WU-67 (session-19): intra-session result diff from
    /// `SearchState.diffSinceLastScan()`. nil on the first scan of a
    /// session (no prior snapshot to compare against) — the diff line
    /// is hidden in that case. The 3-tuple shape matches ACTION-WU-67;
    /// the rendered string is mechanism-description ("+N above
    /// threshold, −N below threshold") and classified SAFE under §19.
    let diff: (added: Int, removed: Int, unchanged: Int)?
    let onShareSnapshot: (() -> Void)?

    @State private var isExpanded: Bool

    init(
        report: CoverageReport,
        results: [SearchResult] = [],
        diff: (added: Int, removed: Int, unchanged: Int)? = nil,
        initialExpanded: Bool = true,
        onShareSnapshot: (() -> Void)? = nil
    ) {
        self.report = report
        self.results = results
        self.diff = diff
        self._isExpanded = State(initialValue: initialExpanded)
        self.onShareSnapshot = onShareSnapshot
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xs) {
                row(labelKey: "coverageReport.scannedPages",
                    value: "\(report.scannedPageCount)")
                row(labelKey: "coverageReport.enabledCategories",
                    value: "\(report.enabledCategories.count)")
                row(labelKey: "coverageReport.candidates",
                    value: "\(totalCandidates)")

                if !report.candidateCountByCategory.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                            ForEach(sortedCategoryCounts, id: \.0) { pair in
                                perCategoryRow(category: pair.0, count: pair.1)
                            }
                        }
                    } label: {
                        Text("Per category")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // WU-67 (session-19): intra-session diff line. Rendered only
                // when `diff != nil` (a prior snapshot exists in this session
                // and a re-scan completed). String is mechanism-description
                // ("+N above threshold, −N below threshold") with no outcome
                // promise — SAFE under §19. Per-category suffix
                // ("(N <category> newly suppressed)") is deferred to V1.1+
                // per the 3-tuple API in `SearchState.diffSinceLastScan()`.
                if let diff {
                    Text(Self.diffLabel(diff: diff))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Self.diffAccessibilityLabel(diff: diff))
                }

                row(labelKey: "coverageReport.applied",
                    value: "\(report.appliedCount)")
                row(labelKey: "coverageReport.deselected",
                    value: "\(report.deselectedCount)")
                row(labelKey: "coverageReport.belowThreshold",
                    value: "\(report.belowThresholdSuppressedCount)")

                if totalOverlap > 0 {
                    row(labelKey: "coverageReport.overlapSuppressed",
                        value: "\(totalOverlap)")
                }

                if let onShareSnapshot {
                    Button {
                        onShareSnapshot()
                    } label: {
                        Label(Self.shareSnapshotButtonLabel, systemImage: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, ResectaTokens.Spacing.xxs)
                    .accessibilityLabel("Share scan coverage snapshot")
                }
            }
            .padding(.top, ResectaTokens.Spacing.xxs)
        } label: {
            Label(
                String(localized: "coverageReport.title", table: "Legal"),
                systemImage: "chart.bar.doc.horizontal"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    private var totalCandidates: Int {
        report.candidateCountByCategory.values.reduce(0, +)
    }

    private var totalOverlap: Int {
        report.overlapSuppressedCountByCategory.values.reduce(0, +)
    }

    private var sortedCategoryCounts: [(PIICategory, Int)] {
        report.candidateCountByCategory
            .sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }
            .map { ($0.key, $0.value) }
    }

    // QRC-14: every `coverageReport.*` key lives in the "Legal" strings
    // table — a defaulted-table lookup resolves against Localizable and
    // renders the raw key.
    @ViewBuilder
    private func row(labelKey: String.LocalizationValue, value: String) -> some View {
        HStack {
            Text(String(localized: labelKey, table: "Legal"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    // WU-36 (session-19): per-category row — category name + (optional)
    // confidence histogram + total count. Histogram only renders when at
    // least one binned result exists, so categories whose candidates lack
    // `piiConfidence` (or are otherwise excluded from binning) don't push
    // a row of zero-height bars onto the disclosure.
    @ViewBuilder
    private func perCategoryRow(category: PIICategory, count: Int) -> some View {
        HStack(spacing: ResectaTokens.Spacing.xs) {
            Text(category.rawValue)
                .font(.caption)
            Spacer(minLength: ResectaTokens.Spacing.xs)
            if !results.isEmpty {
                let bins = Self.confidenceBinCounts(results: results, category: category)
                if bins.contains(where: { $0 > 0 }) {
                    ConfidenceHistogramRow(bins: bins, categoryRawValue: category.rawValue)
                }
            }
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - WU-36 Histogram Row

// WU-36 (session-19): private SwiftUI view for the inline 5-band
// confidence histogram inside the per-category sub-disclosure. Each band
// renders as a thin Rectangle with height proportional to its bin count
// against the per-category maximum. Empty bands render a 1pt floor so
// the bar chart stays visually contiguous. Accessibility label is
// mechanism-description ("confidence distribution, N results across M
// bands") and classified SAFE under §19.
private struct ConfidenceHistogramRow: View {
    let bins: [Int]
    let categoryRawValue: String

    private static let barWidth: CGFloat = 6
    private static let barSpacing: CGFloat = 2
    private static let maxBarHeight: CGFloat = 10

    var body: some View {
        let maxCount = max(1, bins.max() ?? 1)
        HStack(alignment: .bottom, spacing: Self.barSpacing) {
            ForEach(bins.indices, id: \.self) { i in
                Rectangle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(
                        width: Self.barWidth,
                        height: bins[i] == 0
                            ? 1
                            : max(1, CGFloat(bins[i]) / CGFloat(maxCount) * Self.maxBarHeight)
                    )
            }
        }
        .frame(height: Self.maxBarHeight, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            CoverageReportView.histogramAccessibilityLabel(
                category: categoryRawValue,
                bins: bins
            )
        )
    }
}

// MARK: - WU-16 / WU-36 Pure-Function Contracts

extension CoverageReportView {
    /// Per WU-16 / [TOKEN_ADDITIONS]: Share Snapshot button label.
    /// Classified SAFE under §19 — standard share affordance.
    static let shareSnapshotButtonLabel: String = "Share Snapshot"

    /// The disclosure auto-opens when the view first
    /// appears, immediately after the scan lands. The auto-open gate at
    /// `SearchResultsSection.swift:26-31` already conditions this view
    /// on a completed scan, so the disclosure surfaces the summary the
    /// moment a coverage report exists. Pinned by `CoverageSnapshotTests`.
    static let disclosureExpandedByDefault: Bool = true

    /// Number of bands in the confidence histogram.
    /// 5 bands cover `[0.0, 0.2, 0.4, 0.6, 0.8, 1.0]`; the last band is
    /// inclusive of 1.0 so a score of exactly 1.0 lands in the top
    /// bucket. Exposed as a static so `CoverageHistogramTests` can size
    /// assertions without coupling to a magic number.
    static let confidenceHistogramBandCount: Int = 5

    /// Pure-function bin counts for one category.
    /// Iterates `results` once per call (O(n) over `results`); excludes
    /// entries with `piiConfidence == nil` or `piiCategory != category`.
    /// Returns `bandCount` integers — each index `i` covers
    /// `[i / bandCount, (i+1) / bandCount)` except the last band, which
    /// is inclusive of 1.0. Confidence values are clamped to `[0.0, 1.0]`
    /// defensively. Performance: pinned <100ms for 10k synthetic results
    /// on the simulator host by
    /// `CoverageHistogramTests.binsTenThousandResultsUnderHundredMs`
    /// (acceptance target <50ms per `WORK_UNITS.md#wu-36`; budget widened
    /// for simulator host variance per session-19 flake-watch posture).
    static func confidenceBinCounts(
        results: [SearchResult],
        category: PIICategory,
        bandCount: Int = confidenceHistogramBandCount
    ) -> [Int] {
        guard bandCount > 0 else { return [] }
        let bandWidth = 1.0 / Double(bandCount)
        var counts = Array(repeating: 0, count: bandCount)
        for r in results where r.piiCategory == category {
            guard let c = r.piiConfidence else { continue }
            let clamped = max(0.0, min(1.0, c))
            var band = Int(clamped / bandWidth)
            if band >= bandCount { band = bandCount - 1 }
            counts[band] += 1
        }
        return counts
    }

    /// WU-36: VoiceOver label for the per-category histogram row.
    /// Mechanism-description — names the category, total binned count,
    /// and band count. No outcome promise. Classified SAFE under §19.
    static func histogramAccessibilityLabel(category: String, bins: [Int]) -> String {
        let total = bins.reduce(0, +)
        return "\(category) confidence distribution, \(total) results across \(bins.count) bands"
    }

    /// WU-67 (session-19): rendered label for the intra-session diff
    /// line. Format: `"+<added> above threshold, −<removed> below
    /// threshold"`. Uses the U+2212 MINUS SIGN (`−`) per the action
    /// spec's typographic convention. Mechanism-description — no
    /// outcome promise; classified SAFE under §19.
    /// `static` so the helper is callable from tests without hosting
    /// the SwiftUI runtime.
    static func diffLabel(diff: (added: Int, removed: Int, unchanged: Int)) -> String {
        return "+\(diff.added) above threshold, −\(diff.removed) below threshold"
    }

    /// WU-67: VoiceOver label for the diff line. Spells out the symbols
    /// (`+` / `−`) into words for natural speech and includes the
    /// `unchanged` count, which is otherwise implicit from the rendered
    /// string. Mechanism-description; classified SAFE under §19.
    static func diffAccessibilityLabel(diff: (added: Int, removed: Int, unchanged: Int)) -> String {
        return "Diff since last scan: \(diff.added) added above threshold, \(diff.removed) removed below threshold, \(diff.unchanged) unchanged"
    }
}
