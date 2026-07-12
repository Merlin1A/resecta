import Foundation

// SEC-1 — File protection on temp output.
//
// Helper for setting iOS Data Protection class on URLs in the temp tree.
// Producers (PipelineCoordinator, PDFStreamReconstructor, export copy site)
// call applyProtection(_:level:) after every write or copy. Caller flips the
// effective level via TempFileProtection on document close so background
// cleanup (e.g., cleanOrphanedTempFiles) can still remove files after the
// device locks. Mechanism-description language per ARCH §1.3 / shared §4 (I6):
// this helper sets a level that is designed to reduce at-rest exposure on a
// locked device; it is a best-effort hardening, not an outcome promise.

/// Effective protection level for files in the temp tree.
///
/// `.complete` while a redaction session is live keeps temp output unreadable
/// while the device is locked. Downgrading to
/// `.completeUntilFirstUserAuthentication` on document close keeps protection
/// across reboots but allows background cleanup utilities (which can run while
/// the device is locked after first unlock) to access stale files.
public enum TempFileProtection: Sendable {
    case complete
    case completeUntilFirstUserAuthentication

    /// Map to the Foundation `FileProtectionType` value used by
    /// `FileManager.setAttributes(_:ofItemAtPath:)`. Foundation surfaces the
    /// read side via `URLResourceValues.fileProtection` (`URLFileProtection`)
    /// but the write side goes through `FileAttributeKey.protectionKey`
    /// with a `FileProtectionType` — the URL setter is read-only in the
    /// public API.
    public var fileProtectionType: FileProtectionType {
        switch self {
        case .complete:
            return .complete
        case .completeUntilFirstUserAuthentication:
            return .completeUntilFirstUserAuthentication
        }
    }

    /// Map to the corresponding `URLFileProtection` value for read-back
    /// comparisons via `URLResourceValues.fileProtection`.
    public var urlFileProtection: URLFileProtection {
        switch self {
        case .complete:
            return .complete
        case .completeUntilFirstUserAuthentication:
            return .completeUntilFirstUserAuthentication
        }
    }
}

/// Namespace for temp-file hardening helpers. Engine-side so producers in
/// both the engine package and the app target can call the same code path.
public enum TempFileHardening {
    /// Apply a file-protection level to `url`. Caller is responsible for
    /// invoking this after every write or copy into the temp tree.
    ///
    /// The write path uses `FileManager.setAttributes(_:ofItemAtPath:)`
    /// with `FileAttributeKey.protectionKey` and a `FileProtectionType`
    /// value — the Foundation API for changing the Data Protection class
    /// after a file is created. (`URLResourceValues.fileProtection` is
    /// read-only in the public API; assigning via `setResourceValues` is
    /// not supported.) No third-party framework dependency.
    ///
    /// - Throws: rethrows any error from `FileManager.setAttributes` (e.g.,
    ///   the file does not exist or the underlying filesystem does not
    ///   support the protection class).
    public static func applyProtection(
        _ url: URL,
        level: TempFileProtection
    ) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: level.fileProtectionType],
            ofItemAtPath: url.path
        )
    }

    /// Read back the current file-protection level. Returns `nil` if the
    /// filesystem does not report a value (e.g., on the macOS test host,
    /// where the resource key is not populated). On iOS this resolves to
    /// the current `URLFileProtection` value for the file.
    public static func currentProtection(of url: URL) throws -> URLFileProtection? {
        let values = try url.resourceValues(forKeys: [.fileProtectionKey])
        return values.fileProtection
    }

    /// Walk a directory and downgrade every regular file to the supplied
    /// level. Used on document close (`.completeUntilFirstUserAuthentication`)
    /// so the launch-time cleanup path can still remove stale temp files
    /// after the device is locked. Errors on individual files are swallowed
    /// — best-effort traversal — but caller may observe the first thrown
    /// error from the top-level enumerator if the root is unreadable.
    public static func downgradeTree(
        at root: URL,
        to level: TempFileProtection
    ) {
        let fm = FileManager.default
        // If the root itself is a file, just downgrade it.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { return }
        if !isDir.boolValue {
            try? applyProtection(root, level: level)
            return
        }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile ?? false
            guard isRegular else { continue }
            try? applyProtection(fileURL, level: level)
        }
    }
}
