import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Session close removes abandoned intermediates.
//
// A `recon_*` file is the reconstructor's in-progress artifact; the run
// that wrote it removes it on every exit path, so one still in the session
// directory at close was abandoned. `downgradeTempProtectionOnSessionClose()`
// unlinks it before the protection downgrade — the launch sweep would
// otherwise reap it only after its 1-hour TTL. The session's own output
// (`redacted_*`) stays: it is the registered output until `clearAll()`.

@Suite("Session close removes abandoned intermediates")
@MainActor
struct PipelineCoordinatorSessionCloseTests {

    @Test("The intermediate walk removes recon_ entries and leaves the redacted_ output")
    func walkRemovesReconLeavesOutput() throws {
        // Per-test parent directory: the shared temp root sees unrelated
        // churn from parallel tests; the session directory under our own
        // root is the only thing enumerated.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "session_close_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = TempExportDirectory(parent: root)
        defer { dir.tearDown() }
        let recon = try dir.childURL(named: "recon_\(UUID().uuidString).pdf")
        let output = try dir.childURL(named: "redacted_\(UUID().uuidString).pdf")
        try Data("intermediate".utf8).write(to: recon)
        try Data("output".utf8).write(to: output)

        PipelineCoordinator.removeAbandonedIntermediates(in: dir.url)

        #expect(!FileManager.default.fileExists(atPath: recon.path),
                "the abandoned intermediate is removed at session close")
        #expect(FileManager.default.fileExists(atPath: output.path),
                "the session's output is not touched by the walk")
        #expect(FileManager.default.fileExists(atPath: dir.url.path),
                "the session directory itself stays for tearDown()")
    }

    @Test("The walk on a directory that does not exist does nothing")
    func walkOnMissingDirectoryDoesNothing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing_\(UUID().uuidString)", isDirectory: true)
        PipelineCoordinator.removeAbandonedIntermediates(in: missing)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("downgradeTempProtectionOnSessionClose removes a recon_ file from the live session directory and keeps the output")
    func sessionCloseRemovesReconFromLiveDirectory() throws {
        let coord = PipelineCoordinator(
            documentState: DocumentState(),
            redactionState: RedactionState(),
            settingsState: SettingsState()
        )
        defer { coord.tearDownTempDirectory() }
        let recon = try coord.tempExportDirectory.childURL(
            named: "recon_\(UUID().uuidString).pdf")
        let output = try coord.tempExportDirectory.childURL(
            named: "redacted_\(UUID().uuidString).pdf")
        try Data("intermediate".utf8).write(to: recon)
        try Data("output".utf8).write(to: output)

        coord.downgradeTempProtectionOnSessionClose()

        #expect(!FileManager.default.fileExists(atPath: recon.path),
                "session close unlinks the abandoned intermediate")
        #expect(FileManager.default.fileExists(atPath: output.path),
                "session close leaves the registered output for clearAll()")
    }
}
