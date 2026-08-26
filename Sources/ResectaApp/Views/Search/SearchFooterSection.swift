import SwiftUI
import RedactionEngine

// SEARCH-AND-REDACT §S3 / §S4: Footer summary, grouping, audit export.
// Lifted from `SearchAndRedactSheet.swift` (WU-01).
// WU-22 (session-9): the Sort `Menu` migrated out of the footer and
// into the `SearchToolbarSection.chipRowSubstrate` chip-row consumer.
//
// Under the unified review surface the footer serves BOTH result
// origins: search/scan-run results (reading `searchState`) and staged
// detections under review (via `ReviewFooterModel`). UXC-45 (D-117,
// RB-105/109): it is the surface's ONE selection authority — the
// "M of N selected" count, the compact "Add to selection" predicate
// menu (each origin's predicates, relocated here from the full-width
// rows both origins used to mount above their lists), and the
// prominent global Select All (the affordance set that makes all-
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
                // sibling was deleted (redundant with the category chips +
                // "Select where…"); piiScan results always group by page.
                if review == nil,
                   searchState.searchModeType == .multiTerm && searchState.searchTerms.count > 1 {
                    Toggle("By Term", isOn: $searchState.groupByTerm)
                        .toggleStyle(.button)
                        .controlSize(.small)
                }

                addToSelectionMenu
                selectAllButton
            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
    }

    // MARK: - Add to selection (UXC-45, RB-105/109)

    /// Compact predicate menu beside Select All — the "Add to selection"
    /// affordance both origins used to render as a full-width row above
    /// their lists. The items are each origin's predicates, unchanged:
    /// RB-21/UXC-12 additive (union) semantics — a predicate ADDS every
    /// matching row to whatever is already selected and never deselects
    /// anything; narrowing to exactly a predicate's matches is the
    /// "Deselect All" → predicate two-step. Search predicates apply to
    /// `searchState.results` (not `filteredResults`) so the menu stays
    /// useful when filters hide candidates; review predicates apply to
    /// every staged detection. Every pick flips the conditional-dismiss
    /// touched tracker exactly once. (Menus are fine here — the D-70
    /// arbitration poisons concern the compact strip, not the footer.)
    private var addToSelectionMenu: some View {
        Menu {
            if review != nil {
                reviewPredicateItems
            } else {
                searchPredicateItems
            }
        } label: {
            Image(systemName: "checklist")
                .font(.body)
                .foregroundStyle(.tint)
                // RB-54/67: 46-pt layout floor on both axes.
                .frame(
                    width: ResectaTokens.TouchTarget.minimum,
                    height: ResectaTokens.TouchTarget.minimum
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Add to selection")
        .accessibilityHint("Adds every result matching an attribute to the selection")
        .accessibilityIdentifier("footerAddToSelectionMenu")
    }

    /// Search-origin predicates (relocated from `SearchResultsSection`,
    /// items unchanged). Each Section corresponds to one predicate kind
    /// (confidence threshold, source, category, applied state); every
    /// branch routes through `userSelectWhere`.
    @ViewBuilder
    private var searchPredicateItems: some View {
        Section("By confidence") {
            Button("\u{2265} 75%") {
                userSelectWhere { ($0.piiConfidence ?? 0) >= 0.75 }
            }
            Button("\u{2265} 90%") {
                userSelectWhere { ($0.piiConfidence ?? 0) >= 0.90 }
            }
        }
        Section("By source") {
            Button("Text") {
                userSelectWhere { $0.source == .textLayer }
            }
            Button("OCR") {
                userSelectWhere { $0.source != .textLayer }
            }
        }
        if searchState.searchModeType == .piiScan {
            let categories = searchState.categoryCounts.keys
                .sorted(by: { $0.rawValue < $1.rawValue })
            if !categories.isEmpty {
                Section("By category") {
                    ForEach(categories, id: \.self) { category in
                        Button(category.rawValue) {
                            userSelectWhere { $0.piiCategory == category }
                        }
                    }
                }
            }
        }
        Section("By applied state") {
            Button("Applied") {
                let applied = searchState.appliedResultIDs
                userSelectWhere { applied.contains($0.id) }
            }
            Button("Unapplied") {
                let applied = searchState.appliedResultIDs
                userSelectWhere { !applied.contains($0.id) }
            }
        }
    }

    /// Select-Where wrapper: the additive predicate union plus the
    /// conditional-dismiss touched flip — predicate selection is user
    /// selection work, so the sheet's Dismiss confirms from here forward.
    private func userSelectWhere(_ predicate: (SearchResult) -> Bool) {
        searchState.addToSelection(where: predicate)
        searchState.userModifiedSelections = true
    }

    /// Review-origin predicates (relocated from `ScanReviewSection`,
    /// items unchanged): RB-21/UXC-12 — additive (union), so "≥ 90%"
    /// ADDS the matching detections to whatever is already selected and
    /// never deselects the rest.
    @ViewBuilder
    private var reviewPredicateItems: some View {
        let kindsWithCounts = ScanReviewSection.kindsWithCounts(
            in: ScanReviewSection.flattenedFindings(redactionState.pendingTriage)
        )
        Section("By confidence") {
            Button("\u{2265} 75%") { addToReviewSelection { $0.confidence >= 0.75 } }
            Button("\u{2265} 90%") { addToReviewSelection { $0.confidence >= 0.90 } }
        }
        if !kindsWithCounts.isEmpty {
            Section("By category") {
                ForEach(kindsWithCounts, id: \.kind) { item in
                    Button(item.kind.fullName) {
                        addToReviewSelection { $0.kind == item.kind }
                    }
                }
            }
        }
    }

    /// RB-21/UXC-12: additive predicate selection over the staged
    /// detections — unions the predicate's matches into the existing
    /// `triageSelections` via `ScanReviewSection.addSelections(where:in:to:)`
    /// rather than replacing the dictionary outright, so a prior manual
    /// pick or an earlier predicate's matches are never deselected by a
    /// later one.
    private func addToReviewSelection(_ predicate: (DetectionResult) -> Bool) {
        redactionState.triageSelections = ScanReviewSection.addSelections(
            where: predicate,
            in: ScanReviewSection.flattenedFindings(redactionState.pendingTriage),
            to: redactionState.triageSelections
        )
        // Conditional dismiss: predicate selection is user selection work.
        searchState.userModifiedSelections = true
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
