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

        /// The hint the button speaks and the funnel shows.
        var hint: String {
            switch self {
            case .selectedMatches: return "Apply or clear the selected matches first"
            case .noRegions: return "Draw regions or apply Scan or Search results first"
            case .busy: return ""
            }
        }
    }

    /// True while the live search session holds selections not yet applied
    /// (a selected row no live region covers, or an auto-selected set never
    /// reviewed) — the sheet's own dismiss rule. Redact refuses on it; Home
    /// asks before closing on it.
    static func hasUnappliedSelections(_ redactionState: RedactionState) -> Bool {
        redactionState.activeSearch?.hasUnappliedSelections(
            liveApplied: redactionState.liveAppliedSearchResultIDs) ?? false
    }

    /// The refusal that holds now, or nil when Redact may start. The
    /// selected matches come first, then the missing regions. A finger held
    /// on the canvas refuses as busy: the run would burn the stored place of
    /// a box the screen shows elsewhere.
    func redactRefusal(with redactionState: RedactionState) -> RedactRefusal? {
        if Self.hasUnappliedSelections(redactionState) { return .selectedMatches }
        if !redactionState.hasEffectiveRegions { return .noRegions }
        if !canStartPipeline || redactionState.canvasHoldsATouch { return .busy }
        return nil
    }
}
