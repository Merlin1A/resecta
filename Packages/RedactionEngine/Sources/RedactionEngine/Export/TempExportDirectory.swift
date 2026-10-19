import Foundation

// Backup exclusion on temp dir.
//
// All export-pipeline temp writes live under a per-session
// subdirectory `redacted_session_<UUID>/` inside `FileManager.temporaryDirectory`.
// The subdirectory is flagged with `isExcludedFromBackup = true` at the
// directory level (iCloud's documented unit for the exclusion flag) so the
// transient redacted artifacts are not designed to be carried into iCloud
// or local backups. The entire subdirectory is removed on session end.
//
// This helper owns the lifecycle. `TempFileHardening` (parallel
// sibling) handles per-file protection-class flags; the two are intended to
// be composed at the call sites in `PipelineCoordinator` and the export
// finalize block.
//
// File location note: this type lives in the RedactionEngine package so it
// can be exercised by the engine test suite (`BackupExclusionTests`).
// It could instead be folded into `TempFileHardening`; placing it
// alongside in `Export/` keeps the two together.

/// Owns the lifecycle of a per-session temporary subdirectory inside
/// `FileManager.default.temporaryDirectory`. The subdirectory is created
/// lazily on first use (or eagerly via ``prepare()``), flagged with
/// `isExcludedFromBackup = true` at the directory level, and removed by
/// ``tearDown()``.
///
/// Thread safety: `final class` with serialized access via the owning
/// MainActor coordinator. Marked `@unchecked Sendable` for the same reason
/// `PipelineCoordinator` is — MainActor isolation serializes mutation, but
/// the type is consumed across `@concurrent` engine entry points which take
/// the resolved child `URL` (a value type) and never the directory wrapper.
public final class TempExportDirectory: @unchecked Sendable {

    /// Filename prefix for per-session subdirectories. `cleanOrphanedTempFiles`
    /// recognizes this prefix to sweep crash-orphaned sessions on next launch.
    public static let sessionDirectoryPrefix = "redacted_session_"

    /// The per-session subdirectory URL. Stable for the lifetime of this
    /// instance. Created on demand by ``prepare()`` / ``childURL(named:)``.
    public let url: URL

    /// Set once the directory has been created on disk and flagged.
    private var didPrepare: Bool = false

    /// Create a wrapper bound to a fresh `redacted_session_<UUID>/` URL
    /// inside `FileManager.default.temporaryDirectory`. Does not touch the
    /// filesystem — call ``prepare()`` or ``childURL(named:)`` to create.
    public init(parent: URL = FileManager.default.temporaryDirectory) {
        let name = "\(Self.sessionDirectoryPrefix)\(UUID().uuidString)"
        self.url = parent.appendingPathComponent(name, isDirectory: true)
    }

    /// Idempotently create the subdirectory and set `isExcludedFromBackup`.
    /// Safe to call repeatedly. A directory deleted behind the session (a
    /// sweep, the system) is created and flagged again. Throws on
    /// `createDirectory` failure; the `isExcludedFromBackup` flag is
    /// best-effort (logged via `try?`) — if it cannot be set, the temp write
    /// still proceeds rather than blocking the pipeline.
    @discardableResult
    public func prepare() throws -> URL {
        if didPrepare, FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: nil
        )
        // iCloud's documented unit for the exclusion flag is the directory
        // (Apple TN: "Move all your files to a directory and exclude that
        //  directory from backup"). Setting it on the directory propagates
        // to child files; we do not need to flag each child separately.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        // The URL must be mutable to call setResourceValues.
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
        didPrepare = true
        return url
    }

    /// Return a child URL inside the session subdirectory, creating the
    /// directory on first call. Convenience over ``prepare()`` +
    /// ``url.appendingPathComponent(_:)``.
    public func childURL(named filename: String) throws -> URL {
        try prepare()
        return url.appendingPathComponent(filename)
    }

    /// Remove the entire session subdirectory, including any child files.
    /// Safe to call when the directory does not exist (no-op). Errors are
    /// swallowed to keep teardown infallible from the caller's perspective —
    /// orphan cleanup on next launch picks up any residue.
    public func tearDown() {
        try? FileManager.default.removeItem(at: url)
        didPrepare = false
    }
}

// MARK: - Temp File Cleanup

/// Clean orphaned temp files from prior sessions. Called at app launch and on
/// every return to the foreground; idempotent, so repeated calls repeat the
/// same bounded work.
/// Crash-loop scenarios can accumulate large temp files before iOS purges them.
///
/// Known temp entry prefixes (keep in sync with producers):
/// - `recon_`              : intermediate reconstruction temp (legacy path; still
///                             created until routing is fully migrated)
/// - `redacted_`           : pipeline output + export copies (legacy flat path)
/// - `redacted_session_`   : per-session subdirectory (entire subtree
///                             removed on session end; this sweep handles the
///                             crash-orphaned remainder)
/// - `resecta_`            : broadened sweep — also matches all
///                             `resecta_*` temp writes (e.g.
///                             `resecta_audit_*`, `resecta_coverage_*` from
///                             `MatchExportService`, and any future
///                             `resecta_verification_*` writes). Applies the
///                             same 1-hour TTL and cleanup contract
///                             uniformly so app-kill during a share-sheet
///                             dismiss does not leak orphans.
///
/// `liveSessionURLs` names the session directories still in use — the open
/// document's `redacted_session_<UUID>/`, handed in by the app's workspace
/// coordinator. They are skipped whatever their age: a document left open
/// past the TTL keeps its session and its output.
public func cleanOrphanedTempFiles(excluding liveSessionURLs: Set<URL> = []) {
    let tmp = FileManager.default.temporaryDirectory
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: tmp, includingPropertiesForKeys: [.creationDateKey]
    ) else { return }
    let staleThreshold = Date().addingTimeInterval(-3600) // 1 hour
    let livePaths = Set(liveSessionURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
    for url in contents where url.lastPathComponent.hasPrefix("recon_")
                            || url.lastPathComponent.hasPrefix("redacted_")
                            || url.lastPathComponent.hasPrefix("resecta_") {
        if livePaths.contains(url.resolvingSymlinksInPath().standardizedFileURL.path) { continue }
        // `redacted_session_<UUID>` directories are caught by the
        // `redacted_` prefix match above; removeItem handles both files
        // and directories recursively. The `resecta_` arm covers
        // `resecta_audit_*` and `resecta_coverage_*` share-sheet temp
        // files written by `MatchExportService`.
        if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
           date < staleThreshold {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
