import Foundation
import RedactionEngine

// Visibility predicate for the canvas-surface
// "View rationale" UIAction. The
// predicate is a static function so the gating contract is testable
// without a UIView host.
//
// The canvas `UIContextMenuInteractionDelegate` (in
// `RedactionOverlayView.swift`) consults this predicate before
// appending the "View Rationale" UIAction. The long-press
// density cap means the item shares the existing `UIContextMenuInteraction`
// rather than via a second interaction, and only appears when the
// region's `Source` carries a non-nil `MatchRationale` — same gating
// the iPad `RegionInfoPopover.View rationale` disclosure uses.

extension RedactionOverlayView {

    /// Gating predicate for the "View Rationale"
    /// UIAction on the canvas context menu. Visible when the tapped
    /// region's `Source` carries a `MatchRationale` (i.e. it was applied
    /// from a search result that captured detector reasoning). Manual
    /// draws and detected faces never qualify because their `Source`
    /// cases hold no `rationale` associated value. Pinned by
    /// `CanvasRationaleMenuTests.menuVisibility…`.
    static func rationaleMenuShouldShow(region: RedactionRegion) -> Bool {
        switch region.source {
        case .detectedPII(_, let rationale): return rationale != nil
        case .searchMatch(_, let rationale): return rationale != nil
        case .manual, .detectedFace:        return false
        }
    }
}
