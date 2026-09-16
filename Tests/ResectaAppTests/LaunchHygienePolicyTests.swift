import Testing
import SwiftUI
@testable import ResectaApp

// Orphan-sweep scene-phase policy.
//
// The sweep of stale temp files (`cleanOrphanedTempFiles()`) runs at
// process launch and — through `LaunchHygienePolicy` — on every return to
// the foreground. These tests pin the phase mapping: only `.active` starts
// the sweep; the two snapshot-privacy phases never start filesystem work.
// Implementation lives beside `SnapshotPrivacyPolicy` in
// `SnapshotPrivacyOverlay.swift`; the wire-up is `ResectaApp.swift`'s
// `.onChange(of: scenePhase)`.

@Suite("Launch hygiene policy")
struct LaunchHygienePolicyTests {

    @Test("`.active` starts the orphan sweep")
    func activeStartsSweep() {
        #expect(LaunchHygienePolicy.shouldSweepOrphans(on: .active) == true)
    }

    @Test("`.inactive` does not start the sweep")
    func inactiveDoesNotStartSweep() {
        #expect(LaunchHygienePolicy.shouldSweepOrphans(on: .inactive) == false)
    }

    @Test("`.background` does not start the sweep")
    func backgroundDoesNotStartSweep() {
        #expect(LaunchHygienePolicy.shouldSweepOrphans(on: .background) == false)
    }
}
