import SwiftUI

// Footer summary, grouping, audit export.
// Lifted from `SearchAndRedactSheet.swift`.
// The Sort `Menu` migrated out of the footer and
// into the `SearchToolbarSection.chipRowSubstrate` chip-row consumer.
//
// The footer reads search/scan-run results (`searchState`). It is the
// surface's ONE selection authority — the "M of N selected" count and
// the prominent global Select All (the affordance set that makes
// all-deselected arrival livable). The "Add to selection" predicate
// menu that sat between them was removed: selection is per row or
// Select All.

struct SearchFooterSection: View {
    @Bindable var searchState: SearchState

    var body: some View {
        VStack(spacing: ResectaTokens.Spacing.xxs) {
            if searchState.resultsAtCap {
                // The cap banner carries the unscanned remainder
                // so "showing first N" stops reading as full coverage.
                Text(Self.capBannerText(
                    resultCount: searchState.totalCount,
                    unscannedPageCount: searchState.capUnscannedPageCount,
                    interface: searchState.searchModeType.interface
                ))
                    .font(.caption)
                    .foregroundStyle(ResectaTokens.SemanticColor.warnText)
            }
            HStack {
                // One label family for the whole surface: "M of N
                // selected" in every state (the zero state
                // reads "0 of N selected"; the footer is the selection
                // authority and states the count plainly).
                // M and N must come from the SAME domain.
                // The global `selectedCount` beside the filtered total
                // produced M>N reads under a kind filter
                // ("12 of 6 selected"); `selectedFilteredCount` keys
                // both numbers to the visible set, mirroring the nav
                // counter's filtered remap (and the Select All gate
                // below, which already compared filtered-to-filtered).
                Text(Self.selectionCountLabel(
                    selected: searchState.selectedFilteredCount,
                    total: searchState.filteredCount,
                    hiddenSelected: max(0, searchState.selectedCount - searchState.selectedFilteredCount)
                ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                // Grouping toggle. The piiScan "By Category"
                // sibling was deleted (redundant with the category
                // chips); piiScan results always group by page.
                if searchState.searchModeType == .multiTerm && searchState.searchTerms.count > 1 {
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
        let allSelected = searchState.selectedFilteredCount == searchState.filteredCount
        let action: () -> Void = {
            searchState.toggleSelectAll()
        }
        // Closure-label form so the floor can sit on
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
            // Custom prominent chrome — subheadline white label on a 36pt
            // drawn BrandTeal capsule (`BrandTeal.fill`, the filled-capsule
            // tier the parked strip's Apply shares; visual parity with the retired
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
                    .background(ResectaTokens.BrandTeal.fill, in: Capsule())
                    .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.capsulePress)
                .accessibilityIdentifier("footerSelectAllButton")
        }
    }

    /// Cap-banner copy. States the truncation AND how many pages
    /// the cancelled scan never reached (0 when the cap fired on the last
    /// page, or when the count is unavailable — the truncation sentence
    /// alone still renders). A Scan has no query to refine, so its banner
    /// drops the refine clause. Pure function pinned by
    /// `SearchFooterCapBannerTests`.
    static func capBannerText(resultCount: Int, unscannedPageCount: Int, interface: SearchInterface = .search) -> String {
        var text = "Showing first \(resultCount) results."
        if unscannedPageCount > 0 {
            let pageNoun = unscannedPageCount == 1 ? "page was" : "pages were"
            text += " \(unscannedPageCount) \(pageNoun) never scanned."
        }
        return interface == .scan ? text : text + " Refine your search for more specific matches."
    }

    /// Footer selection count for the unified surface: "M of N
    /// selected" in EVERY state, the zero state included ("0 of 30
    /// selected"). The footer is the one selection
    /// authority and states the count plainly; the former "N found —
    /// none selected yet" arrival phrasing retired with the standalone
    /// predicate rows. One rule for both origins. Selected matches a
    /// filter hides still go to Apply, so the label names them
    /// ("3 of 3 selected · 14 hidden"). Pure function pinned by
    /// `SelectionDefaultLabelTests` and `SearchFooterHiddenSelectionTests`.
    static func selectionCountLabel(selected: Int, total: Int, hiddenSelected: Int = 0) -> String {
        let label = "\(selected) of \(total) selected"
        return hiddenSelected > 0 ? label + " \u{00B7} \(hiddenSelected) hidden" : label
    }
}
