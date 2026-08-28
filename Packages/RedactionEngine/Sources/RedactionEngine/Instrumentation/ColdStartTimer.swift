import Foundation

// Engineer-facing cold-start timing capture.
// Pairs with the DataPipeline `bundle_size.json` build probe (DataPipeline
// commit `8ab3649`, 2026-04-26), which records `_meta.git_head` (equal to
// `git rev-parse --short HEAD` at build time) for manual cross-reference
// against the marks this type records.
//
// This timer is engineer-facing only — no Resecta UI copy in V1 — and
// records engine_load_ms and first_detection_ready_ms.
//
// Storage and mark methods are gated behind `#if DEBUG`; release builds compile
// to no-op shims with the same public surface so call sites need no extra
// gating. The zero-networking + no-document-content invariants
// are preserved (the type captures durations only — no payload).

#if DEBUG
/// Engineer-facing cold-start timing recorder.
///
/// Two marks are recorded against a process-start baseline:
///
/// - `markEngineLoaded()` — the moment `DetectionOrchestrator.init(...)`
///   finishes (all gazetteer / classifier / scorer loaders run as
///   stored-property defaults before the init body executes, so marking at
///   the end of the init body is the engine-ready point).
/// - `markFirstDetectionComplete()` — the first `PIIDetector.detect(...)`
///   call returning inside `DetectionOrchestrator.detectPage(...)`.
///   Idempotent: the first call wins, subsequent calls are no-ops, so the
///   mark site does not need to track "first" itself.
///
/// The millisecond-delta read-side (computed accessors + snapshot) was
/// unwired dead code (never called outside its own tests) and was removed;
/// the marks themselves stay recorded for a future debug-menu/debugger-po
/// reader.
///
/// **Concurrency model.** Mark sites in `DetectionOrchestrator` are
/// synchronous. An `actor` would force every mark to be `await`-suspended,
/// which the synchronous init / sync-detect path cannot honour. Instead the
/// type is `final class @unchecked Sendable` with `NSLock`, mirroring the
/// codebase's existing pattern (`RegexSentinelCheck.ResumedFlag`). Single-shot
/// idempotent writes.
///
/// **Process-start baseline.** A `static let processStart = ContinuousClock.now`
/// captures the moment of *first reference*, not process launch. To pin the
/// baseline to the earliest user-controllable point, `ResectaApp.init()` calls
/// `captureProcessStart()` as its first line. The first call wins; subsequent
/// calls are no-ops.
///
/// **Release builds.** This entire type compiles to a no-op shim under the
/// `#else` branch (release config). Call sites are gated by `#if DEBUG` so
/// the shim is reached only via direct construction in test code; the
/// stored-property storage and lock are absent in release.
public final class ColdStartTimer: @unchecked Sendable {
    /// Singleton accessor used by `ResectaApp.init()` and the
    /// `DetectionOrchestrator` mark sites. Tests construct their own
    /// instance via `init(processStart:)` to avoid cross-test state.
    public static let shared = ColdStartTimer()

    private let lock = NSLock()
    private var processStart: ContinuousClock.Instant?
    private var engineLoadedAt: ContinuousClock.Instant?
    private var firstDetectionCompleteAt: ContinuousClock.Instant?

    /// Construct a fresh timer. Pass `processStart` to pre-set the baseline
    /// (test seam — production code uses the singleton + `captureProcessStart()`).
    public init(processStart: ContinuousClock.Instant? = nil) {
        self.processStart = processStart
    }

    /// Record the process-start baseline. First call wins; subsequent calls
    /// are no-ops. Default argument captures `ContinuousClock.now` at the
    /// call site so the mark instant is the caller's, not this method's.
    public func captureProcessStart(at instant: ContinuousClock.Instant = ContinuousClock.now) {
        lock.lock(); defer { lock.unlock() }
        if processStart == nil { processStart = instant }
    }

    /// Record the moment the engine becomes usable. Idempotent (first call wins).
    public func markEngineLoaded(at instant: ContinuousClock.Instant = ContinuousClock.now) {
        lock.lock(); defer { lock.unlock() }
        if engineLoadedAt == nil { engineLoadedAt = instant }
    }

    /// Record the moment the first detection call returns. Idempotent
    /// (first call wins) — call sites do not need to track "first" themselves.
    public func markFirstDetectionComplete(at instant: ContinuousClock.Instant = ContinuousClock.now) {
        lock.lock(); defer { lock.unlock() }
        if firstDetectionCompleteAt == nil { firstDetectionCompleteAt = instant }
    }

}
#else
/// Release-build no-op shim — identical public surface, zero state.
/// Engineer-facing only; release builds pay no instrumentation
/// cost.
public final class ColdStartTimer: @unchecked Sendable {
    public static let shared = ColdStartTimer()

    public init(processStart: ContinuousClock.Instant? = nil) {}

    public func captureProcessStart(at instant: ContinuousClock.Instant = ContinuousClock.now) {}
    public func markEngineLoaded(at instant: ContinuousClock.Instant = ContinuousClock.now) {}
    public func markFirstDetectionComplete(at instant: ContinuousClock.Instant = ContinuousClock.now) {}
}
#endif
