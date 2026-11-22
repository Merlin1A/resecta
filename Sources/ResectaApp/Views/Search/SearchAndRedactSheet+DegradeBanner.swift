import SwiftUI
import RedactionEngine

extension SearchAndRedactSheet {
    // MARK: - the unified degrade rule Degrade banner

    /// Unified degrade-banner rule: Scan always surfaces a degraded
    /// detection corpus (its runs consult it); Search only when a
    /// scan-class capability degrades the CURRENT action — and no
    /// Search-side action in this tree uses one (literal matching plus
    /// OCR modality access), so the Search side renders none until a
    /// recall-aid lands there. Pure predicate, pinned by
    /// `DegradedBannerTests`.
    static func degradeBannerShouldShow(
        interface: SearchInterface,
        degraded: Bool
    ) -> Bool {
        degraded && interface == .scan
    }

    /// Persistent top banner while `redactionState.autoDetectionDegraded`
    /// is true (one or more gazetteer / context-keywords resources failed
    /// to load this session). The copy is a mechanism description —
    /// describes what happened and what remains available, no outcome
    /// promises. The copy pass reworded the inherited banner line: the
    /// state is a degrade (runs proceed with the resources that
    /// loaded), and the retired flow name is gone — the wording now
    /// matches the toast that announces the same state.
    @ViewBuilder
    var degradedDetectionBanner: some View {
        HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(DetectionDegradeCopy.banner(
                failedGazetteers: redactionState.autoDetectionDegradeFailures))
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
        .background(ResectaTokens.SemanticColor.warningTint.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("degradedDetectionBanner")
        .accessibilityAddTraits(.isHeader)
    }

    // `debounceSearch(query:)`, `triggerSearch()`, the two apply
    // handlers (toolbar + keyboard shortcut), `applyShortcutEnabled`,
    // and the saved-search recall live in
    // `Search/SearchAndRedactSheet+Trigger.swift` (M-6 hub-cap
    // decomposition; run-orchestration family stays together).

    func presentReverseRationale(for result: SearchResult) {
        let doctype = searchState.lastDoctypeExplanation?.primary
        let context = ReverseRationaleContext.make(
            snippet: result.contextSnippet, matchedText: result.matchedText)
        activeModal = .rationale(ReverseRationaleRequest(
            snippet: result.matchedText,
            fullContext: context,
            doctype: doctype
        ))
    }

    /// Content for the per-row rationale case of `activeModal`.
    /// Looks up the row by id from `searchState.results`; if the row is
    /// no longer present (rare race during result-list updates), the
    /// sheet renders an empty view and SwiftUI dismisses on the next
    /// update cycle.
    @ViewBuilder
    func rowRationaleSheet(rowID: UUID) -> some View {
        if let result = searchState.results.first(where: { $0.id == rowID }) {
            MatchRationaleSheet(result: result)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        } else {
            EmptyView()
        }
    }

    /// The query, built from the session alone (`SearchQuery`).
    func buildSearchMode() -> SearchMode { SearchQuery(searchState: searchState).buildSearchMode() }

    /// Pure decision for the results-arrival detent raise. True only
    /// on the empty → non-empty transition while the sheet sits at
    /// `.medium`: compactFloat is a deliberate canvas-visible state
    /// and large already shows the list, so neither is touched. Static
    /// so `SearchDetentRaiseTests` pins the contract without driving
    /// the SwiftUI render cycle.
    static func shouldRaiseDetentForArrivedResults(
        wasEmpty: Bool,
        isEmpty: Bool,
        currentDetent: PresentationDetent
    ) -> Bool {
        wasEmpty && !isEmpty && currentDetent == .medium
    }
}
