import CoreGraphics
import Foundation
import PDFKit

// A search reads a gated page's tokens by awaiting them, never by blocking a
// task thread on the ink-fit lane (`DocumentSearcher+InkFit.swift`): searches
// that blocked their threads on the lane while Vision's text recognitions
// waited on threads of their own were seen to stall together: Vision finishes
// a text recognition on the task pool, so a pool whose threads all wait never
// lets one end. The page is drawn on a dispatch thread and read on the lane;
// the fits that follow read the tokens from the cache (a fit on a task thread
// never reads, `fit`). A page that is not gated never waits.

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
final class InkFitContinuation: @unchecked Sendable {
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
    /// envelope (degraded, and shown as such: no longer deferred); no
    /// thread waits on the lane.
    func withInkFitRead<T>(_ page: PDFPage, _ body: () -> T) async -> T {
        guard let read = Self.pendingInkRead(page) else { return body() }
        let deferral = InkFitDeferral()
        let first = InkFitDeferral.$current.withValue(deferral) { body() }
        guard deferral.wanted else { return first }
        await read.run()
        // A cancelled search keeps its first run (the envelopes); it is not emitted.
        if Task.isCancelled { return first }
        return body()
    }

    /// The page, its tokens read first when it is gated (for matching that
    /// reports as it goes and cannot run twice).
    func preparedForInkFit(_ page: PDFPage) async -> SendablePDFPage {
        if let read = Self.pendingInkRead(page) { await read.run() }
        return SendablePDFPage(page)
    }

    /// `value`, after the page's tokens are read when it is gated.
    func afterInkFitRead<T>(_ page: PDFPage, _ value: @autoclosure () async -> T) async -> T {
        if let read = Self.pendingInkRead(page) { await read.run() }
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

/// The reads in flight, by read key (`inkFitReadKey`: the page's content,
/// its image and box, and the read's script): a search of a page already
/// being read awaits that read rather than queuing another for the same
/// tokens. Each waiter keeps its own cancellation and backstop; a read in
/// flight past the backstop (its draw never returned) is not joined, so a
/// later search starts a read of its own (which skips the hung draw).
final class InkFitReadJoin: @unchecked Sendable {
    static let shared = InkFitReadJoin()
    private let lock = NSLock()
    private var waiting: [Int: (started: Date, boxes: [InkFitContinuation])] = [:]
    /// Adds `box` to the read of `key`: true when none was in flight (the caller starts it).
    func join(_ key: Int, _ box: InkFitContinuation) -> Bool {
        lock.withLock {
            let first = waiting[key].map { Date().timeIntervalSince($0.started) > DocumentSearcher.inkFitReadBackstop } ?? true
            if first { waiting[key] = (Date(), [box]) } else { waiting[key]?.boxes.append(box) }
            #if DEBUG
            if first { started[key, default: 0] += 1 }
            #endif
            return first
        }
    }
    #if DEBUG
    /// Test seam: how many reads of `key` were started (joins not counted).
    private var started: [Int: Int] = [:]
    func startedCount(_ key: Int) -> Int { lock.withLock { started[key] ?? 0 } }
    #endif
    /// The read of `key` ended: every waiter on it gets its tokens (nil on a miss).
    func finish(_ key: Int, _ tokens: [DocumentSearcher.InkToken]?) {
        let boxes = lock.withLock { waiting.removeValue(forKey: key)?.boxes ?? [] }
        for box in boxes { box.resume(tokens) }
    }
}

/// A few long-lived threads that run the page reads (each read's draw, and
/// its wait on the Vision lane), off every dispatch and task queue: a busy
/// global queue never delays a read's start, and a stalled read holds one of
/// them while the others go on. Each read waits on the serial Vision lane
/// on its thread, so there are enough of them for the reads of busy runs to
/// wait side by side, and a few page draws at a time (`draws`: the read's
/// full-page draw is its memory). A draw that never returns holds its thread
/// for good: once every thread is held by a draw (or a wait for one) running
/// past `hungAfter`, a new read is refused at once (its fits take the
/// envelope) instead of queuing behind them.
final class InkFitReadThreads: @unchecked Sendable {
    static let shared = InkFitReadThreads(count: 16, draws: 4, hungAfter: DocumentSearcher.inkFitTimeout)
    private static let numberKey = "com.resecta.search.inkfit.read"
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var idle = 0
    private var drawingSince: [Int: Date] = [:]
    /// When each held draw slot was taken, by thread.
    private var slotSince: [Int: Date] = [:]
    private let count: Int, hungAfter: TimeInterval
    private let drawSlots: DispatchSemaphore, drawLimit: Int
    init(count: Int, draws: Int? = nil, hungAfter: TimeInterval) {
        self.count = count; self.hungAfter = hungAfter
        drawLimit = draws ?? count
        drawSlots = DispatchSemaphore(value: drawLimit)
        for number in 0..<count {
            let thread = Thread { [unowned self] in self.serve(number) }
            thread.name = "\(Self.numberKey).\(number)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
    /// `job` on a read thread; false (and nothing runs) when no thread is
    /// free and each is held by a draw running past `hungAfter`, or every
    /// draw slot is.
    func submit(_ job: @escaping () -> Void) -> Bool {
        condition.lock(); defer { condition.unlock() }
        if slotsHung { return false }
        if idle == 0, drawingSince.count == count,
           drawingSince.values.allSatisfy({ Date().timeIntervalSince($0) > hungAfter }) { return false }
        jobs.append(job); condition.signal()
        return true
    }
    /// Every draw slot held by a draw running past `hungAfter` (the lock held).
    private var slotsHung: Bool {
        slotSince.count == drawLimit && slotSince.values.allSatisfy { Date().timeIntervalSince($0) > hungAfter }
    }
    /// `work` (a read's draw), noted while it runs on one of these threads;
    /// nil, with nothing drawn, when no draw slot comes free within
    /// `hungAfter` (or every slot is held by a draw past it).
    func drawing<T>(_ work: () -> T) -> T? {
        guard let number = Thread.current.threadDictionary[Self.numberKey] as? Int else { return work() }
        condition.lock()
        if slotsHung { condition.unlock(); return nil }
        drawingSince[number] = Date()
        condition.unlock()
        defer { condition.lock(); drawingSince[number] = nil; condition.unlock() }
        guard drawSlots.wait(timeout: .now() + hungAfter) == .success else { return nil }
        condition.lock(); slotSince[number] = Date(); condition.unlock()
        defer { condition.lock(); slotSince[number] = nil; condition.unlock(); drawSlots.signal() }
        return work()
    }
    private func serve(_ number: Int) {
        Thread.current.threadDictionary[Self.numberKey] = number
        while true {
            condition.lock()
            idle += 1
            while jobs.isEmpty { condition.wait() }
            idle -= 1
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }
}

extension DocumentSearcher {
    /// The longest a search awaits a page read before its fits take the
    /// envelope: a backstop above the read's own bounds (the draw lock's
    /// wait, `inkFitWaitCeiling` behind reads that move, and `inkFitTimeout`
    /// once the read is at the Vision lane's head, where a stalled one is
    /// retired at its limit).
    static let inkFitReadBackstop: TimeInterval = inkFitTimeout + inkFitWaitCeiling + inkFitTimeout

    /// The read backstop's timer, on a queue of its own.
    static let inkFitReadTimers = DispatchQueue(label: "com.resecta.search.inkfit.read-timers", qos: .utility)
}

extension InkFitPendingRead {
    /// Reads the page (drawn and waited for on an ink-fit read thread, read
    /// on the Vision lane), never on a task thread: Vision's text recognition
    /// finishes its work on the task pool, so a pool whose threads all wait
    /// (on Vision, or on the lane) never lets a read end. A read of the same
    /// page already in flight is joined. The read's time limit counts from
    /// when it reaches the Vision lane's head (`onInkFitQueue`); the search
    /// waits at most `inkFitReadBackstop`. Nothing is cached on a miss.
    func run() async {
        if InkTokenCache.shared.value(for: key) != nil { return }
        guard !Task.isCancelled else { return }
        let read = self
        let box = InkFitContinuation()
        // A cancelled search stops waiting at once, queued or joined (the
        // read, if it runs, ends on its lane and is cached for the next search).
        let tokens: [DocumentSearcher.InkToken]? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.set(continuation)
                if InkFitReadJoin.shared.join(read.key, box) {
                    let submitted = InkFitReadThreads.shared.submit {
                        let result = DocumentSearcher.readTokens(read.page.page, rotation: read.rotation, visual: read.visual,
                                                                 key: read.key, languages: read.languages, frame: read.frame)
                        if let result { InkTokenCache.shared.set(result, for: read.key) }
                        InkFitReadJoin.shared.finish(read.key, result)
                    }
                    // Every read thread held by a draw that never returned: no read.
                    if !submitted {
                        DocumentSearcher.inkFitLogger.log("ink fit: every read thread is held by a draw that has not returned; no read")
                        InkFitReadJoin.shared.finish(read.key, nil)
                    }
                }
                DocumentSearcher.inkFitReadTimers.asyncAfter(deadline: .now() + DocumentSearcher.inkFitReadBackstop) {
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
