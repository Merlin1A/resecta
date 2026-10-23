import Testing
import Foundation
@testable import ResectaApp

// The editor's announcement observers: a delete says what happened, the
// hover popover stays down while the search sheet is up, and the nearby-
// match nudge offers to mark the match.
@Suite("Editor announcement observers", .tags(.overlay))
@MainActor
struct EditorAnnouncementObserversTests {

    @Test("A delete announces the delete, not a cleared selection")
    func deleteAnnouncesItself() {
        #expect(EditorAnnouncementObservers.selectionAnnouncement(newCount: 0, regionsRemoved: true)
                == PDFViewCoordinator.commitAnnouncement(.deleted))
        #expect(EditorAnnouncementObservers.selectionAnnouncement(newCount: 0, regionsRemoved: false)
                == "Selection cleared")
        #expect(EditorAnnouncementObservers.selectionAnnouncement(newCount: 3, regionsRemoved: false)
                == "3 regions selected")
    }

    @Test("No hover popover while the search sheet is up")
    func noHoverPopoverOverTheSheet() {
        #expect(EditorAnnouncementObservers.showsHoverPopover(hasMetadata: true, searchSheetUp: false))
        #expect(!EditorAnnouncementObservers.showsHoverPopover(hasMetadata: true, searchSheetUp: true))
    }

    @Test("Undo and Redo name the step with its page, or with its page count")
    func undoRedoAnnouncement() {
        #expect(EditorAnnouncementObservers.undoRedoAnnouncement(
            .init(pages: [2], name: "Add Region", serial: 1), pageCount: 5) == "Add Region, page 3 of 5")
        #expect(EditorAnnouncementObservers.undoRedoAnnouncement(
            .init(pages: [0, 2], name: "Delete Regions", serial: 2), pageCount: 5) == "Delete Regions, on 2 pages")
    }

    @Test("The nearby-match nudge reads its copy")
    func nudgeCopy() {
        #expect(EditorAnnouncementObservers.nudgeToastMessage == "1 match nearby. Mark it too?")
        #expect(EditorAnnouncementObservers.nudgeToastActionLabel == "Mark")
    }
}
