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
        // Sweep temp-file orphans from an interrupted `save` (a crash
        // between the temp write and the replace leaves a stray
        // `.{name}.tmp-*` sibling that would otherwise persist forever).
        let dir = fileURL.deletingLastPathComponent()
        let orphanPrefix = ".\(fileURL.lastPathComponent).tmp-"
        if let siblings = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in siblings where name.hasPrefix(orphanPrefix) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
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
    /// parent directory as needed. The temp file carries
    /// `.completeFileProtection` and the backup-exclusion flag BEFORE
    /// the atomic replace, so no crash window exists in which a
    /// complete, correctly-named file sits under the directory's
    /// default attributes. Silent on failure beyond a log line —
    /// mirrors the UserDefaults sibling's degrade-gracefully posture.
    func save(_ value: T) {
        let envelope = Envelope(schemaVersion: schemaVersion, payload: value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let tmpURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            let data = try encoder.encode(envelope)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: tmpURL, options: [.completeFileProtection])
            var tmpValues = URLResourceValues()
            tmpValues.isExcludedFromBackup = true
            var tmp = tmpURL
            try tmp.setResourceValues(tmpValues)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }
            // Re-assert on the final URL — the engine-helper route does
            // not read attributes back on every host, and the belt keeps
            // the previous per-save re-application contract.
            try TempFileHardening.applyProtection(fileURL, level: .complete)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = fileURL
            try url.setResourceValues(values)
        } catch { // LegalPhrases:safe (Swift keyword)
            try? FileManager.default.removeItem(at: tmpURL)
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

/// Raw JSON tree for envelope rows the current decoder cannot
/// understand. Lenient per-element envelope decodes park such rows here
/// so a later save re-emits them instead of erasing them: a
/// temporarily-undecodable row (e.g. future-version skew) must survive
/// unrelated saves, or the lenient read's "one bad row never zeroes the
/// list" guarantee quietly becomes "one bad row vanishes at the next
/// save". Numbers carry as `Double` — adequate for every field the
/// saved-search / saved-regex schemas persist. Bool is probed before
/// number so `true` cannot coerce through NSNumber bridging.
nonisolated enum RetainedJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RetainedJSONValue])
    case object([String: RetainedJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RetainedJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RetainedJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON shape"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
