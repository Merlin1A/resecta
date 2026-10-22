import Testing
@testable import ResectaApp

// The custom-term time-limit toast is shown once for a scan: a latch on the
// scan, not the toast queue's coalescing (which lasts only while the first
// toast is on screen or queued).

@Suite("Custom-term time-limit toast: once per scan", .tags(.search))
@MainActor
struct CustomTermTimeoutToastTests {

    @Test("The latch fires once")
    func latchFiresOnce() {
        let latch = SearchAndRedactSheet.ScanOnceLatch()
        #expect(latch.fire())
        #expect(!latch.fire())
        #expect(!latch.fire())
        #expect(SearchAndRedactSheet.ScanOnceLatch().fire(), "a new scan's latch is fresh")
    }

    @Test("A page that runs out after the first toast has left the screen adds no second toast")
    func noSecondToastAfterTheFirstLeft() {
        let toasts = ToastQueueManager()
        let latch = SearchAndRedactSheet.ScanOnceLatch()
        func pageRanOut() {
            guard latch.fire() else { return }
            toasts.enqueue(SearchAndRedactSheet.customTermTimeoutMessage, severity: .warning)
        }
        pageRanOut()
        #expect(toasts.activeToasts.map(\.message) == [SearchAndRedactSheet.customTermTimeoutMessage])
        toasts.clearAll()
        #expect(toasts.activeToasts.isEmpty)
        pageRanOut()
        #expect(toasts.activeToasts.isEmpty, "the queue would have shown it again; the latch does not")
    }
}
