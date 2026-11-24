import Foundation

// Why Redact may not start now: the refusal's cases and the one ordered
// list that decides between them. Moved here whole from DocumentState.swift
// so the refusal can gain cases without that file passing its line limit.

extension DocumentState {

    /// Why Redact may not start now. The button, ⇧⌘R and the run funnel
    /// (`PipelineCoordinator.runFullPipeline`) read this one rule.
    enum RedactRefusal: Equatable {
        case selectedMatches  // unapplied search selections; a run would drop them
        case noRegions        // no region survives the minimum-dimension filter
        case busy             // another phase, a run in flight, a pending review or a touch held on the canvas; no hint
        /// A search that counts left a page not read, and it is not yet
        /// answered: the stop at Redact, a sheet that needs an answer. It
        /// carries the pages it names, so Redact Anyway answers exactly the
        /// pages the sheet showed.
        case pagesNotRead(Set<RedactStop.Page>)

        /// How a refusal is shown: a notice that leaves, or a sheet that needs an answer.
        enum Presentation: Equatable {
            case notice
            case sheet
        }

        var presentation: Presentation {
            if case .pagesNotRead = self { return .sheet }
            return .notice
        }

        /// The hint the button speaks and the funnel shows.
        var hint: String {
            switch self {
            case .selectedMatches: return "Apply or clear the selected matches first"
            case .noRegions: return "Draw regions or apply Scan or Search results first"
            case .busy, .pagesNotRead: return ""
            }
        }
    }

    /// Whether the stop at Redact is returned. Off until the stop's sheet is
    /// drawn: a refusal with nothing on screen would leave a Redact tap
    /// silent. The sheet's own change turns it on.
    static let pagesNotReadReturned = false

    /// The one order of the refusals: the selected matches, the missing
    /// regions, a run that cannot start, then the cases that need an answer,
    /// pages not read first.
    static func refusal(
        unappliedSelections: Bool, hasRegions: Bool, canStart: Bool, pagesToName: Set<RedactStop.Page>
    ) -> RedactRefusal? {
        if unappliedSelections { return .selectedMatches }
        if !hasRegions { return .noRegions }
        if !canStart { return .busy }
        if !pagesToName.isEmpty { return .pagesNotRead(pagesToName) }
        return nil
    }

    /// True while the live search session holds selections not yet applied
    /// (a selected row no live region covers, or an auto-selected set never
    /// reviewed) — the sheet's own dismiss rule. Redact refuses on it; Home
    /// asks before closing on it.
    static func hasUnappliedSelections(_ redactionState: RedactionState) -> Bool {
        redactionState.activeSearch?.hasUnappliedSelections(
            liveApplied: redactionState.liveAppliedSearchResultIDs) ?? false
    }

    /// The refusal that holds now, or nil when Redact may start, in the one
    /// order above. A finger held on the canvas refuses as busy: the run
    /// would burn the stored place of a box the screen shows elsewhere.
    func redactRefusal(with redactionState: RedactionState) -> RedactRefusal? {
        Self.refusal(
            unappliedSelections: Self.hasUnappliedSelections(redactionState),
            hasRegions: redactionState.hasEffectiveRegions,
            canStart: canStartPipeline && !redactionState.canvasHoldsATouch,
            pagesToName: Self.pagesNotReadReturned
                ? RedactStop.namedPages(runs: redactionState.closedSearchRuns, answered: redactionState.redactStopAnswered)
                : [])
    }
}
