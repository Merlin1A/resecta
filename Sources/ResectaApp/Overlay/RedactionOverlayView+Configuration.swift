import UIKit
import RedactionEngine

// The overlay's configure call, moved out of `RedactionOverlayView.swift`
// (the hub) from its `// MARK: - Configuration` seam: it takes the regions,
// the selection, the search highlights and the live preview from the
// editor's state, and does nothing while a drag is active. The state it writes is stored on the hub
// (an extension adds no storage).

extension RedactionOverlayView {
    // MARK: - Configuration

    /// Update displayed regions from RedactionState.
    /// No-op while a drag is active to avoid mid-gesture state reset.
    func configure(
        with regions: [RedactionRegion],
        selectedIDs: Set<UUID>,
        searchHighlights: [SearchResult] = [],
        livePreviewRects: [CGRect] = [],
        focusedHighlightID: UUID? = nil
    ) {
        guard !isActivelyDragging else { return }
        let geometryChanged = regions != self.regions
        let selectionChanged = selectedIDs != self.selectedIDs
        let searchChanged = searchHighlights != self.searchHighlights
        let previewChanged = livePreviewRects != self.livePreviewRects
        // The result walk can move the ring without any other
        // input changing — its own dirty bit.
        let focusChanged = focusedHighlightID != self.focusedHighlightID
        self.regions = regions
        self.selectedIDs = selectedIDs
        self.searchHighlights = searchHighlights
        self.livePreviewRects = livePreviewRects
        self.focusedHighlightID = focusedHighlightID
        if geometryChanged || selectionChanged || searchChanged || previewChanged || focusChanged {
            cachedAccessibilityElements = nil
            setNeedsDisplay()
        }
        // Animate resize handle transitions on selection change
        let newSingleID = selectedIDs.count == 1 ? selectedIDs.first : nil
        if selectionChanged {
            if previousSelectedID == nil, newSingleID != nil {
                animateHandlesIn()
            } else if previousSelectedID != nil, newSingleID == nil {
                animateHandlesOut()
            } else if previousSelectedID != newSingleID, newSingleID != nil {
                // Changed single selection — instant swap (handles stay visible)
                handleScale = 1.0
            }
            previousSelectedID = newSingleID
        }
        // Post VoiceOver layout notification on geometry changes
        if geometryChanged {
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }
}
