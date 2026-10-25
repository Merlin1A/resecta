import CoreGraphics
import Foundation
import PDFKit

// A search reads a gated page's tokens by awaiting them, never by blocking a
// task thread on the ink-fit lane (`DocumentSearcher+InkFit.swift`): searches
// that blocked their threads on the lane while Vision's text recognitions
// waited on threads of their own were seen to stall together: Vision finishes
// a text recognition on the task pool, so a pool whose threads all wait never
// lets one end. The page is drawn and read on the lane, handed over from a
// dispatch thread; the fits that follow read the tokens from the cache. A page that
// is not gated never waits.

/// Set while a search's matching runs before its page was read: a fit that
/// has no tokens returns the envelope at once and notes the read wanted.
final class InkFitDeferral: @unchecked Sendable {
    @TaskLocal static var current: InkFitDeferral?
    private let lock = NSLock()
    private var wantedRead = false
    var wanted: Bool { lock.withLock { wantedRead } }
    func want() { lock.withLock { wantedRead = true } }
}

/// A read a gated page still needs, with all it takes from the page.
struct InkFitPendingRead: @unchecked Sendable {
    let key: Int
    let page: InkFitPage
    let rotation: Int
    let visual: CGSize
    let frame: InkFitFrame
    let languages: [String]?
}

/// The awaited read's continuation, resumed once by the first answer (the
/// read, the timeout or a cancellation), even one that comes before it is set.
private final class InkFitContinuation: @unchecked Sendable {
    typealias Value = [DocumentSearcher.InkToken]?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var hasEarly = false
    private var early: Value = nil
    private var done = false
    func set(_ c: CheckedContinuation<Value, Never>) {
        let (now, value): (Bool, Value) = lock.withLock {
            if hasEarly { done = true; return (true, early) }
            continuation = c
            return (false, nil)
        }
        if now { c.resume(returning: value) }
    }
    func resume(_ value: Value) {
        let waiting: CheckedContinuation<Value, Never>? = lock.withLock {
            guard !done else { return nil }
            guard let c = continuation else {
                if !hasEarly { hasEarly = true; early = value }
                return nil
            }
            done = true; continuation = nil
            return c
        }
        waiting?.resume(returning: value)
    }
}


extension DocumentSearcher {

    /// `body` (a page's matching, free of other effects) with the page's
    /// tokens read first when a fit in it wants them: run once with fits
    /// deferred; when one wanted the read, the read is awaited and `body`
    /// runs again. Without a read in time the second run's fits are the
    /// envelope (degraded); no thread waits on the lane.
    func withInkFitRead<T>(_ page: PDFPage, _ body: () -> T) async -> T {
        defer { reportInterleavedLines(page) }
        guard let read = Self.pendingInkRead(page) else { return body() }
        let deferral = InkFitDeferral()
        let first = InkFitDeferral.$current.withValue(deferral) { body() }
        guard deferral.wanted else { return first }
        await read.run()
        // A cancelled search keeps its first run (the envelopes); it is not emitted.
        if Task.isCancelled { return first }
        return InkFitDeferral.$current.withValue(InkFitDeferral()) { body() }
    }

    /// The page, its tokens read first when it is gated (for matching that
    /// reports as it goes and cannot run twice).
    func preparedForInkFit(_ page: PDFPage) async -> SendablePDFPage {
        if let read = Self.pendingInkRead(page) { await read.run() }
        reportInterleavedLines(page)
        return SendablePDFPage(page)
    }

    /// `value`, after the page's tokens are read when it is gated.
    func afterInkFitRead<T>(_ page: PDFPage, _ value: @autoclosure () async -> T) async -> T {
        if let read = Self.pendingInkRead(page) { await read.run() }
        reportInterleavedLines(page)
        return await value()
    }

    /// The read `page` still needs: nil when it is not gated, its tokens are
    /// cached, or it has no private copy to draw from (the fits fall back).
    nonisolated static func pendingInkRead(_ page: PDFPage) -> InkFitPendingRead? {
        guard !Thread.isMainThread, let cgPage = page.pageRef, carriesHiddenTextOverImage(page, cgPage: cgPage) else { return nil }
        let visual = effectiveBounds(page.bounds(for: .cropBox), rotation: page.rotation).size
        guard visual.width > 0, visual.height > 0 else { return nil }
        let key = InkTokenCache.key(page: page, cgPage: cgPage, visual: visual)
        guard InkTokenCache.shared.value(for: key) == nil,
              let document = page.document, case let index = document.index(for: page), index != NSNotFound,
              let privatePage = PrivatePDFCopies.shared.copy(of: document)?.page(at: index + 1) else { return nil }
        return InkFitPendingRead(key: key, page: InkFitPage(privatePage), rotation: page.rotation, visual: visual,
                                 frame: readingFrame(of: page, visual: visual), languages: inkFitLanguages(for: page.string ?? ""))
    }
}

extension InkFitPendingRead {
    /// Reads the page on the ink-fit lane (drawn and read there, as a fit
    /// reads it), handed over from a dispatch thread, never a task thread:
    /// Vision's text recognition finishes its work on the task pool, so a
    /// pool whose threads all wait (on Vision, or on the lane) never lets a
    /// read end. Waited for within `inkFitTimeout`; nothing is cached on a miss.
    func run() async {
        if InkTokenCache.shared.value(for: key) != nil { return }
        guard !Task.isCancelled else { return }
        let read = self
        let box = InkFitContinuation()
        // A cancelled search stops waiting at once (the read, if it runs, ends
        // on its lane and is cached for the next search).
        let tokens: [DocumentSearcher.InkToken]? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.set(continuation)
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = DocumentSearcher.readTokens(read.page.page, rotation: read.rotation, visual: read.visual,
                                                             key: read.key, languages: read.languages, frame: read.frame)
                    if let result { InkTokenCache.shared.set(result, for: read.key) }
                    box.resume(result)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + DocumentSearcher.inkFitTimeout) {
                    box.resume(nil)
                }
            }
        } onCancel: {
            box.resume(nil)
        }
        guard let tokens else {
            DocumentSearcher.inkFitLogger.log("ink fit: a page read did not finish in time; its fits are the drift envelope")
            return
        }
        InkTokenCache.shared.set(tokens, for: key)
    }
}

extension DocumentSearcher {
    /// A gated page's tokens read ahead by awaiting them, for a caller that
    /// fits outside a search (it would otherwise wait on the lane).
    nonisolated static func prepareInkFit(_ page: PDFPage) async {
        if let read = pendingInkRead(page) { await read.run() }
    }
}

extension DocumentSearcher {
    /// Vision's tokens as the fit reads them: their boxes in points of a
    /// page (or reading frame) of `size`, their alignment keys, and for each
    /// key letter its character in the token as read.
    nonisolated static func inkTokens(from read: [OCREngine.Token], size: CGSize) -> [InkToken] {
        read.map { t in
            var keyToRaw: [Int] = []
            // One entry per key letter: a ligature read as one character
            // gives its key several letters.
            for (index, character) in t.text.enumerated() {
                keyToRaw += Array(repeating: index, count: alignmentKey(Substring(String(character))).count)
            }
            return InkToken(key: alignmentKey(Substring(t.text)),
                            rect: CGRect(x: t.normalizedRect.minX * size.width, y: t.normalizedRect.minY * size.height,
                                         width: t.normalizedRect.width * size.width, height: t.normalizedRect.height * size.height),
                            line: t.line, raw: t.text, keyToRaw: keyToRaw)
        }
    }
}
