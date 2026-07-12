import Testing
import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

@Suite("DocumentSearcher cancellation", .tags(.search))
struct DocumentSearcherCancellationTests {

    @Test("Cancelling a search lets a second search start and complete")
    func cancelThenRestartCompletes() async throws {
        let data = multiPageTextPDF(
            pageCount: 25,
            text: "The quick brown fox jumps over the lazy dog. SSN 123-45-6789."
        )
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }
        let sendable = SendablePDFDocument(doc)
        let searcher = DocumentSearcher()

        let firstTask = Task {
            let stream = searcher.search(
                sendable,
                mode: .text("fox", options: SearchOptions()),
                progress: { _, _ in }
            )
            var collected: [SearchResult] = []
            for await result in stream {
                collected.append(result)
                if collected.count == 1 { break }
            }
            return collected.count
        }
        // Give the first task a moment to start producing.
        try await Task.sleep(for: .milliseconds(20))
        firstTask.cancel()
        _ = await firstTask.value

        let secondStream = searcher.search(
            sendable,
            mode: .text("fox", options: SearchOptions()),
            progress: { _, _ in }
        )
        var secondCount = 0
        for await _ in secondStream { secondCount += 1 }

        #expect(secondCount >= 25)
    }

    @Test("Sinks set after a cancelled search apply to the next run")
    func sinksReinstalledAfterCancel() async throws {
        let data = multiPageTextPDF(
            pageCount: 10,
            text: "Sensitive personal data — confidential."
        )
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }
        let sendable = SendablePDFDocument(doc)
        let searcher = DocumentSearcher()

        // Install a sink, kick off a scan, cancel mid-stream. The actor
        // should accept the next `setOverlapSink` call promptly.
        await searcher.setOverlapSink({ _ in })

        let firstTask = Task {
            let stream = searcher.search(
                sendable,
                mode: .text("personal", options: SearchOptions()),
                progress: { _, _ in }
            )
            for await _ in stream { }
        }
        try await Task.sleep(for: .milliseconds(15))
        firstTask.cancel()

        // Re-install sinks while the cancellation is still settling.
        // The actor entry should drain within a single page boundary.
        let start = ContinuousClock.now
        await searcher.setOverlapSink(nil)
        await searcher.setRegexTimeoutSink(nil)
        let elapsed = ContinuousClock.now - start

        _ = await firstTask.value
        #expect(elapsed < .seconds(2), "Sink setter took \(elapsed) after cancel")
    }

    @Test("Ten rapid cancel-restart cycles leave the searcher healthy")
    func tenRapidCancelRestartCycles() async throws {
        let data = multiPageTextPDF(
            pageCount: 20,
            text: "Quick fox. More fox content here. Fox again."
        )
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }
        let sendable = SendablePDFDocument(doc)
        let searcher = DocumentSearcher()

        for _ in 0..<10 {
            let task = Task {
                let stream = searcher.search(
                    sendable,
                    mode: .text("fox", options: SearchOptions()),
                    progress: { _, _ in }
                )
                for await _ in stream { }
            }
            try? await Task.sleep(for: .milliseconds(5))
            task.cancel()
            _ = await task.value
        }

        // Final pass without cancellation — the searcher must still produce
        // a complete result set, proving no leaked state from prior runs.
        let stream = searcher.search(
            sendable,
            mode: .text("fox", options: SearchOptions()),
            progress: { _, _ in }
        )
        var count = 0
        for await _ in stream { count += 1 }

        #expect(count >= 20)
    }

    // MARK: - Helpers

    private func multiPageTextPDF(pageCount: Int, text: String) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            for _ in 0..<pageCount {
                context.beginPage()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: UIColor.black
                ]
                (text as NSString).draw(
                    in: CGRect(x: 72, y: 72, width: 468, height: 648),
                    withAttributes: attrs
                )
            }
        }
    }
}
