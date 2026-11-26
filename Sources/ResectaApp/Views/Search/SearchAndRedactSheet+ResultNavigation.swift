import SwiftUI

extension SearchAndRedactSheet {
    // MARK: - Result Navigation

    /// The ‹ k/N › cluster renders at EITHER site only while a walk is
    /// live — the ONE published predicate (`SearchState.isWalkLive`,
    /// which the editor's page-bar hide reads through
    /// `RedactionState.walkLive`): search results on board. The compact
    /// handle's per-item Apply / Select rides it.
    var showsResultNavCluster: Bool {
        searchState.isWalkLive
    }

    /// The medium+ search-bar site of the ‹ k/N › cluster. Geometry
    /// only — the pair keeps its row, counter, labels, ids, and
    /// shortcuts; each chevron is the set Ø44 drawn circle inside the
    /// 46pt layout floor, pair spacing 2 → 6 (≈8pt visual gap between
    /// the drawn circles). A later change to the pair's BEHAVIOUR (a
    /// tap parks the sheet at the compact float — the walk seam
    /// `focusWalk(on:parking:)`, `+Walk.swift`) re-homed the
    /// composition into the shared `resultNavCluster` builder so this
    /// site and the compact handle never drift; the geometry here is
    /// untouched (`UIFixChromeUITests` measures it) and the counter
    /// always renders at this site.
    var resultNavigationControls: some View {
        resultNavCluster(site: .searchBar)
    }

    /// The ONE result-nav cluster — the ‹ › pair plus the k/N counter
    /// — mounted at BOTH sites (the medium+ search bar's trailing edge
    /// via `resultNavigationControls`, and the parked strip in
    /// `+CompactStrip.swift`). The sites are never co-mounted, so the
    /// ids / labels / ⌘G shortcuts stay unique in the live tree. A
    /// chevron tap steps the current result AND parks the sheet at the
    /// compact float through the one walk seam (`focusWalk`); ⌘G / ⇧⌘G
    /// ride these same Buttons, so the shortcut ≡ the chevron by
    /// construction (J/K keep the medium semantics —
    /// `SearchResultsSection`). The `site` decides the geometry only
    /// (`ResultNavSite`): the search bar keeps its pinned Ø44-in-46,
    /// spacing 6, caption counter; the parked strip draws full-size
    /// controls and hides the counter from XXXL up (measured).
    func resultNavCluster(site: ResultNavSite) -> some View {
        HStack(spacing: ResectaTokens.Spacing.xs) {
            if site == .parked { stripNoticeMark }
            HStack(spacing: site.pairSpacing) {
                resultNavButton(.previous, site: site)
                resultNavButton(.next, site: site)
            }
            if !(site == .parked && dynamicTypeSize >= .xxxLarge) {
                resultNavCounter(site: site)
            }
        }
    }

    enum ResultNavDirection { case previous, next }

    /// One chevron of the pair — the step, then the seam; the ids,
    /// labels and shortcuts ride here for both sites and both
    /// compositions.
    @ViewBuilder
    func resultNavButton(_ direction: ResultNavDirection, site: ResultNavSite) -> some View {
        switch direction {
        case .previous:
            Button {
                stepWalk(.previous)
            } label: {
                Self.circularIconLabel(
                    "chevron.up", diameter: site.diameter, glyphPointSize: site.glyphPointSize)
            }
            .buttonStyle(.circularIcon)
            .accessibilityLabel("Previous result")
            .accessibilityIdentifier("resultNavPrevious")
            .keyboardShortcut("g", modifiers: [.command, .shift])
        case .next:
            Button {
                stepWalk(.next)
            } label: {
                Self.circularIconLabel(
                    "chevron.down", diameter: site.diameter, glyphPointSize: site.glyphPointSize)
            }
            .buttonStyle(.circularIcon)
            .accessibilityLabel("Next result")
            .accessibilityIdentifier("resultNavNext")
            .keyboardShortcut("g", modifiers: .command)
        }
    }

    /// Counter respects active filters. When no filter is
    /// active (filteredCount == totalCount) the simple 1-of-N form
    /// is shown. When a filter is active the counter shows the
    /// position within the visible filtered set; an en dash (–)
    /// signals that the current result is hidden by the filter.
    /// Rendered at both sites — the strings and a11y labels are
    /// unchanged; only the font follows the site (caption at the
    /// search bar, subheadline on the parked strip).
    @ViewBuilder
    func resultNavCounter(site: ResultNavSite) -> some View {
        if let idx = searchState.currentOccurrenceIndex {
            if searchState.filteredCount == searchState.totalCount {
                Text("\(idx + 1)/\(searchState.totalCount)")
                    .font(site.counterFont)
                    .monospacedDigit()
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .accessibilityLabel("Result \(idx + 1) of \(searchState.totalCount)")
            } else if let filteredPos = searchState.currentResultFilteredPosition {
                Text("\(filteredPos)/\(searchState.filteredCount)")
                    .font(site.counterFont)
                    .monospacedDigit()
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .accessibilityLabel("Result \(filteredPos) of \(searchState.filteredCount), \(searchState.totalCount - searchState.filteredCount) filtered")
            } else {
                Text("–/\(searchState.filteredCount)")
                    .font(site.counterFont)
                    .monospacedDigit()
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .accessibilityLabel("Current result hidden by filters, \(searchState.filteredCount) of \(searchState.totalCount) shown")
            }
        }
    }
}
