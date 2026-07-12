import Foundation

// SEC-2 — Backup exclusion on temp dir.
//
// Per SEC-2, all export-pipeline temp writes live under a per-session
// subdirectory `redacted_session_<UUID>/` inside `FileManager.temporaryDirectory`.
// The subdirectory is flagged with `isExcludedFromBackup = true` at the
// directory level (iCloud's documented unit for the exclusion flag) so the
// transient redacted artifacts are not designed to be carried into iCloud
// or local backups. The entire subdirectory is removed on session end.
//
// This helper owns the lifecycle. SEC-1's `TempFileHardening` (parallel
// sibling) handles per-file protection-class flags; the two are intended to
// be composed at the call sites in `PipelineCoordinator` and the export
// finalize block.
//
// File location note: this type lives in the RedactionEngine package so it
// can be exercised by the engine test suite (`BackupExclusionTests`).
// The kickoff also offered folding into `TempFileHardening`; placing it
// alongside in `Export/` is the reconciliation point.

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
    /// Safe to call repeatedly. Throws on `createDirectory` failure; the
    /// `isExcludedFromBackup` flag is best-effort (logged via `try?`) — if
    /// it cannot be set, the temp write still proceeds rather than blocking
    /// the pipeline.
    @discardableResult
    public func prepare() throws -> URL {
        if didPrepare { return url }
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

    /// Resolve `isExcludedFromBackup` on the directory URL. Returns `nil`
    /// if the resource value cannot be read (e.g., directory does not
    /// exist yet). Test affordance.
    public func isExcludedFromBackup() -> Bool? {
        let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return values?.isExcludedFromBackup
    }
}
