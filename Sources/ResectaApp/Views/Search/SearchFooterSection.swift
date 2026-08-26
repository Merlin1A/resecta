import SwiftUI

// SEARCH-AND-REDACT §S3 / §S4: Footer summary, grouping, audit export.
// Lifted from `SearchAndRedactSheet.swift` (WU-01).
// WU-22 (session-9): the Sort `Menu` migrated out of the footer and
// into the `SearchToolbarSection.chipRowSubstrate` chip-row consumer.
//
// Under the unified review surface the footer serves BOTH result
// origins: search/scan-run results (reading `searchState`) and staged
// detections under review (via `ReviewFooterModel`). UXC-45 (D-117,
// RB-105/109): it is the surface's ONE selection authority — the
// "M of N selected" count and the prominent global Select All (the
// affordance set that makes all-deselected arrival livable). UXC-46
// (D-121) removed the "Add to selection" predicate menu that sat
// between them: selection is per row or Select All.

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
                // One label family for the whole surface: "M of N
                // selected" in every state (UXC-45 — the zero state
                // reads "0 of N selected"; the footer is the selection
                // authority and states the count plainly).
                // BH-A-01 — M and N must come from the SAME domain.
                // The global `selectedCount` beside the filtered total
                // produced M>N reads under a kind filter
                // ("12 of 6 selected"); `selectedFilteredCount` keys
                // both numbers to the visible set, mirroring the nav
                // counter's filtered remap (and the Select All gate
                // below, which already compared filtered-to-filtered).
                Text(Self.selectionCountLabel(
                    selected: review?.selectedCount ?? searchState.selectedFilteredCount,
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
                // sibling was deleted (redundant with the category
                // chips); piiScan results always group by page.
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
        // UXC-18/REV-01: closure-label form so the floor can sit on
        // the label; `Text(...)` reproduces the exact
        // string-initializer label, so the accessible name is
        // unchanged in both states.
        if allSelected {
            Button(action: action) {
                Text("Deselect All")
                    .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
                .controlSize(.small)
                .accessibilityIdentifier("footerSelectAllButton")
        } else {
            // REV-01 (packet §7.2 item 5, RB-66/RB-67): custom
            // prominent chrome — subheadline white label on a 36pt
            // drawn BrandTeal capsule (visual parity with the retired
            // `.borderedProminent` small control), with the 46pt
            // LAYOUT floor + contentShape AFTER the fill so the drawn
            // pill stays compact. The Deselect branch above is
            // untouched (quiet style; its floor was already
            // invisible). Pressed state on `CapsulePressButtonStyle`.
            Button(action: action) {
                Text("Select All")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(ResectaTokens.BrandTeal.tint, in: Capsule())
                    .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.capsulePress)
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

    /// Footer selection count for the unified surface: "M of N
    /// selected" in EVERY state, the zero state included ("0 of 30
    /// selected"). UXC-45 (RB-105): the footer is the one selection
    /// authority and states the count plainly; the former "N found —
    /// none selected yet" arrival phrasing retired with the standalone
    /// predicate rows. One rule for both origins. Pure function pinned
    /// by `SelectionDefaultLabelTests`.
    static func selectionCountLabel(selected: Int, total: Int) -> String {
        "\(selected) of \(total) selected"
    }
}
