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

    func body(content: Content) -> some View {
        content
            // VoiceOver announcement on selection count change
            .onChange(of: redactionState.selectedRegionIDs.count) { oldCount, newCount in
                guard UIAccessibility.isVoiceOverRunning,
                      documentState.phaseKind == .editing else { return }
                let announcement: String
                switch newCount {
                case 0:  announcement = "Selection cleared"
                case 1:  announcement = "1 region selected"
                default: announcement = "\(newCount) regions selected"
                }
                AccessibilityNotification.Announcement(announcement).post()
            }
            // iPad hover popover — observe hoveredRegionID on RedactionState
            .onChange(of: redactionState.hoveredRegionID) { _, newID in
                if let id = newID, let metadata = redactionState.regionMetadata[id] {
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
                    "1 match nearby. Add to selection?",
                    severity: .info,
                    actionLabel: "Add",
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
