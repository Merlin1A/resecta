import Testing

// The app target cannot import the engine's test helpers; this is the same
// gate, kept in lockstep with `RedactionEngineTests/Fixtures/TestHelpers.swift`.

// MARK: - TestGate: the visible environmental skip

/// The one shape for a test that cannot run in this environment (a runtime
/// asset that is not provisioned, an emitter whose output path is not
/// requested, a host without the cores a measurement needs). The gate
/// records a warning-severity issue — visible in the xcresult and the log,
/// never a failure — so a run that skipped a body is distinguishable from a
/// run that proved something. A resource that IS tracked in the repository
/// (a fixture JSON, a bundled gazetteer, a value the test computes itself)
/// is not a gate: it is `try #require`, and its absence fails the test.
enum TestGate {
    /// Record the skip and let the caller `return`. The `return` stays at the
    /// call site so the compiler still sees the early exit.
    static func skip(_ reason: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        Issue.record(reason, severity: .warning, sourceLocation: sourceLocation)
    }
}
