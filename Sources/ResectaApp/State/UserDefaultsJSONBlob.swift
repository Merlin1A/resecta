import Foundation
import OSLog

// W4 — reusable envelope for persisting structured Codable values in
// UserDefaults with a schema-version byte. Shared by W3 (user terms),
// W4 (per-category threshold overrides), and W6 (saved regex library).
//
// Schema mismatches and decode errors fall through to the provided
// fallback rather than corrupting state. No automatic migration is
// attempted in v1 — future schema versions can add migration logic
// inside `load()` by branching on `envelope.schemaVersion`.

// nonisolated: a stateless UserDefaults persistence envelope used off-MainActor
// on detached hydrate paths (e.g. UserTermsStore.loadAndSanitize). Keep it out
// of the SE-0466 MainActor-default pinned project-wide (fix-series s04 flip).
nonisolated struct UserDefaultsJSONBlob<T: Codable & Sendable>: @unchecked Sendable {
    let key: String
    let schemaVersion: UInt8
    let defaults: UserDefaults
    let fallback: T

    init(
        key: String,
        schemaVersion: UInt8,
        defaults: UserDefaults = .standard,
        fallback: T
    ) {
        self.key = key
        self.schemaVersion = schemaVersion
        self.defaults = defaults
        self.fallback = fallback
    }

    /// Decode the stored value; returns `fallback` on absence, schema
    /// mismatch, or decode error. Never throws — corrupted state should
    /// degrade gracefully rather than break the app.
    func load() -> T {
        guard let data = defaults.data(forKey: key) else { return fallback }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == schemaVersion else {
                logger.info(
                    "UserDefaultsJSONBlob[\(self.key, privacy: .public)] schema mismatch: stored=\(envelope.schemaVersion), expected=\(self.schemaVersion); using fallback")
                return fallback
            }
            return envelope.payload
        } catch {
            logger.warning(
                "UserDefaultsJSONBlob[\(self.key, privacy: .public)] decode failed: \(String(describing: error), privacy: .public)")
            return fallback
        }
    }

    /// Serialize and write with the current schema version. Silent on
    /// failure (disk pressure / encoder bug) — UserDefaults itself does
    /// not throw.
    func save(_ value: T) {
        let envelope = Envelope(schemaVersion: schemaVersion, payload: value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(envelope)
            defaults.set(data, forKey: key)
        } catch {
            logger.warning(
                "UserDefaultsJSONBlob[\(self.key, privacy: .public)] encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Remove the stored value. Subsequent `load()` calls return `fallback`.
    func clear() {
        defaults.removeObject(forKey: key)
    }

    private struct Envelope: Codable {
        let schemaVersion: UInt8
        let payload: T
    }
}

// nonisolated: a Sendable Logger referenced from the nonisolated blob methods
// (off-MainActor hydrate path). Globals default to MainActor under the s04 flip.
nonisolated private let logger = Logger(subsystem: "app.resecta", category: "UserDefaultsJSONBlob")
