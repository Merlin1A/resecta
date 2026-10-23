import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The export path's two state facts, reached through
// the static seams `DocumentEditorView+Export.swift` carries — never by
// widening the view. (a) A purged output is a discarded output: the purge
// path clears it through `clearOutput()`, so the run's recorded inputs
// (`lastRunInputs`) go with it, as on every other discard. (b) The share
// copy has one fixed name with no export time in it, and a copy already
// at that URL (a share whose sheet never removed its copy) is replaced,
// so a second share in the same session succeeds.

@Suite("Export — the purged output and the share copy")
@MainActor
struct ShareCopyExportTests {

    // MARK: - (a) The purged output

    @Test("A purged output clears the run's recorded inputs with it")
    func purgedOutputClearsLastRunInputs() {
        let redaction = RedactionState()
        // An output URL whose file is gone (iOS reclaimed the temp file
        // while the app was in the background — KI-4).
        redaction.outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("purged_\(UUID().uuidString).pdf")
        redaction.recordLastRunInputs(.fixture())
        let document = DocumentState()
        document.phase = .verified(report: VerificationDebugFixtures.secureAllPass)

        let source = DocumentEditorView.exportSource(redactionState: redaction, documentState: document)

        #expect(source == nil)
        #expect(redaction.outputURL == nil)
        #expect(redaction.lastRunInputs == nil,
                "today `redactionState.outputURL = nil` leaves the discarded run's inputs behind")
        guard case .failed(.exportError(.filePurged), .editing) = document.phase else {
            Issue.record("expected the purged failure returning to editing, got \(document.phaseKind)")
            return
        }
    }

    @Test("An output on disk is the export source; nothing is cleared")
    func outputOnDiskIsTheSource() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = TempExportDirectory(parent: root)
        defer { dir.tearDown() }
        let output = try dir.childURL(named: "redacted_\(UUID().uuidString).pdf")
        try Data("output".utf8).write(to: output)

        let redaction = RedactionState()
        redaction.outputURL = output
        redaction.recordLastRunInputs(.fixture())
        let document = DocumentState()
        document.phase = .verified(report: VerificationDebugFixtures.secureAllPass)

        #expect(DocumentEditorView.exportSource(redactionState: redaction, documentState: document) == output)
        #expect(redaction.lastRunInputs != nil)
        #expect(document.phaseKind == .verified)
    }

    // MARK: - (b) The share copy

    @Test("The share copy's name records no export time")
    func shareCopyNameHasNoDate() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = TempExportDirectory(parent: root)
        defer { dir.tearDown() }
        let output = try dir.childURL(named: "redacted_\(UUID().uuidString).pdf")
        try Data("output".utf8).write(to: output)

        let copy = try DocumentEditorView.makeShareCopy(of: output, in: dir)

        #expect(copy.lastPathComponent == DocumentEditorView.shareCopyFileName)
        #expect(copy.lastPathComponent.range(of: #"\d"#, options: .regularExpression) == nil,
                "today `redacted_yyyy-MM-dd_HH-mm-ss.pdf` (exportFormatter)")
        #expect(copy.deletingLastPathComponent().standardizedFileURL.path
                    == dir.url.standardizedFileURL.path,
                "the copy stays in the session's protected directory")
    }

    @Test("A second share in one session succeeds over a copy left at the export URL")
    func secondShareReplacesALeftoverCopy() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = TempExportDirectory(parent: root)
        defer { dir.tearDown() }
        let output = try dir.childURL(named: "redacted_\(UUID().uuidString).pdf")
        try Data("first run".utf8).write(to: output)

        let first = try DocumentEditorView.makeShareCopy(of: output, in: dir)
        // The first share's sheet never removed its copy.
        #expect(FileManager.default.fileExists(atPath: first.path))

        // A re-run replaced the output; the user shares again.
        try Data("second run".utf8).write(to: output, options: .atomic)
        let second = try DocumentEditorView.makeShareCopy(of: output, in: dir)

        #expect(second == first)
        #expect(try Data(contentsOf: second) == Data("second run".utf8),
                "the copy is the current output, not the leftover")
    }

    // MARK: - Fixtures

    /// Per-test parent directory, as `PipelineCoordinatorSessionCloseTests`
    /// builds it: the shared temp root sees churn from parallel tests.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("share_copy_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
