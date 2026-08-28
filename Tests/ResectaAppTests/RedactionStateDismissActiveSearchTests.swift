import Testing
import Foundation
@testable import ResectaApp

// At the Apply seam, the editor's ONE
// `.sheet(item:)` slot reads `redactionState.activeSearch` and sits above
// the phase switch, so a Search/Scan session that survives Redact rides the
// compact float over the progress card, the results screen and its pushes,
// and Keep Editing comes back with Scan / Search disabled. The shared
// teardown (`dismissActiveSearch()`) now runs in `runFullPipeline` right
// after its start guard, and the purge re-run, `clearAll()` and
// `clearForNewDocument()` use the same helper. Pinned here without a
// SwiftUI host: the helper's behaviour and the seams that call it.
@Suite("RedactionState dismissActiveSearch")
@MainActor
struct RedactionStateDismissActiveSearchTests {

    @Test("dismissActiveSearch drops the live session and is idempotent")
    func dismissDropsTheSession() {
        let state = RedactionState()
        let search = SearchState()
        state.activeSearch = search
        #expect(state.activeSearch != nil)

        state.dismissActiveSearch()
        #expect(state.activeSearch == nil)

        state.dismissActiveSearch()
        #expect(state.activeSearch == nil, "a second call is a no-op")
    }

    @Test("Source pin: runFullPipeline tears the session down right after its start guard, before any phase transition")
    func runFullPipelineTearsDownFirst() throws {
        let source = try loadRepoFile("Sources/ResectaApp/State/PipelineCoordinator.swift")
        guard let fn = source.range(of: "func runFullPipeline(documentOverride: PipelineMode?) {"),
              let startGuard = source.range(
                of: "guard documentState.canStartPipeline(with: redactionState) else { return }",
                range: fn.upperBound..<source.endIndex),
              let teardown = source.range(
                of: "redactionState.dismissActiveSearch()",
                range: startGuard.upperBound..<source.endIndex),
              let firstTransition = source.range(
                of: ".transition(to:",
                range: startGuard.upperBound..<source.endIndex)
        else {
            Issue.record("Could not locate the runFullPipeline seam")
            return
        }
        #expect(teardown.lowerBound < firstTransition.lowerBound,
                "the teardown precedes the first phase transition of the run")
        let prologue = source[startGuard.upperBound..<firstTransition.lowerBound]
        #expect(!prologue.contains("activeSearch ="),
                "no other activeSearch write rides the run's prologue")
    }

    @Test("Source pin: the purge re-run and both lifecycle resets use the shared teardown")
    func sharedTeardownIsAdopted() throws {
        let editor = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView.swift")
        guard let purge = editor.range(of: "static func prepareForPurgeRerun(") else {
            Issue.record("Could not locate prepareForPurgeRerun")
            return
        }
        #expect(editor[purge.upperBound...].prefix(300).contains("redactionState.dismissActiveSearch()"))

        let state = try loadRepoFile("Sources/ResectaApp/State/RedactionState.swift")
        let uses = state.components(separatedBy: "dismissActiveSearch()").count - 1
        #expect(uses >= 3, "declaration + clearForNewDocument + clearAll (read \(uses))")
        #expect(!state.contains("MainActor.assumeIsolated { search?.cancelSearchWithoutAwait() }\n        pendingTriage"),
                "clearAll no longer inlines the teardown")
    }

    @Test("Source pin: the results-screen Home routes through handleHomeTap")
    func verifiedHomeRoutesThroughHandleHomeTap() throws {
        let editor = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView.swift")
        guard let id = editor.range(of: ".accessibilityIdentifier(\"verificationDoneButton\")") else {
            Issue.record("Could not locate verificationDoneButton")
            return
        }
        let start = editor.index(id.lowerBound, offsetBy: -600, limitedBy: editor.startIndex) ?? editor.startIndex
        let button = editor[start..<id.lowerBound]
        #expect(button.contains("handleHomeTap()"))
        #expect(!button.contains("showDoneConfirmation = true"),
                "the direct dialog raise is gone — it could not present over a live sheet")
    }

    /// Mirrors `HonestySurfacesTests.loadRepoFile`.
    private func loadRepoFile(
        _ relativePath: String, from file: StaticString = #filePath
    ) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}
