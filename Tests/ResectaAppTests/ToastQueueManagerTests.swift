import Testing
import Foundation
import SwiftUI
@testable import ResectaApp

// ToastQueueManager lifecycle: one receipt at a time, identity by event, a
// life on a clock that runs only while the receipt is drawn, layers, holds,
// phases, the slot, announcements and the review request. A test that needs
// time moves a clock of its own and asks the queue to settle; the run
// start's drop and the drain tests use the real clock across the 0.3 s gap.

/// A clock a test moves by hand.
private final class QueueTestClock {
    var now = ContinuousClock.now
    func advance(_ seconds: Double) { now = now.advanced(by: .seconds(seconds)) }
}

/// What a test's closures record.
private final class QueueTestRecord {
    var count = 0
    var lines: [String] = []
}

@Suite("ToastQueueManager")
@MainActor
struct ToastQueueManagerTests {

    /// A queue on a test's clock, with VoiceOver and Switch Control off and
    /// announcements recorded rather than spoken.
    private func queue(_ clock: QueueTestClock, spoken: QueueTestRecord = QueueTestRecord()) -> ToastQueueManager {
        let mgr = ToastQueueManager()
        mgr.now = { clock.now }
        mgr.voiceOverRunning = { false }
        mgr.switchControlRunning = { false }
        mgr.postAnnouncement = { spoken.lines.append($0) }
        return mgr
    }

    @Test("First enqueue shows the toast")
    func firstEnqueueShows() {
        let mgr = ToastQueueManager()
        mgr.enqueue(ToastItem(message: "Welcome", severity: .info))
        #expect(mgr.activeToasts.count == 1)
        #expect(mgr.activeToasts.first?.message == "Welcome")
    }

    // MARK: - Identity is the event

    @Test("Two posts of one event are one message")
    func onePostedEventIsOneMessage() throws {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        let event = mgr.post(.marked(applied: 3, alreadyCovered: 0))
        let shown = try #require(mgr.activeToasts.first)
        clock.advance(2)
        mgr.settleClocks()
        let again = mgr.post(.marked(applied: 4, alreadyCovered: 0), event: event)
        #expect(again == event)
        #expect(mgr.activeToasts.count == 1)
        #expect(mgr.waitingToasts.isEmpty)
        #expect(mgr.activeToasts.first?.id == shown.id, "replaced in place")
        #expect(mgr.activeToasts.first?.message == "Marked 4 for redaction. Not redacted until you tap Redact.")
        #expect(mgr.receiptClock(of: shown.id)?.remaining(at: clock.now) == 6.0, "its clock starts again")
    }

    @Test("Two messages of different tones are shown one after the other")
    func differentTonesOneAfterTheOther() {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        mgr.enqueue(ToastItem(message: "Heads up", severity: .warning))
        mgr.enqueue(ToastItem(message: "All good", severity: .success))
        #expect(mgr.activeToasts.map(\.message) == ["Heads up"], "never two at once")
        #expect(mgr.waitingToasts.map(\.message) == ["All good"])
        clock.advance(1)
        mgr.settleClocks()
        #expect(mgr.activeToasts.map(\.message) == ["Heads up"])
        clock.advance(0.5)
        mgr.settleClocks()
        #expect(mgr.activeToasts.map(\.message) == ["All good"], "a plain one gives way after 1.5 s")
    }

    @Test("Same position queues subsequent toasts")
    func samePositionQueues() {
        let mgr = ToastQueueManager()
        mgr.enqueue(ToastItem(message: "First", severity: .info))
        mgr.enqueue(ToastItem(message: "Second", severity: .info))
        mgr.enqueue(ToastItem(message: "Third", severity: .info))
        // All three distinct; only first is active.
        #expect(mgr.activeToasts.count == 1)
        #expect(mgr.activeToasts.first?.message == "First")
    }

    @Test("Two events with the same words are both shown")
    func sameWordsTwoEvents() throws {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        mgr.post(.deletedBoxes(count: 2), action: {})
        mgr.post(.deletedBoxes(count: 2), action: {})
        let first = try #require(mgr.activeToasts.first)
        #expect(mgr.activeToasts.map(\.message) == ["Deleted 2 regions."])
        #expect(mgr.waitingToasts.map(\.message) == ["Deleted 2 regions."], "the second waits; it is not dropped")
        mgr.dismiss(first)
        clock.advance(0.5)
        mgr.settleClocks()
        let second = try #require(mgr.activeToasts.first)
        #expect(second.message == "Deleted 2 regions.")
        #expect(second.id != first.id)
        #expect(mgr.waitingToasts.isEmpty)
    }

    // MARK: - A repeat that tells nothing new

    @Test("The results-limit warning posted at three runs in a row is one message")
    func resultsLimitThreeRunsOneMessage() {
        let mgr = queue(QueueTestClock())
        let events = (0..<3).map { _ in mgr.post(.searchResultsTruncated) }
        #expect(mgr.activeToasts.count == 1)
        #expect(mgr.waitingToasts.isEmpty)
        #expect(Set(events).count == 1, "each repeat is the shown message")
    }

    @Test("A repeated refusal is one message while it is up and is shown again after it has left")
    func repeatedRefusal() throws {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        mgr.post(.drawOrApplyFirst)
        mgr.post(.drawOrApplyFirst)
        let first = try #require(mgr.activeToasts.first)
        #expect(mgr.activeToasts.count == 1)
        #expect(mgr.waitingToasts.isEmpty)
        mgr.dismiss(first)
        clock.advance(0.5)
        mgr.settleClocks()
        mgr.post(.drawOrApplyFirst)
        let again = try #require(mgr.activeToasts.first)
        #expect(again.id != first.id)
        #expect(again.message == DocumentState.RedactRefusal.noRegions.hint)
    }

    @Test("A repeat is dropped while the first waits behind another message")
    func repeatWhileWaiting() {
        let mgr = queue(QueueTestClock())
        mgr.post(.deletedBoxes(count: 2), action: {})
        mgr.post(.searchResultsTruncated)
        mgr.post(.searchResultsTruncated)
        #expect(mgr.activeToasts.map(\.message) == ["Deleted 2 regions."])
        #expect(mgr.waitingToasts.map(\.message)
                == ["Search results truncated. Refine your query for more specific matches."])
    }

    @Test("A refused drop with another way back is another message")
    func refusedDropOtherWayBack() {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        let keepEditing = DocumentState.importBlockedOnThisScreenMessage(wayBack: DocumentState.keepEditingTitle)
        let reopen = DocumentState.importBlockedOnThisScreenMessage(
            wayBack: FailedStateView.primaryActionLabel(.reopenDocument))
        #expect(keepEditing != reopen)
        mgr.post(.importBlockedOnThisScreen(wayBack: DocumentState.keepEditingTitle))
        mgr.post(.importBlockedOnThisScreen(wayBack: FailedStateView.primaryActionLabel(.reopenDocument)))
        #expect(mgr.activeToasts.map(\.message) == [keepEditing])
        #expect(mgr.waitingToasts.map(\.message) == [reopen])
        clock.advance(1.5)
        mgr.settleClocks()
        #expect(mgr.activeToasts.map(\.message) == [reopen])
    }

    // MARK: - The run start's drop

    // The plain toast is posted last: a plain message that is waiting gives way to any
    // newer one, so posted before the second action toast it would be gone before the drop.
    @Test("A run start's drop removes every toast that carries an action, shown or queued, and keeps the rest")
    func dropActionToastsKeepsOtherToasts() async throws {
        let mgr = ToastQueueManager()
        mgr.enqueue(ToastItem(
            message: "Mode switch cleared 2 unapplied matches.", severity: .info, actionLabel: "Undo", actionHandler: {}))
        mgr.enqueue(ToastItem(
            message: "1 match nearby. Mark it too?", severity: .info, actionLabel: "Mark", actionHandler: {}))
        mgr.enqueue(ToastItem(message: "Saved", severity: .info))
        #expect(mgr.activeToasts.count == 1)
        #expect(mgr.activeToasts.first?.actionHandler != nil)

        mgr.dropActionToasts()

        #expect(!mgr.activeToasts.contains { $0.actionHandler != nil },
                "the shown toast with an action is withdrawn")
        // The queue drains after the 0.3 s gap: only the plain toast is left.
        for _ in 0..<100 {
            if mgr.activeToasts.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mgr.activeToasts.map { $0.message } == ["Saved"])
        mgr.dismiss(mgr.activeToasts[0])
        try await Task.sleep(for: .milliseconds(450))
        #expect(mgr.activeToasts.isEmpty, "the waiting toast with an action never shows")
    }

    @Test("A run start's drop leaves a toast without an action on screen")
    func dropActionToastsLeavesAPlainToast() {
        let mgr = ToastQueueManager()
        mgr.enqueue(ToastItem(message: "Saved", severity: .info))
        let shown = mgr.activeToasts.map(\.id)
        #expect(shown.count == 1)

        mgr.dropActionToasts()

        #expect(mgr.activeToasts.map(\.id) == shown, "a toast without an action stays for its own time")
    }

    @Test("Manual dismiss removes the active toast and drains the queue after 0.3 s gap")
    func dismissDrainsQueue() async throws {
        let mgr = ToastQueueManager()
        mgr.enqueue(ToastItem(message: "First", severity: .info))
        mgr.enqueue(ToastItem(message: "Second", severity: .info))
        let first = mgr.activeToasts.first!
        mgr.dismiss(first)
        // Immediate removal from activeToasts (animation target state).
        #expect(mgr.activeToasts.count == 0)
        // Self-clocking — poll until the 300 ms-gap drain promotes the
        // queued toast instead of a fixed 450 ms wall-clock sleep (which flaked
        // under full-suite load). The 300 ms drain gap constant is NOT
        // reduced; only the test wait becomes deterministic.
        for _ in 0..<100 {
            if mgr.activeToasts.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mgr.activeToasts.count == 1)
        #expect(mgr.activeToasts.first?.message == "Second")
    }

    @Test("clearAll empties active + queued + cancels pending drain")
    func clearAllIsIdempotent() async throws {
        let mgr = ToastQueueManager()
        mgr.enqueue(ToastItem(message: "First", severity: .warning))
        mgr.enqueue(ToastItem(message: "Second", severity: .warning))
        mgr.enqueue(ToastItem(message: "Third", severity: .info))
        mgr.clearAll()
        #expect(mgr.activeToasts.isEmpty)
        // Second clearAll is a no-op.
        mgr.clearAll()
        #expect(mgr.activeToasts.isEmpty)
        // No drain task should resurrect the queued toast.
        try await Task.sleep(for: .milliseconds(450))
        #expect(mgr.activeToasts.isEmpty)
    }

    @Test("toastVersion increments on enqueue and dismiss")
    func toastVersionMoves() {
        let mgr = ToastQueueManager()
        let v0 = mgr.toastVersion
        mgr.enqueue(ToastItem(message: "Hello", severity: .info))
        #expect(mgr.toastVersion > v0)
        let v1 = mgr.toastVersion
        mgr.dismiss(mgr.activeToasts.first!)
        #expect(mgr.toastVersion > v1)
    }

    // MARK: - Life

    @Test("An action keeps a receipt at least 8 seconds")
    func actionKeepsEightSeconds() {
        let mgr = queue(QueueTestClock())
        let short = ToastItem(message: "Cleared 1 match.", severity: .info,
                              actionLabel: "Undo", actionHandler: {})
        #expect(mgr.displayDuration(for: short) == 8.0)
        let noAction = ToastItem(message: "Cleared 1 match.", severity: .info)
        #expect(mgr.displayDuration(for: noAction) == 2.5)
    }

    @Test("A long message is not cut short")
    func longMessageNotCutShort() throws {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        let owner = ToastItem(
            message: RedactWorkspaceView.encryptedSourceMessage(hadRestrictions: true), severity: .warning)
        #expect(mgr.displayDuration(for: owner) == 12.0)
        let long = ToastItem(message: Array(repeating: "word", count: 200).joined(separator: " "),
                             severity: .error)
        #expect(mgr.displayDuration(for: long) == 101.0)
        #expect(mgr.displayDuration(for: ToastItem(message: "Ok", severity: .info)) == 2.5)
        // On screen it stays its whole 12 seconds.
        mgr.post(.encryptedSource(hadRestrictions: true))
        let shown = try #require(mgr.activeToasts.first)
        clock.advance(11.5)
        mgr.settleClocks()
        #expect(mgr.activeToasts.map(\.id) == [shown.id])
        clock.advance(0.5)
        mgr.settleClocks()
        #expect(mgr.activeToasts.isEmpty)
    }

    // MARK: - Layers

    @Test("With no layer registered the queue behaves as one drawing root")
    func noLayerOneDrawingRoot() throws {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        mgr.post(.shared)
        let item = try #require(mgr.activeToasts.first)
        #expect(mgr.registeredLayerCount == 0)
        #expect(mgr.receipt(drawnBy: UUID())?.id == item.id)
        #expect(mgr.receiptClock(of: item.id)?.isRunning == true)
        #expect(!mgr.receiptAtSlot)
        clock.advance(2.5)
        mgr.settleClocks()
        #expect(mgr.activeToasts.isEmpty, "it leaves on its clock")
    }

    @Test("A receipt belongs to the layer in front, and while that layer yields the layer below draws it")
    func receiptBelongsToTheFront() throws {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        let root = UUID(), search = UUID()
        mgr.registerLayer(root, role: .root)
        mgr.registerLayer(search, role: .draws)
        mgr.post(.marked(applied: 3, alreadyCovered: 0))
        let item = try #require(mgr.activeToasts.first)
        #expect(mgr.receipt(drawnBy: search)?.id == item.id)
        #expect(mgr.receipt(drawnBy: root) == nil, "the root draws nothing")
        clock.advance(1)
        mgr.setLayerYields(search, true)
        #expect(mgr.receipt(drawnBy: root)?.id == item.id)
        #expect(mgr.receipt(drawnBy: search) == nil)
        clock.advance(1)
        mgr.setLayerYields(search, false)
        #expect(mgr.receipt(drawnBy: search)?.id == item.id)
        #expect(mgr.receiptClock(of: item.id)?.remaining(at: clock.now) == 4.0, "the time left is kept")
    }

    @Test("A warning a run raises belongs to the sheet that ran it: raised under the saved list, it waits and is drawn on Search once the list is gone")
    func runWarningBelongsToItsSheet() throws {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        let root = UUID(), search = UUID(), saved = UUID()
        mgr.registerLayer(root, role: .root)
        mgr.registerLayer(search, role: .draws)
        mgr.registerLayer(saved, role: .draws)
        // A recall closes the saved list and starts Search's run at once:
        // the list is still in front when the run's first warning is posted.
        mgr.post(.scannedRegionsNotAnalyzed, runLayer: search)
        #expect(mgr.receipt(drawnBy: saved) == nil, "not drawn in the list that is leaving")
        #expect(mgr.activeToasts.isEmpty)
        #expect(mgr.waitingToasts.count == 1)
        clock.advance(0.4)
        mgr.settleClocks()
        mgr.unregisterLayer(saved)
        let warning = try #require(mgr.activeToasts.first, "the list's leaving does not end it")
        #expect(warning.message == MessageCatalog.row(for: .scannedRegionsNotAnalyzed).text)
        #expect(mgr.receipt(drawnBy: search)?.id == warning.id)

        // A layer named at a post that is no longer registered gives the
        // message today's rule: the layer in front when it is shown.
        let other = QueueTestClock()
        let second = queue(other)
        second.registerLayer(root, role: .root)
        second.registerLayer(saved, role: .draws)
        second.post(.searchResultsTruncated, runLayer: search)
        let shown = try #require(second.activeToasts.first)
        #expect(second.receipt(drawnBy: saved)?.id == shown.id)
    }

    @Test("A sheet over a receipt ends a plain one; one that must be seen comes back for the rest of its life")
    func sheetOverAReceipt() throws {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        let root = UUID(), search = UUID(), saved = UUID()
        mgr.registerLayer(root, role: .root)
        mgr.registerLayer(search, role: .draws)
        mgr.post(.marked(applied: 3, alreadyCovered: 0))
        mgr.registerLayer(saved, role: .draws)
        #expect(mgr.activeToasts.isEmpty)
        #expect(mgr.waitingToasts.isEmpty, "a plain one ends")
        mgr.unregisterLayer(saved)
        clock.advance(0.5)
        mgr.settleClocks()

        mgr.post(.deletedBoxes(count: 2), action: {})
        let undo = try #require(mgr.activeToasts.first)
        clock.advance(3)
        mgr.settleClocks()
        mgr.registerLayer(saved, role: .draws)
        #expect(mgr.activeToasts.isEmpty)
        #expect(mgr.waitingToasts.map(\.id) == [undo.id], "paused, not ended")
        #expect(mgr.receipt(drawnBy: saved) == nil)
        clock.advance(20)
        mgr.settleClocks()
        #expect(mgr.waitingToasts.map(\.id) == [undo.id])
        mgr.unregisterLayer(saved)
        #expect(mgr.receipt(drawnBy: search)?.id == undo.id)
        #expect(mgr.receiptClock(of: undo.id)?.remaining(at: clock.now) == 5.0, "the rest of its life")

        clock.advance(4)
        mgr.settleClocks()
        mgr.registerLayer(saved, role: .draws)
        mgr.unregisterLayer(saved)
        clock.advance(0.5)
        mgr.settleClocks()
        #expect(mgr.receipt(drawnBy: search)?.id == undo.id)
        #expect(mgr.receiptClock(of: undo.id)?.remaining(at: clock.now) == 2.5, "and at least 2.5 s")
    }

    @Test("A hidden surface ends nothing and stops the clock")
    func hiddenSurfaceEndsNothing() throws {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        let root = UUID(), search = UUID()
        mgr.registerLayer(root, role: .root)
        mgr.registerLayer(search, role: .draws)
        mgr.post(.deletedBoxes(count: 2), action: {})
        let undo = try #require(mgr.activeToasts.first)
        clock.advance(2)
        mgr.settleClocks()
        mgr.setLayerSurface(search, visible: false)
        #expect(mgr.activeToasts.map(\.id) == [undo.id], "nothing ends")
        #expect(mgr.receipt(drawnBy: search) == nil, "it is not drawn")
        #expect(mgr.receiptClock(of: undo.id)?.isRunning == false, "its clock stops")
        clock.advance(30)
        mgr.settleClocks()
        mgr.post(.shared)
        #expect(mgr.activeToasts.map(\.id) == [undo.id])
        #expect(mgr.waitingToasts.map(\.message) == ["Shared."], "an arrival waits")
        mgr.setLayerSurface(search, visible: true)
        #expect(mgr.receipt(drawnBy: search)?.id == undo.id)
        #expect(mgr.receiptClock(of: undo.id)?.remaining(at: clock.now) == 6.0, "the rest of its life")
        clock.advance(5)
        mgr.settleClocks()
        mgr.setLayerSurface(search, visible: false)
        mgr.setLayerSurface(search, visible: true)
        #expect(mgr.receiptClock(of: undo.id)?.remaining(at: clock.now) == 2.5, "and at least 2.5 s")
    }

    @Test("A layer's leaving ends its receipts, shown or paused")
    func layerLeavingEndsItsReceipts() {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        let root = UUID(), search = UUID(), saved = UUID()
        mgr.registerLayer(root, role: .root)
        mgr.registerLayer(search, role: .draws)
        mgr.post(.deletedBoxes(count: 2), action: {})
        #expect(mgr.activeToasts.count == 1)
        mgr.unregisterLayer(search)
        #expect(mgr.activeToasts.isEmpty, "a shown one ends")
        #expect(mgr.waitingToasts.isEmpty)

        mgr.registerLayer(search, role: .draws)
        clock.advance(0.5)
        mgr.settleClocks()
        mgr.post(.deletedBoxes(count: 3), action: {})
        mgr.registerLayer(saved, role: .draws)
        #expect(mgr.waitingToasts.count == 1, "paused under the saved list")
        mgr.unregisterLayer(search)
        #expect(mgr.waitingToasts.isEmpty, "a paused one ends with its layer")
        #expect(mgr.activeToasts.isEmpty)
    }

    @Test("A message about leaving a layer is shown in the layer that remains")
    func leavingMessageInTheRemainingLayer() {
        let mgr = queue(QueueTestClock())
        let root = UUID(), search = UUID()
        mgr.registerLayer(root, role: .root)
        mgr.registerLayer(search, role: .draws)
        let words = SearchAndRedactSheet.dismissClearedMessage(unappliedCount: 3, interface: .search)
        mgr.post(.searchClosedCleared(count: 3, interface: .search))
        #expect(mgr.activeToasts.isEmpty, "it waits while Search is in front")
        #expect(mgr.waitingToasts.map(\.message) == [words].compactMap { $0 })
        mgr.unregisterLayer(search)
        #expect(mgr.receipt(drawnBy: root)?.message == words)
    }

    @Test("Under a layer that only holds, receipts wait and the shown one's clock stops")
    func holdsOnlyLayer() throws {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        let root = UUID(), asking = UUID()
        mgr.registerLayer(root, role: .root)
        mgr.post(.marked(applied: 3, alreadyCovered: 0))
        let marked = try #require(mgr.activeToasts.first)
        clock.advance(1)
        mgr.registerLayer(asking, role: .holdsOnly)
        #expect(mgr.activeToasts.map(\.id) == [marked.id], "nothing ends")
        #expect(mgr.receipt(drawnBy: root) == nil)
        #expect(mgr.receiptClock(of: marked.id)?.isRunning == false)
        mgr.unregisterLayer(asking)
        #expect(mgr.receipt(drawnBy: root)?.id == marked.id)
        #expect(mgr.receiptClock(of: marked.id)?.remaining(at: clock.now) == 5.0)
        mgr.dismiss(marked)
        clock.advance(0.5)
        mgr.settleClocks()

        mgr.registerLayer(asking, role: .holdsOnly)
        mgr.post(.shared)
        #expect(mgr.activeToasts.isEmpty)
        #expect(mgr.waitingToasts.map(\.message) == ["Shared."])
        mgr.unregisterLayer(asking)
        #expect(mgr.receipt(drawnBy: root)?.message == "Shared.")
    }

    @Test("Registering a layer twice keeps one entry, and unregistering it twice leaves none")
    func layerRegistrationIsIdempotent() {
        let mgr = queue(QueueTestClock())
        let root = UUID()
        mgr.registerLayer(root, role: .root)
        mgr.registerLayer(root, role: .root)
        #expect(mgr.registeredLayerCount == 1)
        mgr.unregisterLayer(root)
        mgr.unregisterLayer(root)
        #expect(mgr.registeredLayerCount == 0)
        mgr.post(.shared)
        #expect(mgr.receipt(drawnBy: UUID())?.message == "Shared.", "one drawing root again")
    }

    // MARK: - Phases and guards

    @Test("With no phase pushed no message ends by phase")
    func noPhasePushed() {
        let mgr = queue(QueueTestClock())
        mgr.post(.deletedBoxes(count: 2), action: {})
        mgr.post(.outputReclaimed, action: {})
        mgr.post(.shareSheetUnavailable)
        mgr.revalidate()
        #expect(mgr.documentPhase == nil)
        #expect(mgr.activeToasts.count == 1)
        #expect(mgr.waitingToasts.count == 2, "a row of another phase stays")
    }

    @Test("A message ends when the app leaves the phases its row names")
    func endsOutsideItsPhases() {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        mgr.documentPhaseDidChange(to: .editing)
        mgr.post(.marked(applied: 3, alreadyCovered: 0))
        #expect(mgr.activeToasts.count == 1)
        mgr.documentPhaseDidChange(to: .redacting)
        #expect(mgr.activeToasts.isEmpty, "the Marked message does not stay over the run")
        mgr.documentPhaseDidChange(to: .verified)
        clock.advance(0.5)
        mgr.settleClocks()
        mgr.post(.outputReclaimed, action: {})
        #expect(mgr.activeToasts.map(\.message) == [DocumentEditorView.purgeRerunToastMessage])
        mgr.documentPhaseDidChange(to: .editing)
        #expect(mgr.activeToasts.isEmpty, "the Re-run ends when the editor returns")
        #expect(mgr.documentPhase == .editing)
    }

    @Test("A phase other than editing withdraws every action that changes state")
    func otherPhaseWithdrawsActions() {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        mgr.documentPhaseDidChange(to: .editing)
        // Built directly: true in every phase, so only the action withdraws them.
        mgr.enqueue(ToastItem(message: "Cleared 2 matches.", severity: .info, actionLabel: "Undo", actionHandler: {}))
        mgr.enqueue(ToastItem(message: "1 match nearby.", severity: .info, actionLabel: "Mark", actionHandler: {}))
        mgr.enqueue(ToastItem(message: "Saved", severity: .info))
        mgr.documentPhaseDidChange(to: .verifying)
        #expect(mgr.activeToasts.isEmpty, "the shown action is withdrawn")
        #expect(mgr.waitingToasts.map(\.message) == ["Saved"], "the waiting action is withdrawn; the rest stays")
        clock.advance(0.5)
        mgr.settleClocks()
        #expect(mgr.activeToasts.map(\.message) == ["Saved"])
    }

    // MARK: - Holds

    @Test("A hold stops the clock and holds new messages")
    func holdStopsTheClock() throws {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        let dialog = UUID()
        mgr.post(.marked(applied: 3, alreadyCovered: 0))
        let marked = try #require(mgr.activeToasts.first)
        clock.advance(1)
        mgr.setHold(dialog, true)
        mgr.setHold(dialog, true)
        #expect(mgr.receipt(drawnBy: UUID()) == nil, "not drawn under the dialog")
        #expect(mgr.receiptClock(of: marked.id)?.isRunning == false)
        mgr.post(.deletedBoxes(count: 2), action: {})
        clock.advance(30)
        mgr.settleClocks()
        #expect(mgr.activeToasts.map(\.id) == [marked.id], "nothing new is shown")
        #expect(mgr.waitingToasts.map(\.message) == ["Deleted 2 regions."], "it waits, and is not dropped")
        mgr.setHold(dialog, false)
        #expect(mgr.receiptClock(of: marked.id)?.remaining(at: clock.now) == 5.0)
        clock.advance(0.5)
        mgr.settleClocks()
        let undo = try #require(mgr.activeToasts.first)
        #expect(undo.message == "Deleted 2 regions.", "once released the plain one gives way at 1.5 s")

        // A finger on the receipt stops its clock too.
        mgr.holdClock(undo.id, .touch, true)
        clock.advance(20)
        mgr.settleClocks()
        #expect(mgr.receiptClock(of: undo.id)?.remaining(at: clock.now) == 8.0)
        mgr.holdClock(undo.id, .touch, false)
        clock.advance(8)
        mgr.settleClocks()
        #expect(mgr.activeToasts.isEmpty)
    }

    @Test("With VoiceOver running a receipt with an action waits for focus only under a registered layer")
    func voiceOverWaitsForFocusUnderALayer() throws {
        // No layer registered: it leaves on its clock.
        let clock = QueueTestClock()
        let free = queue(clock)
        free.voiceOverRunning = { true }
        free.post(.deletedBoxes(count: 2), action: {})
        let first = try #require(free.activeToasts.first)
        #expect(free.receiptClock(of: first.id)?.isRunning == true)
        clock.advance(8)
        free.settleClocks()
        #expect(free.activeToasts.isEmpty, "with no layer registered it leaves on its clock")

        // A registered layer draws it: it stays until it has had focus once,
        // then it has what is left of its life. Switch Control alone waits too.
        for (voiceOver, switchControl) in [(true, false), (false, true)] {
            let held = queue(clock)
            held.voiceOverRunning = { voiceOver }
            held.switchControlRunning = { switchControl }
            held.registerLayer(UUID(), role: .root)
            held.post(.deletedBoxes(count: 3), action: {})
            let undo = try #require(held.activeToasts.first)
            #expect(held.receiptClock(of: undo.id)?.isRunning == false)
            clock.advance(60)
            held.settleClocks()
            #expect(held.activeToasts.map(\.id) == [undo.id], "it stays until it has had focus once")
            held.noteFocused(undo.id)
            #expect(held.receiptClock(of: undo.id)?.remaining(at: clock.now) == 8.0)
            clock.advance(8)
            held.settleClocks()
            #expect(held.activeToasts.isEmpty)
        }
    }

    @Test("A plain message that waited over 10 s is dropped at its turn; one that waited less is shown")
    func plainWaitLimitAtItsTurn() throws {
        let clock = QueueTestClock()
        for (heldFor, shown) in [(0.0, ["All good"]), (11.0, [])] {
            let mgr = queue(clock)
            mgr.post(.deletedBoxes(count: 2), action: {})
            let undo = try #require(mgr.activeToasts.first)
            mgr.holdClock(undo.id, .touch, true)
            mgr.enqueue(ToastItem(message: "All good", severity: .success))
            clock.advance(heldFor)
            mgr.settleClocks()
            mgr.holdClock(undo.id, .touch, false)
            clock.advance(8)
            mgr.settleClocks()
            #expect(mgr.waitingToasts.map(\.message) == ["All good"], "it waits through the gap")
            clock.advance(0.3)
            mgr.settleClocks()
            #expect(mgr.activeToasts.map(\.message) == shown, "waited \(heldFor + 8.3) s")
            #expect(mgr.waitingToasts.isEmpty)
        }
    }

    // MARK: - The slot

    @Test("No receipt is at the slot's place until a root layer draws one")
    func slotNeedsARootLayer() {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        mgr.post(.deletedBoxes(count: 2), action: {})
        #expect(!mgr.receiptAtSlot)
        #expect(mgr.receiptAtSlotSince == nil)
        clock.advance(1)
        mgr.registerLayer(UUID(), role: .root)
        #expect(mgr.receiptAtSlot)
        #expect(mgr.receiptAtSlotSince == clock.now)
        let search = UUID()
        mgr.registerLayer(search, role: .draws)
        #expect(!mgr.receiptAtSlot, "paused under Search")
        clock.advance(0.5)
        mgr.settleClocks()
        mgr.post(.shared)
        #expect(mgr.activeToasts.map(\.message) == ["Shared."])
        #expect(!mgr.receiptAtSlot, "a receipt in Search is not at the editor's slot")
        #expect(mgr.receiptAtSlotSince == nil)
    }

    @Test("Yielding the slot to a selection ends the receipt there")
    func yieldingTheSlot() {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        mgr.registerLayer(UUID(), role: .root)
        mgr.post(.deletedBoxes(count: 2), action: {})
        #expect(mgr.receiptAtSlot)
        mgr.yieldSlotToSelection()
        #expect(mgr.activeToasts.isEmpty)
        #expect(!mgr.receiptAtSlot)
        mgr.registerLayer(UUID(), role: .draws)
        clock.advance(0.5)
        mgr.settleClocks()
        mgr.post(.deletedBoxes(count: 3), action: {})
        mgr.yieldSlotToSelection()
        #expect(mgr.activeToasts.count == 1, "a receipt in a sheet is not at the slot")
    }

    // MARK: - Announcements

    @Test("Announcements are spoken one after another")
    func announcementsOneAfterAnother() throws {
        let clock = QueueTestClock()
        let spoken = QueueTestRecord()
        let mgr = queue(clock, spoken: spoken)
        mgr.announce("One")
        mgr.announce("Two")
        #expect(spoken.lines == ["One"], "the second waits for the first")
        mgr.announcementDidFinish("Another line")
        #expect(spoken.lines == ["One"], "another announcement's end does not count")
        mgr.announcementDidFinish("One")
        #expect(spoken.lines == ["One", "Two"])
        mgr.announce("Three")
        clock.advance(2)
        mgr.settleClocks()
        #expect(spoken.lines == ["One", "Two"])
        clock.advance(1)
        mgr.settleClocks()
        #expect(spoken.lines == ["One", "Two", "Three"], "after 3 s with no end reported, the next is spoken")
        mgr.announcementDidFinish("Three")
        // A shown message is announced once, by its own words, through the same queue.
        mgr.post(.shared)
        #expect(spoken.lines.last == "Shared.")
        #expect(spoken.lines.filter { $0 == "Shared." }.count == 1)
        // The queue's file posts an announcement in one place: its poster.
        let source = try loadRepoFile("Sources/ResectaApp/State/ToastQueueManager.swift")
        #expect(source.components(separatedBy: "AccessibilityNotification.Announcement(").count - 1 == 1)
        #expect(!source.contains("UIAccessibility.post("))
    }

    // MARK: - The review request

    @Test("The review request waits for the shared message to leave")
    func reviewRequestWaitsForShared() throws {
        let clock = QueueTestClock()
        let mgr = queue(clock)
        let ran = QueueTestRecord()
        mgr.whenGone(.shared) { ran.count += 1 }
        #expect(ran.count == 1, "with no Shared. up it runs at once")
        mgr.post(.shared)
        mgr.whenGone(.shared) { ran.count += 1 }
        #expect(ran.count == 1)
        clock.advance(2.5)
        mgr.settleClocks()
        #expect(mgr.activeToasts.isEmpty)
        #expect(ran.count == 2, "it runs once the message has left")

        clock.advance(0.5)
        mgr.settleClocks()
        mgr.post(.deletedBoxes(count: 2), action: {})
        let undo = try #require(mgr.activeToasts.first)
        mgr.post(.shared)
        mgr.whenGone(.shared) { ran.count += 1 }
        mgr.dismiss(undo)
        #expect(ran.count == 2, "a waiting Shared. counts")
        clock.advance(0.5)
        mgr.settleClocks()
        #expect(mgr.activeToasts.map(\.message) == ["Shared."])
        clock.advance(2.5)
        mgr.settleClocks()
        #expect(ran.count == 3)
    }

    /// Mirrors `HonestySurfacesTests.loadRepoFile` — reads a repo-relative
    /// source file from disk so the pin above scans real shipped source,
    /// not a copy-pasted string.
    private func loadRepoFile(
        _ relativePath: String, from file: StaticString = #filePath
    ) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    @Test("The Marked notice with a covered count keeps its Redact clause short")
    func markedMessageCoveredFormIsShort() {
        #expect(CommitFeedback.markedMessage(applied: 19, alreadyCovered: 9)
                == "Marked 19 (9 already covered). Not redacted until you tap Redact.")
        #expect(CommitFeedback.markedMessage(applied: 3)
                == "Marked 3 for redaction. Not redacted until you tap Redact.")
    }

    @Test("The Marked notice reports an all-covered apply and stays silent on a no-op")
    func markedMessageAllCoveredAndNoOp() {
        // Nothing new appeared, so the notice says why.
        #expect(CommitFeedback.markedMessage(applied: 0, alreadyCovered: 4)
                == "Marked 0 (4 already covered). Not redacted until you tap Redact.")
        // Nothing created and nothing skipped: no toast at all.
        #expect(CommitFeedback.markedMessage(applied: 0) == nil)
    }
}
