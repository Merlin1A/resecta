import UIKit
import RedactionEngine

// MARK: - Context Menu

extension RedactionOverlayView: UIContextMenuInteractionDelegate {

    /// One row of a region's long-press menu: its title and the rule it
    /// calls (`performContextMenuRow`).
    enum ContextMenuRow: Equatable {
        case info(String)
        case selectAllOnPage(enabled: Bool)
        case deselect
        case deselectAll
        case duplicate
        case viewRationale
        case deleteRegion
        case deleteSelection(count: Int)

        var title: String {
            switch self {
            case .info(let title): return title
            case .selectAllOnPage: return "Select All on Page"
            case .deselect: return "Deselect"
            case .deselectAll: return "Deselect All"
            case .duplicate: return "Duplicate Region"
            case .viewRationale: return "View Rationale"
            case .deleteRegion: return DocumentEditorToolbar.deleteLabel(count: 1)
            case .deleteSelection(let count): return DocumentEditorToolbar.deleteLabel(count: count)
            }
        }

        var systemImage: String {
            switch self {
            case .info: return "info.circle"
            case .selectAllOnPage: return "checkmark.circle"
            case .deselect, .deselectAll: return "xmark.circle"
            case .duplicate: return "plus.square.on.square"
            case .viewRationale: return "doc.text.magnifyingglass"
            case .deleteRegion, .deleteSelection: return "trash"
            }
        }

        var attributes: UIMenuElement.Attributes {
            switch self {
            case .info, .selectAllOnPage(enabled: false): return .disabled
            case .deleteRegion, .deleteSelection: return .destructive
            default: return []
            }
        }
    }

    /// The rows for a hold on `region`, decided in one place. On a region
    /// of a selected group the menu acts on the whole selection (Deselect
    /// All, Delete N Regions) and offers no Duplicate; a whole-page region
    /// offers no Duplicate either. The info row (a detected region's
    /// description) and View Rationale stay about the held region.
    static func contextMenuRows(
        for region: RedactionRegion,
        selectedIDs: Set<UUID>,
        infoTitle: String?,
        canSelectAllOnPage: Bool,
        showsRationale: Bool
    ) -> [ContextMenuRow] {
        let held = selectedIDs.contains(region.id)
        let onGroup = held && selectedIDs.count > 1
        let wholePage = region.normalizedRect == CGRect(x: 0, y: 0, width: 1, height: 1)
        var rows: [ContextMenuRow] = []
        if let infoTitle { rows.append(.info(infoTitle)) }
        rows.append(.selectAllOnPage(enabled: canSelectAllOnPage))
        if onGroup {
            rows.append(.deselectAll)
        } else if held {
            rows.append(.deselect)
        }
        if !onGroup && !wholePage { rows.append(.duplicate) }
        if showsRationale { rows.append(.viewRationale) }
        rows.append(onGroup ? .deleteSelection(count: selectedIDs.count) : .deleteRegion)
        return rows
    }

    /// Run a row's rule for a hold on `region`. Delete N Regions deletes the
    /// selection at once, one undo step, through the coordinator's one
    /// selection delete.
    func performContextMenuRow(_ row: ContextMenuRow, held region: RedactionRegion) {
        let state = coordinator?.redactionState
        switch row {
        case .info:
            break
        case .selectAllOnPage:
            state?.selectAllOnPage(pageIndex)
        case .deselect:
            state?.selectedRegionIDs.remove(region.id)
        case .deselectAll:
            state?.deselectAllRegions()
        case .duplicate:
            state?.duplicateRegion(region.id, page: pageIndex, undoManager: window?.undoManager)
            coordinator?.refreshOverlay(for: pageIndex)
        case .viewRationale:
            // Through `pendingCanvasRationaleRequest` for the sheet on
            // `DocumentEditorView`.
            state?.pendingCanvasRationaleRequest = region.id
        case .deleteRegion:
            coordinator?.deleteRegion(region.id, page: pageIndex)
        case .deleteSelection:
            coordinator?.deleteSelection()
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        // Draw wins: no context menu while the Rectangle
        // tool is on — a hold-then-drag would otherwise pop the menu and
        // cancel the draw in flight.
        guard !isDrawingMode else { return nil }

        guard let region = hitTestRegion(at: location) else { return nil }

        // Building the menu leaves the selection as it is: the rows act on
        // the selection the hold landed in. View Rationale is parked while
        // the search sheet is up, whose single sheet slot would swallow the
        // request until it closes.
        return UIContextMenuConfiguration(identifier: region.id as NSUUID, actionProvider: { [weak self] _ in
            guard let self else { return nil }
            let state = self.coordinator?.redactionState
            let rows = Self.contextMenuRows(
                for: region,
                selectedIDs: state?.selectedRegionIDs ?? self.selectedIDs,
                infoTitle: region.source != .manual
                    ? state?.regionMetadata[region.id]?.accessibilityDescription : nil,
                canSelectAllOnPage: state?.canSelectAllOnPage(self.pageIndex) == true,
                showsRationale: RedactionOverlayView.rationaleMenuShouldShow(region: region)
                    && state?.activeSearch == nil
            )
            return UIMenu(children: rows.map { row in
                UIAction(title: row.title, image: UIImage(systemName: row.systemImage),
                         attributes: row.attributes) { [weak self] _ in
                    self?.performContextMenuRow(row, held: region)
                }
            })
        })
    }
}
