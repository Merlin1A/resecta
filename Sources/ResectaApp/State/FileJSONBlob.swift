import Foundation
import OSLog
import RedactionEngine

// Sibling of `UserDefaultsJSONBlob` for values whose contents warrant
// file-level protection: one JSON file per blob under Application
// Support, written atomically, protected `.complete` via the engine's
// `TempFileHardening` helper (the same `setAttributes` path the export
// temp tree uses — the write-option route does not read back on every
// host), and flagged `isExcludedFromBackup` after every write (an atomic
// replace swaps the underlying file, so both attributes are re-applied
// per save rather than set once). Same envelope/schema-version pattern
// as the UserDefaults sibling: mismatches and decode errors fall through
// to the provided fallback rather than corrupting state.

// nonisolated: a stateless file persistence envelope, usable off-MainActor
// on detached hydrate paths. Keep it out of the SE-0466 MainActor-default
// pinned project-wide (fix-series s04 flip; mirrors UserDefaultsJSONBlob).
// Plain Sendable (not @unchecked): every stored property is Sendable —
// unlike the UserDefaults sibling, which holds a class reference.
nonisolated struct FileJSONBlob<T: Codable & Sendable>: Sendable {
    let fileURL: URL
    let schemaVersion: UInt8
    let fallback: T

    init(fileURL: URL, schemaVersion: UInt8, fallback: T) {
        self.fileURL = fileURL
        self.schemaVersion = schemaVersion
        self.fallback = fallback
    }

    /// Decode the stored value; returns `fallback` on absence, schema
    /// mismatch, or decode error. Never throws — corrupted state should
    /// degrade gracefully rather than break the app.
    func load() -> T {
        guard let data = try? Data(contentsOf: fileURL) else { return fallback }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == schemaVersion else {
                logger.info(
                    "FileJSONBlob[\(self.fileURL.lastPathComponent, privacy: .public)] schema mismatch: stored=\(envelope.schemaVersion), expected=\(self.schemaVersion); using fallback")
                return fallback
            }
            return envelope.payload
        } catch { // LegalPhrases:safe (Swift keyword)
            logger.warning(
                "FileJSONBlob[\(self.fileURL.lastPathComponent, privacy: .public)] decode failed: \(String(describing: error), privacy: .public)")
            return fallback
        }
    }

    /// Serialize and write with the current schema version. Creates the
    /// parent directory as needed. Silent on failure beyond a log line —
    /// mirrors the UserDefaults sibling's degrade-gracefully posture.
    func save(_ value: T) {
        let envelope = Envelope(schemaVersion: schemaVersion, payload: value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(envelope)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
            try TempFileHardening.applyProtection(fileURL, level: .complete)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = fileURL
            try url.setResourceValues(values)
        } catch { // LegalPhrases:safe (Swift keyword)
            logger.warning(
                "FileJSONBlob[\(self.fileURL.lastPathComponent, privacy: .public)] write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Remove the stored file. Subsequent `load()` calls return `fallback`.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private struct Envelope: Codable {
        let schemaVersion: UInt8
        let payload: T
    }
}

// nonisolated: a Sendable Logger referenced from the nonisolated blob methods
// (off-MainActor hydrate path). Globals default to MainActor under the s04 flip.
nonisolated private let logger = Logger(subsystem: "app.resecta", category: "FileJSONBlob")
