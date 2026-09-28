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

// The foreground sweep leaves the open document's session directory alone:
// `AppCoordinator` hands the open workspace's temporary directory to the
// sweep, and hands none once the workspace closes.

@Suite("Launch hygiene: the open session")
@MainActor
struct LiveSessionTempDirectoryTests {

    @Test("An open redact workspace hands its session directory; home hands none")
    func coordinatorHandsLiveSessionDirectory() {
        let coordinator = AppCoordinator(settingsState: SettingsState(), userTermsStore: UserTermsStore())
        #expect(coordinator.liveTempDirectories.isEmpty)

        coordinator.openRedact()
        guard case .redact(let workspace) = coordinator.activeWorkspace else {
            Issue.record("openRedact() did not produce a redact workspace")
            return
        }
        #expect(coordinator.liveTempDirectories == [workspace.coordinator.tempExportDirectory.url])

        coordinator.returnHome()
        #expect(coordinator.liveTempDirectories.isEmpty)
    }
}
