import UIKit
import RedactionEngine

// The canvas long-press menu, moved out of `RedactionOverlayView.swift`
// (the hub) along its `// MARK: - Context Menu` seam: the
// `UIContextMenuInteractionDelegate` conformance (the region menu, the
// magic-wand menu over an OCR word) and the magic-wand request payload.
// The hub installs the interaction in `init` as before.

// MARK: - Context Menu

extension RedactionOverlayView: UIContextMenuInteractionDelegate {

    /// Return the OCR word whose normalized bounding box
    /// contains the given overlay-space point. Returns nil when no
    /// word is hit or when the OCR cache hasn't been populated for
    /// the page. Pure helper so `MagicWandUITests` can pin the gating
    /// contract without touching `UIContextMenuInteraction`. The
    /// hit-test runs in overlay space (top-left origin) —
    /// `pdfNormalizedToOverlay` flips the Y axis so the rect aligns
    /// with UIKit touch coordinates.
    func hitTestOCRWord(at point: CGPoint) -> OCRWord? {
        guard !ocrWords.isEmpty else { return nil }
        for word in ocrWords {
            let overlayRect = pdfNormalizedToOverlay(word.normalizedRect)
            if overlayRect.contains(point) { return word }
        }
        return nil
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        // Draw wins: no context menu while the Rectangle
        // tool is on — a hold-then-drag would otherwise pop the menu and
        // cancel the draw in flight.
        guard !isDrawingMode else { return nil }
        // When no region is at the touch point but an OCR word is,
        // surface the magic-wand "Select all instances" menu (gated on hit).
        // Existing region menu still wins when both are present so the
        // user can still operate on a region they long-pressed on top of.
        if hitTestRegion(at: location) == nil,
           let ocrWord = hitTestOCRWord(at: location) {
            return makeMagicWandMenuConfiguration(for: ocrWord)
        }

        guard let region = hitTestRegion(at: location) else { return nil }

        // Select the region when showing its context menu
        coordinator?.selectRegion(region.id)

        return UIContextMenuConfiguration(actionProvider: { _ in
            var actions: [UIMenuElement] = []

            // Region info item (disabled — display only).
            // Only for detected regions with metadata.
            if region.source != .manual,
               let metadata = self.coordinator?.redactionState?.regionMetadata[region.id] {
                let infoAction = UIAction(
                    title: metadata.accessibilityDescription,
                    image: UIImage(systemName: "info.circle"),
                    attributes: .disabled
                ) { _ in }
                actions.append(infoAction)
            }

            // Select All on Page
            let selectAllAction = UIAction(
                title: "Select All on Page",
                image: UIImage(systemName: "checkmark.circle")
            ) { [weak self] _ in
                guard let self,
                      let regions = self.coordinator?.redactionState?.regions[self.pageIndex]
                else { return }
                self.coordinator?.redactionState?.selectedRegionIDs = Set(regions.map(\.id))
            }
            actions.append(selectAllAction)

            // Deselect (only when tapped region is selected)
            if self.selectedIDs.contains(region.id) {
                let deselectAction = UIAction(
                    title: "Deselect",
                    image: UIImage(systemName: "xmark.circle")
                ) { [weak self] _ in
                    self?.coordinator?.redactionState?.selectedRegionIDs.remove(region.id)
                }
                actions.append(deselectAction)
            }

            // Duplicate Region — long-press menu item that copies
            // the region with a small offset (clamped into page bounds by
            // `RedactionState.duplicateRegion`). Action name "Duplicate
            // Redaction" surfaces in the iOS long-press Undo menu per the
            // existing "<verb> Redaction" pattern.
            let duplicateAction = UIAction(
                title: "Duplicate Region",
                image: UIImage(systemName: "plus.square.on.square")
            ) { [weak self] _ in
                guard let self else { return }
                self.coordinator?.redactionState?.duplicateRegion(
                    region.id, page: self.pageIndex,
                    undoManager: self.window?.undoManager
                )
                self.coordinator?.refreshOverlay(for: self.pageIndex)
            }
            actions.append(duplicateAction)

            // View rationale — gated on the
            // region's `Source` carrying a non-nil `MatchRationale`.
            // Mirrors the iPad popover's disclosure visibility so the
            // menu density stays at the existing cap when no
            // rationale data exists. Action routes through
            // `pendingCanvasRationaleRequest` for sheet presentation on
            // `DocumentEditorView`, same pattern as Tag Exemption above.
            // Also parked while the search sheet is presented: the
            // single `ActiveSheet` slot gives `activeSearch` precedence,
            // so a request set now would sit swallowed until the search
            // sheet closes and then pop up as an orphaned modal.
            if RedactionOverlayView.rationaleMenuShouldShow(region: region),
               self.coordinator?.redactionState?.activeSearch == nil {
                let rationaleAction = UIAction(
                    title: "View Rationale",
                    image: UIImage(systemName: "doc.text.magnifyingglass")
                ) { [weak self] _ in
                    self?.coordinator?.redactionState?
                        .pendingCanvasRationaleRequest = region.id
                }
                actions.append(rationaleAction)
            }

            // Delete action
            let deleteAction = UIAction(
                title: "Delete Region",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                guard let self else { return }
                self.coordinator?.deleteRegion(region.id, page: self.pageIndex)
            }
            actions.append(deleteAction)

            return UIMenu(children: actions)
        })
    }

    /// Build the magic-wand context menu for a long-pressed OCR
    /// word. The menu reads "Select all instances" and routes through
    /// `RedactionState.pendingMagicWandRequest` so the host view can
    /// open the search sheet pre-filled with an exact-match search.
    /// Regex specials in the hit word are escaped at this call site —
    /// the engine accepts the raw term and
    /// does not regex-escape inside the runtime.
    private func makeMagicWandMenuConfiguration(
        for ocrWord: OCRWord
    ) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return UIMenu(children: []) }
            let escapedTerm = RedactionOverlayView.escapeRegexSpecials(in: ocrWord.text)
            let action = UIAction(
                title: "Select all instances",
                image: UIImage(systemName: "wand.and.stars")
            ) { [weak self] _ in
                guard let self else { return }
                let request = MagicWandSearchRequest(
                    escapedTerm: escapedTerm
                )
                self.coordinator?.redactionState?.pendingMagicWandRequest = request
            }
            return UIMenu(children: [action])
        })
    }

    /// Escape the regex metacharacters that
    /// `NSRegularExpression.escapedPattern(for:)` would handle, so a hit
    /// word like `C++` matches the literal sequence and not a regex
    /// (regex-escape at the call site, not in
    /// the engine runtime). The engine's text path uses literal
    /// substring matching so the escape is belt-and-suspenders — kept
    /// because the design keeps the escape responsibility on
    /// the caller, and a future routing change in the engine must not
    /// silently break the magic-wand contract.
    static func escapeRegexSpecials(in term: String) -> String {
        NSRegularExpression.escapedPattern(for: term)
    }
}

/// Payload carried by `RedactionState.pendingMagicWandRequest`
/// when the canvas long-press menu fires "Select all instances".
/// `escapedTerm` is the regex-escaped form fed into the search engine via
/// `SearchMode.text(escapedTerm, options:)` with `exactMatch = true`.
struct MagicWandSearchRequest: Equatable, Sendable {
    let escapedTerm: String
}
