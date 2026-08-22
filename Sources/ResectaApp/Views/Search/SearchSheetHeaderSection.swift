import SwiftUI

// SA-2 (D-70): the sheet's in-content header row — Dismiss · title ·
// Apply — replacing the retired NavigationStack toolbar. The
// NavigationStack wrapper was one of the two proven cooperation
// poisons (18-SCROLL-ARCH §3): with it present, the sheet's
// tracked-scroll-view discovery failed through the bridged
// UINavigationController and `.automatic` content interaction
// resolved every in-list drag against scrolling. The header carries
// the toolbar contract forward unchanged: identifiers, the
// conditional-dismiss routing, and the one "Apply N" for both result
// origins. The row carries ONLY Dismiss and Apply — no overflow
// menu; saved-searches access stays in the content area (one
// bookmark per interface).

/// Nav-bar-parity header for `SearchAndRedactSheet`'s full-chrome
/// composition: Dismiss (leading) · inline title · "Apply N"
/// (trailing, semibold). VoiceOver reads leading → title → trailing
/// (the retired bar's rotor order), header before content. At
/// accessibility type sizes the single row holds and the title
/// truncates — the buttons never do (system nav-bar behavior).
struct SearchSheetHeaderSection: View {
    /// Inline title — `interface.displayName`: per-interface titles
    /// under the one chassis, carried from the retired
    /// `navigationTitle` (the former "Search & Redact" umbrella
    /// retired with the two-interface split).
    let title: String
    /// Live count on the Apply label — the review origin's accepted
    /// count or the search origin's selected count.
    let applyCount: Int
    /// Both origins' gates (zero count, in-flight apply, pipeline
    /// region ownership, fully-applied selection) are computed at the
    /// hub, where all the inputs are visible.
    let applyDisabled: Bool
    let onDismiss: () -> Void
    let onApply: () -> Void

    var body: some View {
        // `.buttonStyle(.plain)` + explicit tint on BOTH buttons is
        // load-bearing, not cosmetic: the SA-2 bisect showed
        // default-styled buttons in the sheet's fixed chrome join the
        // arbitration-poison class (18- §10) — every button proven
        // innocent in the COOP probe runs (chips, footer) is
        // plain-styled.
        HStack(spacing: ResectaTokens.Spacing.sm) {
            // UXC-18: 57-61×19.5 measured — height only, width already
            // clears the floor. Restructured from the `Button(_:action:)`
            // string initializer to a closure-label form so a
            // `.frame(minHeight:)` can sit on the label without
            // touching `.buttonStyle(.plain)` (load-bearing — see the
            // comment above). `Text("Dismiss")` is the exact same
            // label SwiftUI derives from the string initializer, so
            // the accessibility name stays byte-identical.
            Button(action: onDismiss) {
                Text("Dismiss")
                    .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("searchDismissButton")

            Spacer(minLength: ResectaTokens.Spacing.xs)

            Text(title)
                .font(.headline)
                .lineLimit(1)

            Spacer(minLength: ResectaTokens.Spacing.xs)

            // Semibold, no destructive role, disabled at zero — the
            // live count carries the scale, and the undoable mark
            // plus the "Marked N" toast carry the confirmation.
            // Identifier BEFORE `.disabled` — the retired toolbar's
            // modifier order, which keeps the identifier on the AX
            // surface in the disabled state too.
            Button(action: onApply) {
                Text("Apply \(applyCount)")
                    .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(applyDisabled
                    ? AnyShapeStyle(.tertiary)
                    : AnyShapeStyle(.tint))
                .accessibilityIdentifier("searchApplyButton")
                .disabled(applyDisabled)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
    }
}

// MARK: - Hub chrome (SA-2)

extension SearchAndRedactSheet {
    /// The sheet-level chrome both interfaces mount at the top of
    /// their inset stacks: the header row — title + Dismiss + Apply,
    /// the retired NavigationStack toolbar's exact contract, no
    /// overflow (saved-searches access stays in the content area: one
    /// `savedSearchesBookmark` per interface, both in the shared
    /// search-bar row) — plus the unified gazetteer-degrade
    /// disclosure. Opaque background: list rows scroll UNDER the
    /// inset region.
    var sheetHeaderChrome: some View {
        VStack(spacing: 0) {
            SearchSheetHeaderSection(
                title: searchState.searchModeType.interface.displayName,
                applyCount: isReviewActive
                    ? reviewAcceptedCount : searchState.selectedCount,
                // Also disabled while the pipeline owns
                // `redactionState.regions` so the mark write-back
                // transaction cannot interleave with
                // `.detecting / .redacting / .verifying`.
                applyDisabled: isReviewActive
                    ? (reviewAcceptedCount == 0
                       || !documentState.canMutateRegions)
                    : (searchState.selectedCount == 0
                       || isApplying
                       || !documentState.canMutateRegions
                       // An all-applied selection can only no-op
                       // through the overlap guard — gray the
                       // button instead of offering a "Marked 0"
                       // round-trip.
                       || searchState.selectionFullyApplied),
                onDismiss: {
                    // Conditional dismiss: route through the dialog
                    // when the USER has modified selections this
                    // session, OR (UXC-39) when this session received
                    // an auto-selected set (magic-wand preselect) that
                    // has not yet been reviewed — a never-reviewed
                    // preselect no longer drops silently on the way
                    // out. An untouched, non-preselected sheet still
                    // dismisses directly so the common no-op case adds
                    // no friction.
                    if searchState.requiresDismissConfirmation {
                        showDismissConfirmation = true
                    } else {
                        performDismiss(afterConfirmation: false)
                    }
                },
                onApply: {
                    // Both routes promote through the one
                    // `applyFindings` path — an active review as
                    // the staged-detections origin, otherwise the
                    // selected search results.
                    if isReviewActive {
                        applyReviewFindings()
                    } else {
                        applySelectedSearchResults()
                    }
                }
            )

            // Unified degrade rule: the gazetteer-degrade disclosure is unified
            // across interfaces: Scan shows it whenever the session
            // is degraded (its runs consult the detection corpus);
            // Search shows it only when a scan-class capability
            // degrades the current action — and no Search-side
            // action in this tree uses one (literal matching plus
            // OCR modality access only), so the Search side
            // renders none. Predicate is static for testability.
            if Self.degradeBannerShouldShow(
                interface: searchState.searchModeType.interface,
                degraded: redactionState.autoDetectionDegraded
            ) {
                degradedDetectionBanner
            }

            // UXC-40 shape C (RB-42): orientation line — pages with
            // hits out of total pages, mounted only after a completed
            // run that actually produced something. Orientation
            // framing only (EV-P1-02): never "scanned" / "covered" /
            // "clear" wording — the builder below is the only copy
            // for this line. Search reads the UNFILTERED result set
            // (document-wide distribution, not the filtered view);
            // Scan review reads the staged detections.
            if isReviewActive {
                let reviewPages = ScanReviewSection.flattenedFindings(
                    redactionState.pendingTriage
                ).map(\.page)
                if Self.shouldShowPagesWithHitsLine(
                    hasCompletedRun: true,
                    resultCount: reviewPages.count
                ) {
                    pagesWithHitsLineView(pagesWithHits: Self.distinctPageCount(reviewPages))
                }
            } else if Self.shouldShowPagesWithHitsLine(
                hasCompletedRun: searchState.hasCompletedRunSinceClear,
                resultCount: searchState.results.count
            ) {
                pagesWithHitsLineView(
                    pagesWithHits: Self.distinctPageCount(searchState.results.map(\.pageIndex))
                )
            }
        }
        .background(.background)
    }

    /// UXC-40 shape C (RB-42) header sub-line view — `.caption`
    /// `.secondary`, spoken text identical to the visible text.
    @ViewBuilder
    private func pagesWithHitsLineView(pagesWithHits: Int) -> some View {
        Text(Self.pagesWithHitsLine(
            pageCount: documentState.pageCount,
            pagesWithHits: pagesWithHits
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.bottom, ResectaTokens.Spacing.xs)
        .accessibilityIdentifier("pagesWithHitsLine")
    }

    // MARK: - UXC-40 shape C (RB-42) — pages-with-hits orientation line

    /// Header sub-line text — "N pages · M with hits". Orientation
    /// framing only: never "scanned" / "covered" / "clear" wording.
    /// "with hits" never inflects; only the page-count noun does.
    static func pagesWithHitsLine(pageCount: Int, pagesWithHits: Int) -> String {
        let pageWord = pageCount == 1 ? "page" : "pages"
        return "\(pageCount) \(pageWord) \u{00B7} \(pagesWithHits) with hits"
    }

    /// Gate: the line mounts only after a completed run that actually
    /// produced results — an empty or not-yet-run state shows nothing.
    static func shouldShowPagesWithHitsLine(
        hasCompletedRun: Bool,
        resultCount: Int
    ) -> Bool {
        hasCompletedRun && resultCount > 0
    }

    /// Distinct-page count for a list of page indices — the same
    /// derivation whether the source is Search's unfiltered results or
    /// Scan review's staged detections.
    static func distinctPageCount(_ pageIndices: [Int]) -> Int {
        Set(pageIndices).count
    }
}
