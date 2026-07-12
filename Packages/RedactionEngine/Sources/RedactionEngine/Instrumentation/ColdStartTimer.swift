import Foundation

// Engineer-facing cold-start timing capture.
// Pairs with the DataPipeline `bundle_size.json` build probe (DataPipeline
// commit `8ab3649`, 2026-04-26). Cross-reference key is `_meta.git_head` from
// the Python probe vs. `gitHead` on the Swift snapshot — both equal
// `git rev-parse --short HEAD` at the same checkout.
//
// Spec: the DataPipeline data-requirements spec §1.35 + §4 #13
// (engineer-facing only — no Resecta UI copy in V1) + §7.7 F-12 (ack option c:
// engine_load_ms, first_detection_ready_ms).
//
// Storage and mark methods are gated behind `#if DEBUG`; release builds compile
// to no-op shims with the same public surface so call sites need no extra
// gating. Resecta `CLAUDE.md` zero-networking + no-document-content invariants
// are preserved (the type captures durations only — no payload).

#if DEBUG
/// Engineer-facing cold-start timing recorder.
///
/// Two metrics are captured against a process-start baseline:
///
/// - `engineLoadMs` — time from `captureProcessStart()` to
///   `markEngineLoaded()` (the moment `DetectionOrchestrator.init(...)`
///   finishes — all gazetteer / classifier / scorer loaders run as
///   stored-property defaults before the init body executes, so marking at
///   the end of the init body is the engine-ready point).
/// - `firstDetectionReadyMs` — time from `captureProcessStart()` to
///   `markFirstDetectionComplete()` (the first `PIIDetector.detect(...)`
///   call returning inside `DetectionOrchestrator.detectPage(...)`).
///   Idempotent: the first call wins, subsequent calls are no-ops, so the
///   mark site does not need to track "first" itself.
///
/// **Concurrency model.** Mark sites in `DetectionOrchestrator` are
/// synchronous. An `actor` would force every mark to be `await`-suspended,
/// which the synchronous init / sync-detect path cannot honour. Instead the
/// type is `final class @unchecked Sendable` with `NSLock`, mirroring the
/// codebase's existing pattern (`RegexSentinelCheck.ResumedFlag`). Single-shot
/// idempotent writes, synchronous reads.
///
/// **Process-start baseline.** A `static let processStart = ContinuousClock.now`
/// captures the moment of *first reference*, not process launch. To pin the
/// baseline to the earliest user-controllable point, `ResectaApp.init()` calls
/// `captureProcessStart()` as its first line. The first call wins; subsequent
/// calls are no-ops. If `captureProcessStart()` is never called, the
/// accessors return `nil` rather than silently substituting a misleading
/// near-engine-load baseline.
///
/// **`gitHead` ships nil in V1.** `~/resecta/project.yml` does not inject a
/// `GitHead` Info.plist key as of 2026-04-28; V1.1+ wires a `preBuildScripts`
/// entry running `git rev-parse --short HEAD`. Cross-reference with the
/// Python probe is engineer-facing — read both side-by-side at the same
/// checkout.
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

    /// Whole milliseconds from process-start baseline to engine-loaded mark,
    /// or `nil` if either has not been recorded.
    public var engineLoadMs: Int? {
        lock.lock(); defer { lock.unlock() }
        return Self.millisecondsBetween(processStart, and: engineLoadedAt)
    }

    /// Whole milliseconds from process-start baseline to first-detection
    /// returned mark, or `nil` if either has not been recorded.
    public var firstDetectionReadyMs: Int? {
        lock.lock(); defer { lock.unlock() }
        return Self.millisecondsBetween(processStart, and: firstDetectionCompleteAt)
    }

    /// Snapshot of all current metrics, suitable for engineer-facing
    /// diagnostics (debugger po, future debug-menu read). `gitHead` is `nil`
    /// in V1 (see V1.1+ defer-note above).
    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            engineLoadMs: Self.millisecondsBetween(processStart, and: engineLoadedAt),
            firstDetectionReadyMs: Self.millisecondsBetween(processStart, and: firstDetectionCompleteAt),
            gitHead: nil
        )
    }

    public struct Snapshot: Sendable, Equatable {
        public let engineLoadMs: Int?
        public let firstDetectionReadyMs: Int?
        public let gitHead: String?

        public init(engineLoadMs: Int?, firstDetectionReadyMs: Int?, gitHead: String?) {
            self.engineLoadMs = engineLoadMs
            self.firstDetectionReadyMs = firstDetectionReadyMs
            self.gitHead = gitHead
        }
    }

    /// Whole-millisecond delta between two `ContinuousClock.Instant`s,
    /// truncated toward zero. `nil` if either instant is nil.
    private static func millisecondsBetween(
        _ start: ContinuousClock.Instant?,
        and end: ContinuousClock.Instant?
    ) -> Int? {
        guard let start, let end else { return nil }
        let comps = (end - start).components
        // attoseconds = 1e-18 s; 1 ms = 1e15 attoseconds.
        return Int(comps.seconds) * 1_000 + Int(comps.attoseconds / 1_000_000_000_000_000)
    }
}
#else
/// Release-build no-op shim — identical public surface, zero state.
/// Spec §4 #13: engineer-facing only; release builds pay no instrumentation
/// cost.
public final class ColdStartTimer: @unchecked Sendable {
    public static let shared = ColdStartTimer()

    public init(processStart: ContinuousClock.Instant? = nil) {}

    public func captureProcessStart(at instant: ContinuousClock.Instant = ContinuousClock.now) {}
    public func markEngineLoaded(at instant: ContinuousClock.Instant = ContinuousClock.now) {}
    public func markFirstDetectionComplete(at instant: ContinuousClock.Instant = ContinuousClock.now) {}

    public var engineLoadMs: Int? { nil }
    public var firstDetectionReadyMs: Int? { nil }

    public func snapshot() -> Snapshot {
        Snapshot(engineLoadMs: nil, firstDetectionReadyMs: nil, gitHead: nil)
    }

    public struct Snapshot: Sendable, Equatable {
        public let engineLoadMs: Int?
        public let firstDetectionReadyMs: Int?
        public let gitHead: String?

        public init(engineLoadMs: Int?, firstDetectionReadyMs: Int?, gitHead: String?) {
            self.engineLoadMs = engineLoadMs
            self.firstDetectionReadyMs = firstDetectionReadyMs
            self.gitHead = gitHead
        }
    }
}
#endif
