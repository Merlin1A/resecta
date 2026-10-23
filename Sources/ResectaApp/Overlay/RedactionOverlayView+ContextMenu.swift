import UIKit
import RedactionEngine

// MARK: - Context Menu

extension RedactionOverlayView: UIContextMenuInteractionDelegate {

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        // Draw wins: no context menu while the Rectangle
        // tool is on — a hold-then-drag would otherwise pop the menu and
        // cancel the draw in flight.
        guard !isDrawingMode else { return nil }

        guard let region = hitTestRegion(at: location) else { return nil }

        // Select the region when showing its context menu
        coordinator?.selectRegion(region.id)

        return UIContextMenuConfiguration(identifier: region.id as NSUUID, actionProvider: { _ in
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
}
