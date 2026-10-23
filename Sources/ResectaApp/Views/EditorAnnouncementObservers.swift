import SwiftUI
import UIKit
import RedactionEngine

// The editor's announcement observers, moved out of `DocumentEditorView.swift`
// (the hub body): the VoiceOver selection-count announcer, the hover
// observer with its region popover (iPad pointer hover), and the
// nearby-match nudge toast. A modifier with explicit inputs; it owns the
// hover popover's state.

struct EditorAnnouncementObservers: ViewModifier {
    let documentState: DocumentState
    let redactionState: RedactionState
    let toastManager: ToastQueueManager
    let undoManager: UndoManager?
    @State private var showHoverPopover = false
    @State private var hoveredMetadata: RegionMetadata?

    /// The nearby-match nudge's toast and its action.
    static let nudgeToastMessage = "1 match nearby. Mark it too?"
    static let nudgeToastActionLabel = "Mark"

    /// The spoken line for a selection change; a delete names itself with
    /// the coordinator's one delete announcement.
    static func selectionAnnouncement(newCount: Int, regionsRemoved: Bool) -> String {
        if regionsRemoved { return PDFViewCoordinator.commitAnnouncement(.deleted) }
        switch newCount {
        case 0: return "Selection cleared"
        case 1: return "1 region selected"
        default: return "\(newCount) regions selected"
        }
    }

    /// The hover popover opens for a region with metadata, never over the
    /// search sheet.
    static func showsHoverPopover(hasMetadata: Bool, searchSheetUp: Bool) -> Bool {
        hasMetadata && !searchSheetUp
    }

    /// The selection size and the document's region count, observed
    /// together so a selection drop that removed regions reads as a delete.
    private struct SelectionFacts: Equatable {
        let selected: Int
        let regions: Int
    }

    func body(content: Content) -> some View {
        content
            // VoiceOver announcement on selection count change
            .onChange(of: SelectionFacts(
                selected: redactionState.selectedRegionIDs.count,
                regions: redactionState.regions.values.reduce(0) { $0 + $1.count }
            )) { old, new in
                guard new.selected != old.selected, UIAccessibility.isVoiceOverRunning,
                      documentState.phaseKind == .editing else { return }
                AccessibilityNotification.Announcement(Self.selectionAnnouncement(
                    newCount: new.selected, regionsRemoved: new.regions < old.regions)).post()
            }
            // After Undo or Redo, show the first page the step changed and
            // say which page it is.
            .onChange(of: redactionState.lastUndoRedoPages) { _, pages in
                guard let page = pages.min(), documentState.phaseKind == .editing else { return }
                if page != documentState.currentPageIndex { documentState.currentPageIndex = page }
                AccessibilityNotification.Announcement(
                    "Page \(page + 1) of \(documentState.pageCount)").post()
            }
            // iPad hover popover — observe hoveredRegionID on RedactionState
            .onChange(of: redactionState.hoveredRegionID) { _, newID in
                if let id = newID, let metadata = redactionState.regionMetadata[id],
                   Self.showsHoverPopover(hasMetadata: true, searchSheetUp: redactionState.activeSearch != nil) {
                    hoveredMetadata = metadata
                    showHoverPopover = true
                } else {
                    showHoverPopover = false
                }
            }
            // [R-20]: manual-draw nearby-PII nudge observer. `addRegion`'s post-add
            // hook sets `pendingManualDrawNudge` after a `.manual` region commits
            // adjacent (≤ 50 pt normalized) to an unapplied high-confidence
            // PII match. We enqueue a non-modal info toast with an "Add"
            // action that calls `acceptManualDrawNudge` with the nudge captured
            // by value, so the accept survives the suppression mark below
            // clearing the pending field; a run start drops the toast. The
            // `markManualDrawNudgeSuppressed()` call gates further toasts
            // for the current search session; the suppression
            // resets on any `activeSearch` transition + on `clearAll()` +
            // on `clearForNewDocument()`.
            .onChange(of: redactionState.pendingManualDrawNudge?.id) { _, _ in
                guard let nudge = redactionState.pendingManualDrawNudge else { return }
                let capturedNudge = nudge
                toastManager.enqueue(
                    Self.nudgeToastMessage,
                    severity: .info,
                    actionLabel: Self.nudgeToastActionLabel,
                    editsRegions: true,
                    actionHandler: { [weak redactionState, weak undoManager, weak documentState] in
                        guard let state = redactionState else { return }
                        state.acceptManualDrawNudge(
                            capturedNudge, undoManager: undoManager, documentState: documentState)
                    }
                )
                redactionState.markManualDrawNudgeSuppressed()
            }
            .popover(isPresented: $showHoverPopover, attachmentAnchor: .point(.center)) {
                if let metadata = hoveredMetadata {
                    // Pass the region's forward-rationale, if any, into
                    // the popover so the "View rationale" disclosure renders.
                    let rationale = redactionState.hoveredRegionID.flatMap {
                        redactionState.rationale(forRegionID: $0)
                    }
                    RegionInfoPopover(metadata: metadata, rationale: rationale)
                        .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
                        .presentationCompactAdaptation(.popover)
                }
            }
    }
}
