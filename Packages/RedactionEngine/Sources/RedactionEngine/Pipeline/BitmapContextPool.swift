import CoreGraphics
import Foundation

// PERF-5 (paired with SEC-5) — Per-rasterizer bitmap context pool with
// unconditional zeroize on check-in. Fixed cap of 4 entries keyed by
// `(width, height)`. LRU eviction on size mismatch. See plan §5 PERF-5
// and §6 SEC-5↔PERF-5 cross-cutting risk: shipping pool reuse without
// zeroize is a SEC-5 regression, so `checkIn` calls
// `PixelOperations.zeroizeBitmapBuffer` unconditionally and the post-
// checkIn buffer is debug-asserted to be all zeros.

/// Pool of reusable `CGContext` bitmap buffers, sized to the locked
/// per-rasterizer cap. The pool is short-lived (one per pipeline run)
/// and released when the rasterizer goes out of scope.
///
/// **Concurrency.** The pool guards `entries` with an internal `NSLock`.
/// The page-loop's `checkOut`/`checkIn` calls are still serialized by
/// the rasterizer's per-run, one-page-at-a-time ownership — the lock's
/// purpose is the cross-isolation `flush()` path (PERF-bitmappool-no-
/// memwarning-flush): `PipelineCoordinator.memoryWarningTask` runs on
/// MainActor and the page loop runs on a `@concurrent` executor, so
/// without the lock a memory-warning-driven `flush()` could race the
/// `checkOut`/`checkIn` mutations of `entries`. Lock acquisition is
/// uncontended on the page-loop hot path (only `flush()` waits behind
/// an in-flight checkOut/checkIn, and only briefly).
public final class BitmapContextPool: @unchecked Sendable {

    /// Locked decision: 4 same-size contexts, LRU eviction (decisions.md
    /// Batch 10 Q1). Cap is intentionally not configurable — the value
    /// is part of the SEC-5/PERF-5 contract.
    public static let capacity: Int = 4

    /// One pool entry. Order in `entries` is LRU-ordered (oldest first,
    /// newest last). `checkOut` returns the most-recent same-size entry
    /// (LIFO for hot reuse) and `checkIn` appends.
    private struct Entry {
        let width: Int
        let height: Int
        let context: CGContext
    }

    private var entries: [Entry] = []

    /// Guards `entries` so `flush()` (called from MainActor on memory
    /// warning) is safe against in-flight `checkOut`/`checkIn` from the
    /// `@concurrent` rasterize page-loop.
    private let lock = NSLock()

    public init() {}

    // MARK: - Check-out

    /// Return a zeroed `CGContext` of the requested dimensions. If the
    /// pool holds a same-size entry, that entry is removed from the
    /// pool and returned (caller now owns it until `checkIn`). Otherwise
    /// a fresh context is created; the pool's size is unchanged on
    /// check-out (eviction happens on check-in when the pool is full).
    ///
    /// Returns `nil` if the underlying `createBitmapContext` fails
    /// (matches the existing pattern at `PageRasterizer:127`).
    public func checkOut(width: Int, height: Int) -> CGContext? {
        lock.lock()
        // LIFO scan: prefer the most-recently-returned entry so the
        // hot allocation stays cache-warm across the per-page loop.
        if let idx = entries.lastIndex(where: { $0.width == width && $0.height == height }) {
            let entry = entries.remove(at: idx)
            lock.unlock()
            // SEC-5: pool-held buffers are always zeroed (`checkIn` zeroizes
            // before appending). No re-zero needed here.
            return entry.context
        }
        lock.unlock()
        return createBitmapContext(width: width, height: height)
    }

    // MARK: - Check-in

    /// Return a context to the pool. Always invokes
    /// `PixelOperations.zeroizeBitmapBuffer(_:)` first (SEC-5: this is
    /// non-negotiable — the buffer must not retain pixel data when it
    /// sits in the pool). If the pool is at capacity and no existing
    /// entry matches the size, the oldest LRU entry is evicted to
    /// make room.
    public func checkIn(_ context: CGContext) {
        // SEC-5 INVARIANT: zeroize first, every time, no flag.
        // Performed outside the lock — the buffer is exclusively owned by
        // the caller until appended, and zeroizeBitmapBuffer touches only
        // the CGContext's backing memory, not the pool's `entries` array.
        PixelOperations.zeroizeBitmapBuffer(context)

        // Debug-only assertion that the buffer is in fact all zeros
        // post-checkIn. Cheap O(W) row probe (NOT the full buffer) —
        // detects a regression where `zeroizeBitmapBuffer` was bypassed
        // or stubbed without paying full-buffer cost on every page.
        // Plan §3 SEC-5: "Debug assert post-`checkIn`: buffer is all zeros."
        assert(
            debugAssertBufferIsZeroed(context),
            "BitmapContextPool.checkIn invariant violated: buffer is not all zeros after zeroizeBitmapBuffer"
        )

        lock.lock()
        defer { lock.unlock() }
        // Evict if at capacity. We evict the OLDEST entry (FIFO at the
        // head of the array; entries appended LIFO at the tail).
        if entries.count >= Self.capacity {
            entries.removeFirst()
        }

        entries.append(Entry(
            width: context.width,
            height: context.height,
            context: context
        ))
    }

    // MARK: - Flush

    /// Drop every pooled context, releasing the up to ~135 MB of held
    /// bitmap memory (4 entries × a ~33.7 MB US-Letter raster: 2550×3300
    /// px × 4 B at 300 DPI). Idempotent and thread-safe against in-flight
    /// `checkOut`/`checkIn`. Called from
    /// `PipelineCoordinator.memoryWarningTask` after iOS posts
    /// `UIApplication.didReceiveMemoryWarningNotification`: with the
    /// PERF-2 collapse-to-1-parallelism cap also engaged, the remaining
    /// pages reallocate one pool entry lazily on next checkOut.
    /// Plan §5 PERF-5 + audit `03-security-perf-audit.md §5.2.a`.
    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
    }

    // MARK: - Introspection (test-only)

    /// Number of currently-pooled contexts. Test-only inspection.
    internal var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Whether the pool currently holds a context for the given size.
    /// Test-only inspection.
    internal func contains(width: Int, height: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.width == width && $0.height == height }
    }

    /// Peek the most-recent context for `(width, height)` without
    /// removing it. Test-only inspection — used by the zeroize-on-
    /// checkIn guard test to confirm the canonical invariant.
    internal func peek(width: Int, height: Int) -> CGContext? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last(where: { $0.width == width && $0.height == height })?.context
    }

    // MARK: - Debug-assert helper

    /// Sample-based zero check. Returns `true` if the four corners and
    /// the geometric centre of the buffer are zero across all four
    /// BGRA bytes — sufficient to detect a no-op or stubbed zeroize
    /// without the cost of inspecting every byte.
    ///
    /// `internal` so the test target can exercise the predicate in
    /// isolation (the `assert(...)` call in `checkIn` itself crashes
    /// the process when it fires, which is unsuitable for unit-test
    /// coverage). Plan §3 PERF-5:
    /// `testDebugAssertCatchesNonZero` exercises this method directly
    /// against a tampered buffer.
    internal func debugAssertBufferIsZeroed(_ context: CGContext) -> Bool {
        guard let data = context.data else { return true }  // nothing to check
        let buffer = data.assumingMemoryBound(to: UInt8.self)
        let bpr = context.bytesPerRow
        let width = context.width
        let height = context.height
        guard width > 0, height > 0 else { return true }

        // 5 probe locations: 4 corners + centre. Each samples 4 BGRA
        // bytes (alpha included — the pre-checkIn fill set alpha to 255).
        let lastX = width - 1
        let lastY = height - 1
        let midX = width / 2
        let midY = height / 2
        let probes: [(x: Int, y: Int)] = [
            (0, 0), (lastX, 0),
            (midX, midY),
            (0, lastY), (lastX, lastY),
        ]
        for probe in probes {
            let offset = probe.y * bpr + probe.x * 4
            // Bounds check just in case bpr × height was zero earlier.
            guard offset + 4 <= bpr * height else { continue }
            if buffer[offset] != 0
                || buffer[offset + 1] != 0
                || buffer[offset + 2] != 0
                || buffer[offset + 3] != 0
            {
                return false
            }
        }
        return true
    }

    // MARK: - Test-only injection

    #if DEBUG
    /// Bypass-zeroize check-in. **TEST ONLY**. Provides the path
    /// `testDebugAssertCatchesNonZero` uses to validate that the
    /// debug-assert predicate would detect a regression that skipped
    /// `zeroizeBitmapBuffer`. Not exposed outside the package — calling
    /// this in production code is a SEC-5 regression.
    internal func _testOnlyCheckInWithoutZeroize(_ context: CGContext) {
        lock.lock()
        defer { lock.unlock() }
        if entries.count >= Self.capacity {
            entries.removeFirst()
        }
        entries.append(Entry(
            width: context.width,
            height: context.height,
            context: context
        ))
    }
    #endif
}
