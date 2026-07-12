import Testing
import Foundation
@testable import RedactionEngine

// SEC-2 — Backup exclusion on temp dir.
//
// SEC-2 — these tests exercise the `TempExportDirectory` lifecycle directly. The
// integration assertion (no write at the bare `temporaryDirectory` root
// during the session) is covered here by inspecting filesystem residue
// before and after creating a session-scoped child URL.

@Suite("Backup Exclusion on Temp Dir (SEC-2)", .tags(.security))
struct BackupExclusionTests {

    // --- Test 1 ------------------------------------------------------------
    @Test("Session subdirectory is flagged isExcludedFromBackup = true")
    func testExportTempDirIsExcludedFromBackup() throws {
        let dir = TempExportDirectory()
        defer { dir.tearDown() }

        try dir.prepare()

        #expect(FileManager.default.fileExists(atPath: dir.url.path),
                "prepare() must create the per-session subdirectory")

        // Resolve the flag at the directory level (iCloud's documented
        // unit; see Apple TN "Move all your files to a directory and
        // exclude that directory from backup").
        let values = try dir.url.resourceValues(
            forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true,
                "isExcludedFromBackup must be true on the session directory URL")
    }

    // --- Test 2 ------------------------------------------------------------
    @Test("Session subdirectory is removed on tearDown()")
    func testSessionSubdirRemovedOnSessionEnd() throws {
        let dir = TempExportDirectory()
        try dir.prepare()

        // Drop a child file so we also confirm subtree removal.
        let child = try dir.childURL(named: "redacted_\(UUID().uuidString).pdf")
        try Data("payload".utf8).write(to: child)

        #expect(FileManager.default.fileExists(atPath: dir.url.path))
        #expect(FileManager.default.fileExists(atPath: child.path))

        dir.tearDown()

        #expect(!FileManager.default.fileExists(atPath: dir.url.path),
                "tearDown() must remove the session subdirectory")
        #expect(!FileManager.default.fileExists(atPath: child.path),
                "tearDown() must remove child files recursively")
    }

    // --- Test 3 ------------------------------------------------------------
    @Test("No write at temporaryDirectory root during an export session")
    func testNoWriteAtTempRootDuringSession() throws {
        // Scope the snapshot to a per-test parent directory rather than the
        // shared `FileManager.temporaryDirectory`. Other tests run in
        // parallel and write transient files at the global temp root; that
        // unrelated churn would otherwise contaminate the snapshot diff
        // here. `TempExportDirectory(parent:)` is purpose-built for this.
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "backup_excl_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmpRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let before = Set(
            (try? FileManager.default.contentsOfDirectory(
                at: tmpRoot, includingPropertiesForKeys: nil)
            )?.map(\.lastPathComponent) ?? []
        )

        let dir = TempExportDirectory(parent: tmpRoot)
        defer { dir.tearDown() }

        // Exercise the export path the same way PipelineCoordinator does:
        // ask for child URLs for the intermediate recon file, the final
        // redacted PDF, and the share-export copy.
        let recon = try dir.childURL(named: "recon_\(UUID().uuidString).pdf")
        try Data("recon".utf8).write(to: recon)

        let output = try dir.childURL(named: "redacted_\(UUID().uuidString).pdf")
        try Data("output".utf8).write(to: output)

        let exportName = "redacted_2026-05-15_12-00-00.pdf"
        let export = try dir.childURL(named: exportName)
        try Data("export".utf8).write(to: export)

        let after = Set(
            (try? FileManager.default.contentsOfDirectory(
                at: tmpRoot, includingPropertiesForKeys: nil)
            )?.map(\.lastPathComponent) ?? []
        )

        // The only new entry at the temp root is the session subdirectory
        // itself (named with `redacted_session_` prefix). No bare
        // `recon_*.pdf` or `redacted_*.pdf` files at the root.
        let newEntries = after.subtracting(before)
        for name in newEntries {
            #expect(name.hasPrefix(TempExportDirectory.sessionDirectoryPrefix),
                    "Unexpected entry at temporaryDirectory root: \(name)")
        }

        // And concretely: none of the three child filenames appear at root.
        #expect(!after.contains(recon.lastPathComponent),
                "recon_ file must not appear at temp root")
        #expect(!after.contains(output.lastPathComponent),
                "redacted_ pipeline output must not appear at temp root")
        #expect(!after.contains(exportName),
                "redacted_ export copy must not appear at temp root")

        // Sanity: all three files DO exist under the session subdir.
        #expect(FileManager.default.fileExists(atPath: recon.path))
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: export.path))
    }

    // --- Supporting test ---------------------------------------------------
    @Test("childURL() prepares the directory lazily")
    func testChildURLLazilyPreparesDirectory() throws {
        let dir = TempExportDirectory()
        defer { dir.tearDown() }

        #expect(!FileManager.default.fileExists(atPath: dir.url.path),
                "init must not touch the filesystem")

        let child = try dir.childURL(named: "lazy_\(UUID().uuidString).pdf")

        #expect(FileManager.default.fileExists(atPath: dir.url.path),
                "first childURL call must create the session subdirectory")
        #expect(child.deletingLastPathComponent().lastPathComponent
                == dir.url.lastPathComponent,
                "child URL must be located inside the session subdirectory")
    }
}
