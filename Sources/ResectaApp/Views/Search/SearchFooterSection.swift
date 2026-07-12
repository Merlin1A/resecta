import SwiftUI
import RedactionEngine

// SEARCH-AND-REDACT §S3 / §S4: Footer summary, grouping, audit export.
// Lifted from `SearchAndRedactSheet.swift` (WU-01); behavior unchanged.
// WU-22 (session-9): the Sort `Menu` migrated out of the footer and
// into the `SearchToolbarSection.chipRowSubstrate` chip-row consumer.
// FooterSection becomes simpler.

struct SearchFooterSection: View {
    @Bindable var searchState: SearchState
    @Environment(RedactionState.self) private var redactionState
    @Binding var showAuditExport: Bool

    var body: some View {
        VStack(spacing: ResectaTokens.Spacing.xxs) {
            // Hidden for 1.0 behind `searchDiagnosticSurfacesEnabled`.
            if SearchState.searchDiagnosticSurfacesEnabled,
               let explanation = searchState.lastDoctypeExplanation,
               searchState.searchModeType == .piiScan {
                DoctypeDiagnosticView(explanation: explanation)
                    .padding(.bottom, ResectaTokens.Spacing.xxs)
            }
            if searchState.resultsAtCap {
                // QW-12 — the cap banner carries the unscanned remainder
                // so "showing first N" stops reading as full coverage.
                Text(Self.capBannerText(
                    resultCount: searchState.totalCount,
                    unscannedPageCount: searchState.capUnscannedPageCount
                ))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                // UXF-13 (labels only): piiScan results arrive
                // all-DESELECTED — the mirror of triage's all-selected
                // default. The label states that default explicitly
                // instead of a bare "0 of N selected".
                Text(Self.selectionCountLabel(
                    selected: searchState.selectedCount,
                    total: searchState.filteredCount,
                    isPIIScan: searchState.searchModeType == .piiScan
                ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                // W5 — Export audit log (CSV + JSON). Enabled when there
                // are live results OR any previously-applied audit entries.
                // Hidden for 1.0 behind `searchAuditSurfacesEnabled`.
                if SearchState.searchAuditSurfacesEnabled {
                    Button {
                        showAuditExport = true
                    } label: {
                        Label("Export Audit", systemImage: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .controlSize(.small)
                    .disabled(searchState.results.isEmpty
                              && redactionState.appliedMatchAudit.isEmpty)
                    .accessibilityHint("Share a CSV and JSON record of detected matches and their detection rules.")
                }

                // Grouping toggle. The piiScan "By Category"
                // sibling was deleted (redundant with the category chips +
                // "Select where…"); piiScan results always group by page.
                if searchState.searchModeType == .multiTerm && searchState.searchTerms.count > 1 {
                    Toggle("By Term", isOn: $searchState.groupByTerm)
                        .toggleStyle(.button)
                        .controlSize(.small)
                }

                Button(searchState.selectedFilteredCount == searchState.filteredCount ? "Deselect All" : "Select All") {
                    searchState.toggleSelectAll()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
    }

    /// QW-12 — cap-banner copy. States the truncation AND how many pages
    /// the cancelled scan never reached (0 when the cap fired on the last
    /// page, or when the count is unavailable — the truncation sentence
    /// alone still renders). Pure function pinned by
    /// `SearchFooterCapBannerTests`.
    static func capBannerText(resultCount: Int, unscannedPageCount: Int) -> String {
        var text = "Showing first \(resultCount) results."
        if unscannedPageCount > 0 {
            let pageNoun = unscannedPageCount == 1 ? "page was" : "pages were"
            text += " \(unscannedPageCount) \(pageNoun) never scanned."
        }
        return text + " Refine your search for more specific matches."
    }

    /// UXF-13 (labels only) — footer selection count. In piiScan mode
    /// with results present and nothing selected yet (the arrival
    /// default), the label states the none-selected default explicitly;
    /// every other combination keeps the existing "M of N selected"
    /// form. Pure function pinned by `SearchFooterSelectionLabelTests`.
    static func selectionCountLabel(selected: Int, total: Int, isPIIScan: Bool) -> String {
        if isPIIScan && total > 0 && selected == 0 {
            return "\(total) found — none selected yet"
        }
        return "\(selected) of \(total) selected"
    }
}
