import Testing
import Foundation
@testable import ResectaApp

// When the layer a message belongs to leaves: a message that must be seen
// and was never shown is handed on and drawn where the person is now; a
// shown one ends with its layer. A test moves a clock of its own and asks
// the queue to settle.

/// A clock a test moves by hand.
private final class LayerLeavingClock {
    var now = ContinuousClock.now
    func advance(_ seconds: Double) { now = now.advanced(by: .seconds(seconds)) }
}

@Suite("Queue: a layer leaving")
@MainActor
struct ToastQueueLayerLeavingTests {

    /// A queue on the test's clock, with VoiceOver and Switch Control off
    /// and nothing spoken.
    private func queue(_ clock: LayerLeavingClock) -> ToastQueueManager {
        let mgr = ToastQueueManager()
        mgr.now = { clock.now }
        mgr.voiceOverRunning = { false }
        mgr.switchControlRunning = { false }
        mgr.postAnnouncement = { _ in }
        return mgr
    }

    @Test("A run's warning that must be seen and was never shown outlives the sheet that ran it, and is drawn on the editor")
    func unseenRunWarningOutlivesItsSheet() throws {
        let clock = LayerLeavingClock()
        let mgr = queue(clock)
        let root = UUID(), search = UUID(), saved = UUID()
        mgr.registerLayer(root, role: .root)
        mgr.registerLayer(search, role: .draws)
        mgr.registerLayer(saved, role: .draws)
        // A recall from the saved list drops unapplied matches: that message
        // belongs to Search, the layer that remains.
        mgr.post(.recallCleared(count: 2))
        mgr.unregisterLayer(saved)
        let cleared = try #require(mgr.activeToasts.first)
        #expect(cleared.message == "Recall cleared 2 unapplied matches.")
        #expect(mgr.receipt(drawnBy: search)?.id == cleared.id)
        // The recalled run's warning waits behind it, bound to Search.
        mgr.post(.scannedRegionsNotAnalyzed, runLayer: search)
        #expect(mgr.waitingToasts.count == 1)
        // The person closes Search: the shown message ends with its sheet;
        // the one never shown is handed on and drawn on the editor.
        mgr.unregisterLayer(search)
        clock.advance(1.0)
        mgr.settleClocks()
        let warning = try #require(mgr.activeToasts.first, "the unseen warning ended with Search")
        #expect(warning.message == MessageCatalog.row(for: .scannedRegionsNotAnalyzed).text)
        #expect(warning.id != cleared.id)
        #expect(mgr.receipt(drawnBy: root)?.id == warning.id)
    }

    @Test("A plain message waiting on a layer that leaves ends with it")
    func plainWaitingMessageEndsWithItsLayer() throws {
        let clock = LayerLeavingClock()
        let mgr = queue(clock)
        let root = UUID(), search = UUID()
        mgr.registerLayer(root, role: .root)
        mgr.registerLayer(search, role: .draws)
        // Shown on Search and must be seen, so the next one waits.
        mgr.post(.scannedRegionsNotAnalyzed, runLayer: search)
        #expect(mgr.activeToasts.count == 1)
        let plain = try #require(MessageID.examples.first {
            let row = MessageCatalog.row(for: $0)
            return !row.mustBeSeen
        })
        mgr.post(plain, runLayer: search)
        #expect(mgr.waitingToasts.count == 1)
        mgr.unregisterLayer(search)
        clock.advance(1.0)
        mgr.settleClocks()
        #expect(mgr.activeToasts.isEmpty, "a plain message bound to the leaving layer ended")
        #expect(mgr.waitingToasts.isEmpty)
    }
}
