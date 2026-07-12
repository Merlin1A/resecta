import Testing
@testable import RedactionEngine

// D-35 — ColdStartTimer behaviour suite. Engineer-facing semantics:
// nil-until-marked, monotonic, idempotent, snapshot shape, injectable
// baseline (testability seam). See ColdStartTimer.swift for the
// concurrency-model and process-start-baseline rationale.

@Suite("ColdStartTimer")
struct ColdStartTimerTests {

    @Test("engineLoadMs is nil until both baseline and mark are recorded")
    func engineLoadMsIsNilUntilMarked() {
        let timer = ColdStartTimer()
        #expect(timer.engineLoadMs == nil)

        timer.captureProcessStart()
        #expect(timer.engineLoadMs == nil)  // baseline alone is not enough

        timer.markEngineLoaded()
        #expect(timer.engineLoadMs != nil)
    }

    @Test("engineLoadMs reports >= 0 after mark, and matches injected baseline + mark instants")
    func engineLoadMsIsMonotonicAfterMark() {
        let baseline = ContinuousClock.now
        let timer = ColdStartTimer(processStart: baseline)
        let later = baseline.advanced(by: .milliseconds(42))
        timer.markEngineLoaded(at: later)

        #expect(timer.engineLoadMs == 42)
        #expect((timer.engineLoadMs ?? -1) >= 0)
    }

    @Test("Marks are idempotent — first call wins, second call is a no-op")
    func marksAreIdempotent() {
        let baseline = ContinuousClock.now
        let timer = ColdStartTimer(processStart: baseline)

        let first = baseline.advanced(by: .milliseconds(10))
        let second = baseline.advanced(by: .milliseconds(99))

        timer.markEngineLoaded(at: first)
        timer.markEngineLoaded(at: second)
        #expect(timer.engineLoadMs == 10)

        timer.markFirstDetectionComplete(at: first)
        timer.markFirstDetectionComplete(at: second)
        #expect(timer.firstDetectionReadyMs == 10)

        // captureProcessStart is also idempotent — second call must not
        // re-pin the baseline.
        let resetAttempt = baseline.advanced(by: .milliseconds(500))
        timer.captureProcessStart(at: resetAttempt)
        #expect(timer.engineLoadMs == 10)
    }

    @Test("snapshot returns all fields with gitHead == nil in V1")
    func snapshotReturnsAllFields() {
        let baseline = ContinuousClock.now
        let timer = ColdStartTimer(processStart: baseline)
        timer.markEngineLoaded(at: baseline.advanced(by: .milliseconds(7)))
        timer.markFirstDetectionComplete(at: baseline.advanced(by: .milliseconds(15)))

        let snap = timer.snapshot()
        #expect(snap.engineLoadMs == 7)
        #expect(snap.firstDetectionReadyMs == 15)
        // V1 ships gitHead == nil; project.yml does not inject GitHead
        // (verified 2026-04-28). V1.1+ adds preBuildScripts.
        #expect(snap.gitHead == nil)
    }

    @Test("Process-start baseline can be injected for deterministic timing tests")
    func processStartCanBeInjected() {
        let baseline = ContinuousClock.now
        let timer = ColdStartTimer(processStart: baseline)

        // No captureProcessStart() call needed — the injected baseline is
        // already in place. Marks measured against it produce predictable ms.
        timer.markEngineLoaded(at: baseline.advanced(by: .milliseconds(123)))
        timer.markFirstDetectionComplete(at: baseline.advanced(by: .milliseconds(456)))

        #expect(timer.engineLoadMs == 123)
        #expect(timer.firstDetectionReadyMs == 456)
    }
}
