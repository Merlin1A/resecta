import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// PERF-5 (paired with SEC-5) — Bitmap context pool tests.
//
// The canonical guard test (`testCheckInZeroizesBuffer`) is the load-
// bearing contract for the SEC-5 ↔ PERF-5 cross-cutting risk. Per the
// agent task body: "This is the canonical guard — do not weaken in
// later edits."

@Suite("BitmapContextPool (PERF-5)", .tags(.security, .critical))
struct BitmapContextPoolTests {

    // MARK: - testCheckInZeroizesBuffer (canonical guard)

    /// Write `0xFF` across the entire backing allocation, call
    /// `checkIn`, then peek the now-pooled context and assert every
    /// sampled byte is zero. This is the load-bearing invariant
    /// designed to prevent pool reuse from leaking pixel data
    /// (plan §6 cross-cutting risk SEC-5 ↔ PERF-5).
    @Test("checkIn zeroizes buffer (canonical guard — do not weaken)")
    func testCheckInZeroizesBuffer() throws {
        let pool = BitmapContextPool()
        let width = 200
        let height = 300

        // Check out, dirty the buffer, then check in.
        let ctx = try #require(pool.checkOut(width: width, height: height),
                               "checkOut must produce a context")
        let byteCount = ctx.bytesPerRow * ctx.height
        memset(ctx.data!, 0xFF, byteCount)

        // Spot-check pre-checkIn.
        let buffer = ctx.data!.assumingMemoryBound(to: UInt8.self)
        #expect(buffer[0] == 0xFF, "pre-checkIn sentinel must be 0xFF")

        // ACT — checkIn must zeroize unconditionally.
        pool.checkIn(ctx)

        // ASSERT — peek the pool, sample 16 random offsets across the
        // backing allocation. The peek does not remove the entry.
        let peeked = try #require(pool.peek(width: width, height: height),
                                  "pool must hold a context for this size after checkIn")
        let peekedBuffer = peeked.data!.assumingMemoryBound(to: UInt8.self)
        let peekedByteCount = peeked.bytesPerRow * peeked.height

        var rng = SystemRandomNumberGenerator()
        for _ in 0..<16 {
            let offset = Int.random(in: 0..<peekedByteCount, using: &rng)
            #expect(
                peekedBuffer[offset] == 0,
                "byte at offset \(offset) is \(peekedBuffer[offset]) after checkIn; expected 0"
            )
        }

        // Deterministic corners + centre.
        #expect(peekedBuffer[0] == 0, "head of pooled buffer must be zero")
        #expect(peekedBuffer[peekedByteCount - 1] == 0, "tail of pooled buffer must be zero")
        #expect(peekedBuffer[peekedByteCount / 2] == 0, "centre of pooled buffer must be zero")
    }

    // MARK: - testReusesContextForSameSize

    /// Check out twice at the same dimensions with a check-in in
    /// between. The second `checkOut` must return the same `CGContext`
    /// reference (object identity) the first call did.
    @Test("checkOut reuses same context after checkIn for matching size")
    func testReusesContextForSameSize() throws {
        let pool = BitmapContextPool()
        let width = 200
        let height = 300

        let first = try #require(pool.checkOut(width: width, height: height))
        pool.checkIn(first)

        let second = try #require(pool.checkOut(width: width, height: height))

        #expect(
            first === second,
            "checkOut(same size) after checkIn must return the same context (object identity)"
        )
    }

    // MARK: - testEvictsOnSizeChange

    /// Check in 5 distinct sizes. The pool capacity is 4, so the
    /// oldest entry (size #1) must be evicted and the most-recent 4
    /// must remain cached.
    @Test("checkIn evicts oldest LRU entry when capacity is exceeded")
    func testEvictsOnSizeChange() throws {
        let pool = BitmapContextPool()
        // Distinct sizes — width grows monotonically so each is unique.
        let sizes: [(w: Int, h: Int)] = [
            (100, 100),  // oldest — must be evicted
            (200, 100),
            (300, 100),
            (400, 100),
            (500, 100),  // newest — must be cached
        ]

        for size in sizes {
            let ctx = try #require(pool.checkOut(width: size.w, height: size.h),
                                   "checkOut(\(size.w)×\(size.h)) must succeed")
            pool.checkIn(ctx)
        }

        // After 5 checkIns at capacity 4, the oldest (size #0) is evicted.
        #expect(pool.count == BitmapContextPool.capacity,
                "pool count must equal capacity after eviction")
        #expect(!pool.contains(width: sizes[0].w, height: sizes[0].h),
                "oldest size (\(sizes[0].w)×\(sizes[0].h)) must be evicted")
        // Sizes 1–4 remain (size #4 is the most recent).
        for size in sizes[1...] {
            #expect(
                pool.contains(width: size.w, height: size.h),
                "size \(size.w)×\(size.h) must still be cached"
            )
        }
    }

    // MARK: - testFlushReleasesAllEntries (Package G)

    /// Package G — `flush()` drops every pooled entry so iOS can reclaim
    /// the buffers immediately on a memory-warning signal. Idempotent and
    /// expected to be callable from MainActor while a `@concurrent`
    /// rasterize page-loop is in flight; this test only pins the single-
    /// thread state machine (populate → flush → count == 0; reuse path
    /// allocates a fresh context after flush).
    @Test("flush() drops every pool entry and is idempotent")
    func testFlushReleasesAllEntries() throws {
        let pool = BitmapContextPool()
        // Populate the pool with the full capacity (4 distinct sizes).
        let sizes: [(w: Int, h: Int)] = [
            (100, 100), (200, 100), (300, 100), (400, 100),
        ]
        for size in sizes {
            let ctx = try #require(pool.checkOut(width: size.w, height: size.h))
            pool.checkIn(ctx)
        }
        #expect(pool.count == BitmapContextPool.capacity,
                "precondition — pool must be full before flush()")

        // ACT — flush() drops everything.
        pool.flush()
        #expect(pool.count == 0, "flush() must release every entry")
        for size in sizes {
            #expect(
                !pool.contains(width: size.w, height: size.h),
                "size \(size.w)×\(size.h) must no longer be cached after flush()"
            )
        }

        // Idempotent — second flush() leaves the pool empty.
        pool.flush()
        #expect(pool.count == 0, "second flush() must be a no-op")

        // Subsequent checkOut at one of the previously-cached sizes
        // allocates a fresh context (we cannot rely on object identity
        // after a flush — the prior entries were released).
        let fresh = try #require(pool.checkOut(width: sizes[0].w, height: sizes[0].h))
        // Sanity — the fresh context is usable.
        #expect(fresh.width == sizes[0].w)
        #expect(fresh.height == sizes[0].h)
        // Cleanup: return it to keep the pool in a tidy state.
        pool.checkIn(fresh)
        #expect(pool.count == 1, "pool re-populates lazily after flush()")
    }

    // MARK: - testDebugAssertCatchesNonZero

    /// Verify the debug-assert predicate detects a non-zero buffer.
    ///
    /// `checkIn` calls `assert(debugAssertBufferIsZeroed(ctx), ...)` —
    /// firing that assert would crash the test process, so we exercise
    /// the predicate directly. To prove the predicate works against
    /// the "bypassed zeroize" scenario the SEC-5 contract is concerned
    /// with, we use the `#if DEBUG`-gated `_testOnlyCheckInWithoutZeroize`
    /// shim to drop a tampered buffer into the pool, then drive the
    /// same predicate the assert reads. The predicate must return
    /// `false`, which is the value that would have crashed the process
    /// under DEBUG had a real `checkIn` been wired without zeroize.
    @Test("debug-assert predicate returns false on a non-zero buffer (DEBUG-only)")
    func testDebugAssertCatchesNonZero() throws {
        #if DEBUG
        let pool = BitmapContextPool()
        let width = 64
        let height = 64

        // Build a tampered buffer — fill with 0xAA across the entire
        // backing allocation (every probe site dirty).
        let ctx = try #require(pool.checkOut(width: width, height: height))
        let byteCount = ctx.bytesPerRow * ctx.height
        memset(ctx.data!, 0xAA, byteCount)

        // Inject into the pool WITHOUT running zeroize — the scenario
        // that would trip the assert in `checkIn` under DEBUG.
        pool._testOnlyCheckInWithoutZeroize(ctx)

        // Pull it back via peek and run the predicate directly. False
        // is the assert-tripping return value.
        let peeked = try #require(pool.peek(width: width, height: height))
        #expect(
            pool.debugAssertBufferIsZeroed(peeked) == false,
            "predicate must return false on a tampered (non-zeroed) buffer — this is the value that would fire the debug-assert"
        )

        // Positive control: after a proper zeroize, the predicate
        // returns true (the steady-state path that does NOT fire the
        // assert).
        PixelOperations.zeroizeBitmapBuffer(peeked)
        #expect(
            pool.debugAssertBufferIsZeroed(peeked) == true,
            "predicate must return true on a fully zeroed buffer"
        )
        #else
        // Non-debug builds: the assert is compiled out. Test is a no-op
        // by spec (`testDebugAssertCatchesNonZero — debug builds only`).
        #endif
    }
}
