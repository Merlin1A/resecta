import CoreGraphics
import Foundation
import PDFKit
import PDFKitGuard

// The ink fit's caches and queue state (`DocumentSearcher+InkFit.swift`).

/// One serial queue for the ink fit's page reads (Vision), and the job at its
/// head: its page content key, how long it may run, and when it started.
final class InkFitLane: @unchecked Sendable {
    /// Set on every lane's queue: a job already on a lane runs nested work inline.
    static let tag = DispatchSpecificKey<Bool>()
    let queue: DispatchQueue
    private let lock = NSLock()
    private var head: (key: Int?, limit: TimeInterval, started: Date)?
    init(number: Int, label: String) {
        queue = DispatchQueue(label: "com.resecta.search.inkfit.\(label).\(number)", qos: .userInitiated)
        queue.setSpecific(key: Self.tag, value: true)
    }
    func began(key: Int?, limit: TimeInterval) {
        lock.lock(); head = (key, limit, Date()); lock.unlock()
    }
    func ended() { lock.lock(); head = nil; lock.unlock() }
    /// The head job, when it has run past its own limit: its page key (may
    /// be nil) and that limit.
    func overrun() -> (key: Int?, limit: TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        guard let head, Date().timeIntervalSince(head.started) > head.limit else { return nil }
        return (head.key, head.limit)
    }
}

/// The ink fit's current lane, and the lanes whose head job ran past its
/// limit and still holds them. A hung job marks only its own page stuck:
/// later jobs move to a fresh lane, so one stalled page leaves the others
/// fitting. Past `hungLaneCap` lanes hung at once, every fit answers at once
/// (hung page reads are not left to pile up).
final class InkFitQueueState: @unchecked Sendable {
    /// The Vision lanes (page reads, drawing nothing). The renders run on
    /// their caller's thread (`InkFitDrawLock`).
    static let vision = InkFitQueueState(label: "vision")
    private let label: String
    init(label: String) { self.label = label; lane = InkFitLane(number: 0, label: label) }
    static let hungLaneCap = 2
    private let lock = NSLock()
    private var made = 0
    private var lane: InkFitLane
    private var hung: [ObjectIdentifier: Int?] = [:]
    var current: InkFitLane { lock.lock(); defer { lock.unlock() }; return lane }
    /// Whether a job for `key` answers at once: that page's job holds a hung
    /// lane, or too many lanes hang.
    func isStuck(key: Int?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return hung.count >= Self.hungLaneCap || (key != nil && hung.values.contains { $0 == key })
    }
    /// `old`'s head job (page `key`) ran past its limit: later jobs go to a
    /// fresh lane.
    func retire(_ old: InkFitLane, key: Int?) {
        lock.lock(); defer { lock.unlock() }
        guard hung[ObjectIdentifier(old)] == nil else { return }
        hung[ObjectIdentifier(old)] = .some(key)
        if old === lane { made += 1; lane = InkFitLane(number: made, label: label) }
    }
    /// A job on `lane` ended: a hung lane's job ending frees its page.
    func ended(on lane: InkFitLane) {
        lock.lock(); hung[ObjectIdentifier(lane)] = nil; lock.unlock()
    }
}

#if DEBUG
/// Test seam: when a key's read reached the Vision lane's head, and when
/// its lane was retired under it (the latest of each).
final class InkFitLaneTimes: @unchecked Sendable {
    static let shared = InkFitLaneTimes()
    private let lock = NSLock()
    private var began: [Int: Date] = [:], retired: [Int: Date] = [:]
    func didBegin(_ key: Int?) { guard let key else { return }; lock.withLock { began[key] = Date() } }
    func didRetire(_ key: Int?) { guard let key else { return }; lock.withLock { retired[key] = Date() } }
    func began(_ key: Int) -> Date? { lock.withLock { began[key] } }
    func retired(_ key: Int) -> Date? { lock.withLock { retired[key] } }
}

/// The test seam's stalls, by page content key.
final class InkFitStalls: @unchecked Sendable {
    private let lock = NSLock()
    private var stalls: [Int: (stall: TimeInterval, timeout: TimeInterval)] = [:]
    func value(for key: Int) -> (stall: TimeInterval, timeout: TimeInterval)? { lock.lock(); defer { lock.unlock() }; return stalls[key] }
    func set(_ value: (stall: TimeInterval, timeout: TimeInterval)?, for key: Int) { lock.lock(); stalls[key] = value; lock.unlock() }
}
#endif

/// A page image crossing from its render to the Vision lane by value.
struct InkFitImage: @unchecked Sendable { let image: CGImage }

/// A value an ink-fit queue job hands back, and its done signal. A job runs
/// at most once: a lane claims it before it runs, and a waiter that gives up
/// abandons it (moved or abandoned copies left on another lane do nothing).
final class InkFitResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var state = 0  // 0 waiting, 1 running, 2 abandoned
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if state == 0 { state = 1; return true }; return false }
    func abandon() { lock.lock(); if state == 0 { state = 2 }; lock.unlock() }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return state == 1 }
    var value: T?
    let done = DispatchSemaphore(value: 0)
}

/// Read tokens for the ink fit, by page content (the page's text and box),
/// the most recent `capacity` pages.
final class InkTokenCache: @unchecked Sendable {
    static let shared = InkTokenCache()
    static let capacity = 64
    private let lock = NSLock()
    private var tokens: [Int: [DocumentSearcher.InkToken]] = [:]
    private var order: [Int] = []

    /// The page's content key: its text, the bytes of its largest image, its
    /// displayed box and rotation. Read once per page object.
    static func key(page: PDFPage, cgPage: CGPDFPage, visual: CGSize) -> Int {
        if let known = PageKeyCache.shared.value(for: page) { return known }
        var hasher = Hasher()
        hasher.combine(page.string ?? "")
        hasher.combine(largestImageBytes(cgPage))
        hasher.combine(visual.width)
        hasher.combine(visual.height)
        hasher.combine(page.rotation)
        let key = hasher.finalize()
        PageKeyCache.shared.set(key, for: page)
        return key
    }

    /// The stored bytes of the page's largest direct image (as stored: a JPEG
    /// stays compressed), or empty.
    static func largestImageBytes(_ cgPage: CGPDFPage) -> Data {
        guard let dictionary = cgPage.dictionary,
              case .found(let resources) = TextLayerExtractor.inheritedResources(of: dictionary) else { return Data() }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return Data() }
        final class Best { var area = 0; var data = Data() }
        let best = Best()
        CGPDFDictionaryApplyBlock(xobjects, { _, value, info in
            guard let info else { return true }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image",
                  CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height)
            else { return true }
            let best = Unmanaged<Best>.fromOpaque(info).takeUnretainedValue()
            if Int(width) * Int(height) > best.area {
                var format = CGPDFDataFormat.raw
                if let data = CGPDFStreamCopyData(stream, &format) as Data? { best.area = Int(width) * Int(height); best.data = data }
            }
            return true
        }, Unmanaged.passUnretained(best).toOpaque())
        return best.data
    }

    func value(for key: Int) -> [DocumentSearcher.InkToken]? {
        lock.lock(); defer { lock.unlock() }
        return tokens[key]
    }

    func set(_ value: [DocumentSearcher.InkToken], for key: Int) {
        lock.lock(); defer { lock.unlock() }
        if tokens.updateValue(value, forKey: key) == nil { order.append(key) }
        while order.count > Self.capacity { tokens.removeValue(forKey: order.removeFirst()) }
    }
}

/// Fitted boxes by job, with the jobs a background fit is computing.
final class InkFitCache: @unchecked Sendable {
    static let shared = InkFitCache()
    static let capacity = 4096
    private let lock = NSLock()
    private var fittedByKey: [Int: CGRect] = [:]
    private var order: [Int] = []
    private var inFlight: Set<Int> = []

    /// The last degraded box a search returned, for display only (the main
    /// thread's live preview shows what will be applied); never a fit.
    private var displayedByKey: [Int: CGRect] = [:]
    private var displayedOrder: [Int] = []

    func fitted(for key: Int) -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        return fittedByKey[key]
    }

    func displayed(for key: Int) -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        return displayedByKey[key]
    }

    /// True when the caller should start the fit (none is running for `key`).
    func begin(_ key: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.insert(key).inserted
    }

    /// A fit (cached), or a degraded box (`displayed`, kept for display only).
    func finish(_ key: Int, fitted: CGRect?, displayed: CGRect? = nil) {
        lock.lock(); defer { lock.unlock() }
        inFlight.remove(key)
        if let fitted {
            if fittedByKey.updateValue(fitted, forKey: key) == nil { order.append(key) }
            while order.count > Self.capacity { fittedByKey.removeValue(forKey: order.removeFirst()) }
            if displayedByKey.removeValue(forKey: key) != nil { displayedOrder.removeAll { $0 == key } }
        } else if let displayed {
            if displayedByKey.updateValue(displayed, forKey: key) == nil { displayedOrder.append(key) }
            while displayedOrder.count > Self.capacity { displayedByKey.removeValue(forKey: displayedOrder.removeFirst()) }
        }
    }
}

/// The content key of a page object (`InkTokenCache.key`), held weakly by page.
final class PageKeyCache: @unchecked Sendable {
    static let shared = PageKeyCache()
    private let lock = NSLock()
    private let table = NSMapTable<PDFPage, NSNumber>.weakToStrongObjects()

    func value(for page: PDFPage) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return table.object(forKey: page)?.intValue
    }

    func set(_ value: Int, for page: PDFPage) {
        lock.lock(); defer { lock.unlock() }
        table.setObject(NSNumber(value: value), forKey: page)
    }
}

/// A private CoreGraphics copy of each document a search fits on, made from
/// its data through the guarded path (`RSGuardedDataRepresentation`: PDFKit
/// raises on a malformed /Info), held weakly by document.
final class PrivatePDFCopies: @unchecked Sendable {
    static let shared = PrivatePDFCopies()
    private let lock = NSLock()
    private let table = NSMapTable<PDFDocument, CGPDFDocumentBox>.weakToStrongObjects()
    final class CGPDFDocumentBox {
        let document: CGPDFDocument
        /// One draw of the copy at a time.
        let drawLock = InkFitDrawLock()
        init(_ d: CGPDFDocument) { document = d }
    }

    /// For a copy made by `copy(of:)` (else one lock shared by every other document).
    func drawLock(for copy: CGPDFDocument?) -> InkFitDrawLock {
        lock.lock(); defer { lock.unlock() }
        guard let copy else { return Self.otherDraws }
        for case let box as CGPDFDocumentBox in table.objectEnumerator()?.allObjects ?? [] where box.document === copy {
            return box.drawLock
        }
        // Every fit draws from a copy made here; one not found (its document
        // gone while a fit still draws) shares the one lock.
        DocumentSearcher.inkFitLogger.log("ink fit: a draw of a document with no private copy; it takes the shared draw lock")
        return Self.otherDraws
    }
    private static let otherDraws = InkFitDrawLock()

    /// Called on the thread that owns `document`; made once per document (the
    /// lock is held across the write, so two first calls do not both write it).
    /// An encrypted copy that an empty password does not open gives nil: the
    /// fit then falls back to the drift envelope, reported as degraded.
    func copy(of document: PDFDocument) -> CGPDFDocument? {
        lock.lock(); defer { lock.unlock() }
        if let known = table.object(forKey: document) { return known.document }
        guard let data = RSGuardedDataRepresentation(document),
              let provider = CGDataProvider(data: data as CFData),
              let opened = CGPDFDocument(provider) else { return nil }
        if opened.isEncrypted, !opened.isUnlocked, !opened.unlockWithPassword("") { return nil }
        table.setObject(CGPDFDocumentBox(opened), forKey: document)
        #if DEBUG
        made[ObjectIdentifier(document), default: 0] += 1
        #endif
        return opened
    }

    #if DEBUG
    /// Test seam: how many copies have been made of `document`.
    private var made: [ObjectIdentifier: Int] = [:]
    func madeCount(of document: PDFDocument) -> Int {
        lock.lock(); defer { lock.unlock() }
        return made[ObjectIdentifier(document)] ?? 0
    }
    #endif
}

/// `inkFitDidUpdate`, posted once on the main thread for any number of fits
/// that land before it goes out.
final class InkFitUpdates: @unchecked Sendable {
    static let shared = InkFitUpdates()
    private let lock = NSLock()
    private var pending = false

    func post() {
        lock.lock()
        guard !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()
        DispatchQueue.main.async {
            self.lock.lock(); self.pending = false; self.lock.unlock()
            NotificationCenter.default.post(name: DocumentSearcher.inkFitDidUpdate, object: nil)
        }
    }
}

/// A CGPDFPage handed to the background token read (the read only draws it;
/// concurrent reads of a `CGPDFPage` are covered by `PDFKitConcurrencyStressTests`).
struct InkFitPage: @unchecked Sendable {
    let page: CGPDFPage
    /// Held so the page's document outlives a job that outlives its wait.
    let document: CGPDFDocument?
    /// The lock its document's draws take.
    let drawLock: InkFitDrawLock
    init(_ page: CGPDFPage) {
        self.page = page; document = page.document
        drawLock = PrivatePDFCopies.shared.drawLock(for: page.document)
    }
}

/// One draw of a private copy at a time, on the drawing caller's own thread
/// (a render is CPU work that waits on nothing else, so no task thread waits
/// on a lane for it). A caller waits a bounded time for the lock; while a
/// draw has held it past that (a hung draw), later callers answer at once.
final class InkFitDrawLock: @unchecked Sendable {
    private let drawing = NSLock()
    private let lock = NSLock()
    private var heldSince: Date?
    /// `work` with the lock held; nil when the lock is not had within `wait`,
    /// or at once while a draw has held it longer than `wait`.
    func draw<T>(wait: TimeInterval, _ work: () -> T) -> T? {
        if let since = lock.withLock({ heldSince }), Date().timeIntervalSince(since) > wait { return nil }
        guard drawing.lock(before: Date().addingTimeInterval(wait)) else { return nil }
        lock.withLock { heldSince = Date() }
        defer { lock.withLock { heldSince = nil }; drawing.unlock() }
        return work()
    }
}

/// The draws running now, by page content key, and when each began. A draw
/// that never returns holds its thread for good (it runs inline, with no lane
/// to retire): a page with a draw running past `inkFitTimeout` is not drawn
/// again, from any copy, so it holds one thread at most.
final class InkFitDrawsInFlight: @unchecked Sendable {
    static let shared = InkFitDrawsInFlight()
    private let lock = NSLock()
    private var draws: [Int: [Int: Date]] = [:]
    private var next = 0
    func begin(_ key: Int) -> Int {
        lock.withLock { next += 1; draws[key, default: [:]][next] = Date(); return next }
    }
    func end(_ key: Int, _ id: Int) {
        lock.withLock { draws[key]?[id] = nil; if draws[key]?.isEmpty == true { draws[key] = nil } }
    }
    func isHung(_ key: Int, past limit: TimeInterval) -> Bool {
        lock.withLock { draws[key]?.values.contains { Date().timeIntervalSince($0) > limit } ?? false }
    }
}

/// Per-page answers of `carriesHiddenTextOverImage`, held weakly by page.
final class HiddenTextOverImageCache: @unchecked Sendable {
    static let shared = HiddenTextOverImageCache()
    private let lock = NSLock()
    private let table = NSMapTable<PDFPage, NSNumber>.weakToStrongObjects()

    func value(for page: PDFPage) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return table.object(forKey: page)?.boolValue
    }

    func set(_ value: Bool, for page: PDFPage) {
        lock.lock(); defer { lock.unlock() }
        table.setObject(NSNumber(value: value), forKey: page)
    }
}
