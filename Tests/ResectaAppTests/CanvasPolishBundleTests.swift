import Testing
import Foundation
@testable import ResectaApp

// Canvas polish bundle. Three independently-scoped
// sub-fixes pinned by string-literal / predicate / shape tests so each
// one can fail in isolation if a future tweak drifts the message or
// the gating shape.

@Suite("Canvas polish bundle")
@MainActor
struct CanvasPolishBundleTests {

    // MARK: - Sub-threshold VoiceOver string

    @Test("Sub-threshold rejection names the remedy, not the floor")
    func subThresholdAnnouncementNamesTheRemedy() {
        // The floor is in screen points, so a number in the copy is wrong
        // at any zoom but 1×; the copy says what to do instead.
        #expect(
            RedactionOverlayView.subThresholdRejectionAnnouncement
            == "Region too small. Zoom in to draw a smaller region."
        )
        #expect(RedactionOverlayView.subThresholdRejectionAnnouncement
            .range(of: #"\d"#, options: .regularExpression) == nil)
    }

    @Test("The too-small notice reaches the toast queue through the coordinator")
    func tooSmallNoticeGoesThroughTheCoordinator() {
        let coordinator = PDFViewCoordinator()
        #expect(coordinator.noteRegionTooSmall() == false, "no queue attached: the overlay speaks it")
        let toasts = ToastQueueManager()
        coordinator.toastManager = toasts
        #expect(coordinator.noteRegionTooSmall())
        #expect(toasts.activeToasts.map(\.message) == [RedactionOverlayView.subThresholdRejectionAnnouncement])
    }

    // MARK: - Batch-delete dialog page-span

    @Test("Page count derives from unique pages spanned by the selection")
    func pageCountIsUniquePagesInSelection() {
        let id0 = UUID(), id1 = UUID(), id2 = UUID(), id3 = UUID()
        let pages: [UUID: Int] = [id0: 0, id1: 0, id2: 3, id3: 7]
        let selection: Set<UUID> = [id0, id1, id2, id3]
        let count = DocumentEditorView.selectedPageCount(
            selectedIDs: selection,
            pageLookup: { pages[$0] }
        )
        #expect(count == 3)  // pages 0, 3, 7
    }

    @Test("Page count is zero when every selection ID misses the lookup")
    func pageCountZeroOnMissingLookups() {
        let selection: Set<UUID> = [UUID(), UUID()]
        let count = DocumentEditorView.selectedPageCount(
            selectedIDs: selection,
            pageLookup: { _ in nil }
        )
        #expect(count == 0)
    }

    @Test("Plural-region / plural-page message reads with the s-suffixed nouns")
    func dialogMessagePluralsBothNouns() {
        let msg = DocumentEditorView.batchDeleteDialogMessage(
            regionCount: 5, pageCount: 2
        )
        #expect(msg.contains("Deleting 5 regions across 2 pages."))
        #expect(msg.contains("Use Undo to restore them."))
    }

    @Test("Single region / single page switches to the singular nouns")
    func dialogMessageSingularsBothNouns() {
        let msg = DocumentEditorView.batchDeleteDialogMessage(
            regionCount: 1, pageCount: 1
        )
        #expect(msg.contains("Deleting 1 region across 1 page."))
        // Singular branch must NOT pluralize either noun:
        #expect(msg.contains("1 regions") == false)
        #expect(msg.contains("1 pages") == false)
    }

    @Test("Mixed shape (plural regions, single page) keeps grammar coherent")
    func dialogMessageMixedShape() {
        let msg = DocumentEditorView.batchDeleteDialogMessage(
            regionCount: 4, pageCount: 1
        )
        #expect(msg.contains("Deleting 4 regions across 1 page."))
        #expect(msg.contains("1 pages") == false)
    }

    // MARK: - Drawing-mode caption predicate

    @Test("Caption is visible only with rectangle tool active in editing phase")
    func captionVisibleOnlyDuringRectangleEditing() {
        #expect(DocumentEditorView.drawingModeCaptionShouldShow(
            activeTool: .rectangle, phaseKind: .editing
        ) == true)
    }

    @Test("Caption hides when no tool is active")
    func captionHidesWithNoActiveTool() {
        #expect(DocumentEditorView.drawingModeCaptionShouldShow(
            activeTool: nil, phaseKind: .editing
        ) == false)
    }

    @Test("Caption hides outside the editing phase even with the tool on")
    func captionHidesOutsideEditingPhase() {
        // The detecting / redacting / verifying phases blur the canvas
        // underneath their own progress card, so the caption underneath
        // would be stale — gate it on the editing phase.
        let nonEditingPhases: [DocumentState.PhaseKind] = [
            .empty, .importing, .detecting,
            .redacting, .verifying, .exporting, .failed,
        ]
        for phase in nonEditingPhases {
            #expect(DocumentEditorView.drawingModeCaptionShouldShow(
                activeTool: .rectangle, phaseKind: phase
            ) == false)
        }
    }

    @Test("Caption copy names the gesture mechanism (no outcome verb)")
    func captionMechanismDescription() {
        // Mechanism-description language — names the gesture, not
        // a promised outcome. "Drag to draw" names what one finger does and
        // "two fingers to scroll" names the other gesture; the user supplies
        // the intent.
        #expect(DocumentEditorView.drawingModeCaption == "Drag to draw · two fingers to scroll")
    }
}
