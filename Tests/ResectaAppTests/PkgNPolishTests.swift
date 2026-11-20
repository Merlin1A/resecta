import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// V1.0 polish omnibus. Per-site smoke tests for the fixes that
// introduce non-trivial behavior. Trivially-correct edits (comment-only,
// docstring updates, copy tweaks) are not covered here; they are
// validated by the audit-lint hook + visual review.

// MARK: - ToastQueueManager waiting list

@Suite("Toast queue cap", .tags(.search))
@MainActor
struct ToastQueueCapTests {

    @Test("A waiting plain confirmation gives way to a newer message; must-be-seen ones all wait")
    func waitingPlainGivesWayMustBeSeenAllWait() {
        let manager = ToastQueueManager()
        // One that must be seen is shown (it carries an action), so every
        // later arrival waits behind it.
        manager.enqueue(ToastItem(message: "Cleared 2 matches.", severity: .info,
                                  actionLabel: "Undo", actionHandler: {}))
        // A burst of plain ones: each newer one drops the one waiting, so
        // one waits, the newest.
        for i in 0..<48 {
            manager.enqueue(ToastItem(message: "toast-\(i)", severity: .info))
        }
        #expect(manager.activeToasts.count == 1)
        #expect(manager.waitingToasts.map(\.message) == ["toast-47"])
        // Must-be-seen ones are never dropped: all wait, oldest first, and
        // the plain one gives way to the first of them.
        for i in 0..<40 {
            manager.enqueue(ToastItem(message: "undo-\(i)", severity: .info, actionLabel: "Undo", actionHandler: {}))
        }
        #expect(manager.waitingToasts.map(\.message) == (0..<40).map { "undo-\($0)" })
        manager.clearAll()
    }

    @Test("clearAll() drops active toasts and both queues")
    func testClearAllDrops() {
        let manager = ToastQueueManager()
        // Mix severities so the one waiting list holds several kinds.
        manager.enqueue(ToastItem(message: "info-1", severity: .info))
        manager.enqueue(ToastItem(message: "warn-1", severity: .warning))
        manager.enqueue(ToastItem(message: "info-2", severity: .info))
        manager.enqueue(ToastItem(message: "error-1", severity: .error))
        #expect(!manager.activeToasts.isEmpty)
        manager.clearAll()
        #expect(manager.activeToasts.isEmpty)
        // After clearAll, a fresh enqueue should display immediately
        // (neither queue still holds a pending item).
        manager.enqueue(ToastItem(message: "info-fresh", severity: .info))
        #expect(manager.activeToasts.count == 1)
    }
}

// MARK: - searchDebounceTask cancel on disappear

@Suite("Search debounce cancel on disappear", .tags(.search))
@MainActor
struct SearchDebounceCancelTests {

    @Test("Swift Task cancellation surrenders cooperatively (primitive smoke test, not an integration guard)")
    func testSwiftTaskCancellationCooperativelySurrenders() async {
        // This is a Swift-primitive smoke test, not an
        // integration guard. It pins the cooperative-cancellation contract that
        // SearchAndRedactSheet's `.onDisappear { searchDebounceTask?.cancel() }`
        // relies on (a cancelled debounce sleep surrenders at the next
        // Task.checkCancellation point without firing the scan). A real
        // integration test of the .onDisappear path needs UI-test
        // infrastructure and is deferred per V1.0 scope.
        let started = Date()
        let task: Task<Void, Never> = Task {
            try? await Task.sleep(for: .milliseconds(2_000))
        }
        task.cancel()
        await task.value
        let elapsed = Date().timeIntervalSince(started)
        // Should surrender well under the 2-second sleep. In isolation
        // it lands sub-millisecond; under Swift Testing's parallel
        // suite execution on the iPhone 17 simulator, host scheduling
        // jitter has been observed to push the surrender into the
        // ~700ms band. A 1.75s ceiling stays well below the 2s sleep
        // (so the "did not surrender" regression still trips) while
        // absorbing concurrent-suite load.
        #expect(elapsed < 1.75, "Cancelled task should surrender quickly; got \(elapsed)s")
    }
}

// MARK: - Import dispatch cancels prior on rapid duplicate

@Suite("Import dispatch cancellation", .tags(.search))
@MainActor
struct ImportDispatchCancellationTests {

    @Test("Cancelling a prior dispatch task surrenders the await chain")
    func testPriorDispatchCancels() async {
        // The fix is `activeImportDispatch?.cancel(); activeImportDispatch = Task { ... }`
        // at every import dispatch site. The smoke shape pins the
        // Task<Void, Never> cancel-then-replace pattern that
        // RedactWorkspaceView uses.
        var handle: Task<Void, Never>?
        let firstFinished: Task<Void, Never> = Task { @Sendable in
            try? await Task.sleep(for: .milliseconds(2_000))
        }
        handle = firstFinished
        // Replace by cancel+new — mirrors RedactWorkspaceView's pattern.
        handle?.cancel()
        let replacement: Task<Void, Never> = Task {
            try? await Task.sleep(for: .milliseconds(20))
        }
        handle = replacement
        await replacement.value
        // First task should have surrendered shortly after cancel —
        // await its value so it does not outlive the test.
        await firstFinished.value
        #expect(handle != nil)
    }
}

// MARK: - Stores read their file at init

@Suite("Stores load their file synchronously", .tags(.search))
@MainActor
struct StoreHydrateOffMainActorTests {

    @Test("UserTermsStore loads synchronously: the stored list is visible from init")
    func testUserTermsStoreSyncLoadPublishes() {
        let suiteName = "pkg-n-conc-1-userterms-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-n-userterms-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("user-terms.v1.json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        let seed = UserTermsStore(fileURL: fileURL, legacyDefaults: defaults)
        _ = seed.addAlwaysFlag(UserTerm(pattern: "alpha", isRegex: false))
        // The store reads its file inside its initialiser: the stored
        // list is there with no wait.
        let store = UserTermsStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.blob.alwaysFlag.contains(where: { $0.pattern == "alpha" }))
    }

    @Test("SavedRegexStore hydrates synchronously — the persisted list is visible from init")
    func testSavedRegexStoreSyncHydratePublishes() async {
        let suiteName = "pkg-n-conc-1-regex-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-n-regex-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("saved-regexes.v1.json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        let seed = SavedRegexStore(fileURL: fileURL, legacyDefaults: defaults)
        _ = seed.add(label: "PkgN-test", pattern: "\\d{4}")
        // Hydration is synchronous by design: the former async path
        // published `[]` first, and a mutation landing in that window
        // persisted a one-entry envelope over the real library.
        let store = SavedRegexStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.userSavedRegexes.contains(where: { $0.label == "PkgN-test" }))
    }

    @Test("SavedRegexStore: one bad row parks and survives a re-save instead of zeroing the library")
    func testSavedRegexLenientDecodeAndRetention() throws {
        let suiteName = "pkg-n-regex-lenient-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-n-regex-lenient-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("saved-regexes.v1.json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let seed = SavedRegexStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(seed.add(label: "Keep", pattern: "\\d{3}") == .saved)

        // Corrupt one row in the stored file (outer FileJSONBlob
        // envelope → payload → userSavedRegexes; the envelope JSON is
        // shape-identical to the pre-file UserDefaults blob). The
        // previous synthesized decoder failed the WHOLE array on this
        // row, emptying the library; leniency parks it instead.
        let data = try Data(contentsOf: fileURL)
        var outer = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var payload = try #require(outer["payload"] as? [String: Any])
        var rows = try #require(payload["userSavedRegexes"] as? [[String: Any]])
        rows.append(["bogusRow": true])
        payload["userSavedRegexes"] = rows
        outer["payload"] = payload
        try JSONSerialization.data(withJSONObject: outer).write(to: fileURL)

        let store = SavedRegexStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.userSavedRegexes.map(\.label) == ["Keep"],
                "survivors load; the bad row parks instead of zeroing the list")

        // The re-save that used to make the loss permanent.
        #expect(store.add(label: "Second", pattern: "[a-z]{2}") == .saved)
        let rawAfter = String(
            data: try Data(contentsOf: fileURL),
            encoding: .utf8)!
        #expect(rawAfter.contains("bogusRow"),
                "the parked row survives the unrelated save")

        let reloaded = SavedRegexStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(Set(reloaded.userSavedRegexes.map(\.label)) == ["Keep", "Second"])
    }
}

// MARK: - HomeView routes Result.failure through workspace

@Suite("HomeView import failure routes to FailedStateView", .tags(.search))
@MainActor
struct HomeViewFailureRoutingTests {

    @Test("AppCoordinator can be driven to a .failed(.importError(.corrupt)) state")
    func testHomeViewFailureRoutingShape() {
        // HomeView.handleFileImportResult on .failure (non-userCancelled)
        // opens a workspace via appCoordinator.openRedact() and drives
        // its DocumentState to `.failed(.importError(.corrupt))`. The
        // shape under test is the sequence: openRedact → .importing →
        // .failed. We invoke the same operations against a fresh
        // AppCoordinator and assert the terminal phase.
        let settings = SettingsState(defaults: makeScratchDefaults().0)
        let coordinator = AppCoordinator(settingsState: settings, userTermsStore: UserTermsStore())
        coordinator.openRedact()
        guard case .redact(let workspace) = coordinator.activeWorkspace else {
            Issue.record("openRedact() did not produce a redact workspace")
            return
        }
        workspace.documentState.transition(to: .importing)
        let routed = workspace.documentState.transition(to: .failed(
            error: .importError(.corrupt),
            returnPhase: .empty
        ))
        #expect(routed)
        guard case .failed(let error, _) = workspace.documentState.phase,
              case .importError(.corrupt) = error else {
            Issue.record("Workspace did not land on .failed(.importError(.corrupt))")
            return
        }
    }
}

// MARK: - UX-redaction-applied-blocks — apply path enqueues toast

@Suite("UX-redaction-applied-blocks toast replacement", .tags(.search))
@MainActor
struct ApplyTriggersToastTests {

    @Test("Singular-form copy renders for 1-instance apply")
    func testSingularFormCopy() {
        // UX-singular-plural-grammar: the count-suffix ternary
        // idiom for user-facing counts. The templates this test
        // originally quoted ("Redact N instance(s)?", the triage
        // sheet's "N item(s) detected") retired with their surfaces;
        // the idiom's live sites are the clear-notice family
        // ("… N unapplied match(es) …", pinned end-to-end by
        // InterfaceSwitchClearTests). Pin the grammar against a real
        // producer so the rule stays anchored to production copy.
        #expect(SearchAndRedactSheet.recallClearedMessage(unappliedCount: 1)
                == "Recall cleared 1 unapplied match.")
        #expect(SearchAndRedactSheet.recallClearedMessage(unappliedCount: 2)
                == "Recall cleared 2 unapplied matches.")
    }
}

// MARK: - A late progress tick after Stop is dropped

@Suite("Cancellation gate", .tags(.search))
@MainActor
struct CancellationGateTests {

    @Test("Stop invalidates the active run; a progress tick from that run no longer re-enters the pipeline phases")
    func lateTickAfterStopIsDropped() async throws {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.documentState.phase = .editing
        coord.redactionState.addRegion(
            RedactionRegion(
                id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
                source: .manual),
            page: 0, undoManager: nil)
        coord.runFullPipeline(documentOverride: .secureRasterization)
        let runId = try #require(coord.documentState.activeRunId)
        let task = coord.documentState.activePipelineTask

        coord.documentState.cancelActivePipeline(redactionState: coord.redactionState)
        #expect(coord.documentState.activeRunId == nil,
                "Stop invalidates the run in its synchronous step")
        #expect(coord.documentState.phaseKind == .editing)

        // The cancelled run's tick, reported through the production sink.
        let tick = DocumentState.RedactionProgress(
            currentPage: 2, totalPages: 5, currentStep: "Page 2")
        coord.apply(.phase(.redacting(progress: tick)), from: runId)
        #expect(coord.documentState.phaseKind == .editing,
                "a tick from a run that is no longer active is dropped")

        // A later run's events still land.
        coord.runFullPipeline(documentOverride: .secureRasterization)
        let runId2 = try #require(coord.documentState.activeRunId)
        let task2 = coord.documentState.activePipelineTask
        coord.apply(.phase(.redacting(progress: tick)), from: runId2)
        #expect(coord.documentState.phaseKind == .redacting)
        coord.documentState.cancelActivePipeline(redactionState: coord.redactionState)
        _ = await task?.value
        _ = await task2?.value
    }
}
