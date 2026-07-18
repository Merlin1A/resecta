import SwiftUI
import RedactionEngine

// SEARCH-AND-REDACT §S3 / §S4: Footer summary, grouping, audit export.
// Lifted from `SearchAndRedactSheet.swift` (WU-01).
// WU-22 (session-9): the Sort `Menu` migrated out of the footer and
// into the `SearchToolbarSection.chipRowSubstrate` chip-row consumer.
//
// Under the unified review surface the footer serves BOTH result
// origins: search/scan-run results (reading `searchState`) and staged
// detections under review (via `ReviewFooterModel`). It is the
// surface's selection hub — the arrival label plus the prominent
// global Select All (the affordance set that makes all-
// deselected arrival livable).

struct SearchFooterSection: View {
    @Bindable var searchState: SearchState
    @Environment(RedactionState.self) private var redactionState
    @Binding var showAuditExport: Bool

    /// Review-origin inputs. nil → the footer reads `searchState`
    /// (search origin). Non-nil → counts and Select All target the
    /// staged detection findings.
    var review: ReviewFooterModel? = nil

    struct ReviewFooterModel {
        /// Explicit-true selection count across ALL staged detections
        /// (what the toolbar's "Apply N" will apply).
        let selectedCount: Int
        /// Count of detections visible under the active kind filter —
        /// the Select All target.
        let visibleCount: Int
        let allVisibleSelected: Bool
        let onToggleSelectAll: () -> Void
    }

    var body: some View {
        VStack(spacing: ResectaTokens.Spacing.xxs) {
            // Hidden for 1.0 behind `searchDiagnosticSurfacesEnabled`.
            if SearchState.searchDiagnosticSurfacesEnabled,
               review == nil,
               let explanation = searchState.lastDoctypeExplanation,
               searchState.searchModeType == .piiScan {
                DoctypeDiagnosticView(explanation: explanation)
                    .padding(.bottom, ResectaTokens.Spacing.xxs)
            }
            if review == nil, searchState.resultsAtCap {
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
                // Review-first labels: detections and matches arrive all-DESELECTED
                // from either origin, so the zero-selected state states
                // that arrival default explicitly instead of a bare
                // "0 of N selected" — one label family for the whole
                // surface.
                Text(Self.selectionCountLabel(
                    selected: review?.selectedCount ?? searchState.selectedCount,
                    total: review?.visibleCount ?? searchState.filteredCount
                ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                // W5 — Export audit log (CSV + JSON). Enabled when there
                // are live results OR any previously-applied audit entries.
                // Hidden for 1.0 behind `searchAuditSurfacesEnabled`.
                if SearchState.searchAuditSurfacesEnabled, review == nil {
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
                if review == nil,
                   searchState.searchModeType == .multiTerm && searchState.searchTerms.count > 1 {
                    Toggle("By Term", isOn: $searchState.groupByTerm)
                        .toggleStyle(.button)
                        .controlSize(.small)
                }

                selectAllButton
            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
    }

    // MARK: - Select All (selection-throughput prominence)

    /// The global Select All — prominent while it reads "Select All"
    /// (the primary throughput affordance under all-deselected
    /// arrival); the "Deselect All" state keeps the quiet style.
    @ViewBuilder
    private var selectAllButton: some View {
        let allSelected = review?.allVisibleSelected
            ?? (searchState.selectedFilteredCount == searchState.filteredCount)
        let action: () -> Void = review?.onToggleSelectAll
            ?? {
                searchState.toggleSelectAll()
                // Conditional dismiss: footer bulk selection is user selection work.
                searchState.userModifiedSelections = true
            }
        if allSelected {
            Button("Deselect All", action: action)
                .controlSize(.small)
                .accessibilityIdentifier("footerSelectAllButton")
        } else {
            Button("Select All", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("footerSelectAllButton")
        }
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

    /// Review-first labels — footer selection count for the unified
    /// surface. With results present and nothing selected yet (the
    /// arrival default for BOTH origins), the label states the
    /// none-selected default explicitly; every other combination keeps
    /// the "M of N selected" form. The former per-interface gate is
    /// gone — the arrival posture is one rule now. Pure function pinned
    /// by `SearchFooterSelectionLabelTests`.
    static func selectionCountLabel(selected: Int, total: Int) -> String {
        if total > 0 && selected == 0 {
            return "\(total) found — none selected yet"
        }
        return "\(selected) of \(total) selected"
    }
}
