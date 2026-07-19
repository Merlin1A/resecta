import Foundation
import RedactionEngine

// App-wide saved regex library — a top-level user preference shared by
// every document and search session.
//
// Built-ins from `SavedRegex.allBuiltIns` merge in-memory at hydrate so
// future built-in additions don't require a migration. Only user-saved
// entries persist to UserDefaults; built-in IDs are stable across
// launches, so any saved-search that referenced a built-in by id keeps
// resolving correctly.

/// Persistence envelope. `schemaVersion = 1` in V1.x. Stored at
/// `UserDefaults` key `savedRegexes.v1`.
// nonisolated: persisted via `UserDefaultsJSONBlob<T: Codable & Sendable>` and
// read off-MainActor; keep its Codable conformance nonisolated under
// the s04 SE-0466 MainActor-default flip (mirrors UserTermsBlob).
nonisolated struct SavedRegexEnvelope: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let userSavedRegexes: [SavedRegex]
    /// Rows the lenient decode could not understand, retained as raw
    /// JSON so `encode` re-emits them (same contract as
    /// `SavedSearchEnvelope.unrecognized`).
    let unrecognized: [RetainedJSONValue]

    init(
        schemaVersion: Int,
        userSavedRegexes: [SavedRegex],
        unrecognized: [RetainedJSONValue] = []
    ) {
        self.schemaVersion = schemaVersion
        self.userSavedRegexes = userSavedRegexes
        self.unrecognized = unrecognized
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, userSavedRegexes
    }

    /// Lenient per-element decode, ported from `SavedSearchEnvelope`:
    /// the previous synthesized decoder failed the WHOLE array on one
    /// malformed element, so a single bad row emptied the user's entire
    /// regex library (and the next persist made the wipe permanent).
    /// One bad row now parks in `unrecognized`; the rest survive.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let wrapped = try container.decode([FailableSavedRegex].self, forKey: .userSavedRegexes)
        self.userSavedRegexes = wrapped.compactMap(\.value)
        self.unrecognized = wrapped.compactMap(\.raw)
    }

    /// Re-splice decoded + retained rows into the one wire array —
    /// shape unchanged, not a schema change.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        var rows = container.nestedUnkeyedContainer(forKey: .userSavedRegexes)
        for regex in userSavedRegexes { try rows.encode(regex) }
        for row in unrecognized { try rows.encode(row) }
    }
}

/// Never-throwing element wrapper for the lenient envelope decode
/// (mirrors `FailableSavedSearch`).
nonisolated private struct FailableSavedRegex: Decodable {
    let value: SavedRegex?
    let raw: RetainedJSONValue?
    init(from decoder: Decoder) {
        if let decoded = try? SavedRegex(from: decoder) {
            self.value = decoded
            self.raw = nil
        } else {
            self.value = nil
            self.raw = try? RetainedJSONValue(from: decoder)
        }
    }
}

@Observable
@MainActor
final class SavedRegexStore {

    // CONC-1 (Pkg N): `nonisolated` constants for the detached-task
    // hydrate path. Compile-time constants, never mutated.
    nonisolated static let storageKey = "savedRegexes.v1"
    nonisolated static let schemaVersion: UInt8 = 1
    nonisolated static let userSavedCap = 100
    nonisolated static let patternLengthCap = SavedRegex.patternLengthCap

    /// Built-in patterns shipped with the app, surfaced in the menu and
    /// library alongside user-saved entries.
    nonisolated static let builtIns: [SavedRegex] = SavedRegex.allBuiltIns

    /// Merged list: built-ins first, then user-saved entries in append
    /// order. Consumed by the saved-regex menu in `SearchToolbarSection`
    /// and by `SavedRegexLibraryView`.
    var regexes: [SavedRegex] {
        Self.builtIns + userSavedRegexes
    }

    /// User-owned entries, persisted to UserDefaults.
    private(set) var userSavedRegexes: [SavedRegex]

    /// Raw rows the lenient hydrate parked (see
    /// `SavedRegexEnvelope.unrecognized`); threaded back into every
    /// `persist()` so a re-save cannot erase them.
    private var unrecognizedRows: [RetainedJSONValue]

    private let blob: UserDefaultsJSONBlob<SavedRegexEnvelope>

    /// Default production init — reads from `UserDefaults.standard`.
    convenience init() {
        self.init(defaults: .standard)
    }

    // Hydration is deliberately synchronous (the former async path
    // published `[]` until a later tick, and the `isHydrated` barrier
    // only stopped the LATE write-back — a mutation landing first still
    // persisted a one-entry envelope over the real library on disk).
    // One small UserDefaults read is not worth that window.
    init(defaults: UserDefaults) {
        self.blob = UserDefaultsJSONBlob(
            key: Self.storageKey,
            schemaVersion: Self.schemaVersion,
            defaults: defaults,
            fallback: SavedRegexEnvelope(schemaVersion: 1, userSavedRegexes: [])
        )
        let envelope = blob.load()
        self.userSavedRegexes = envelope.userSavedRegexes
        self.unrecognizedRows = envelope.unrecognized
    }

    // MARK: - Mutate

    /// Append a user-saved regex. Returns false if the pattern fails
    /// the synchronous safety pre-check, the label/pattern is empty,
    /// the user list is at cap, or the label collides with an existing
    /// entry (built-in or user-saved). Async ReDoS sentinel validation
    /// stays a separate, awaitable seam — callers should run
    /// `RegexSentinelCheck.validate(_:)` BEFORE invoking this method
    /// on user-typed patterns.
    @discardableResult
    func add(label: String, pattern: String) -> Bool {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty, !trimmedPattern.isEmpty else { return false }
        guard trimmedPattern.count <= Self.patternLengthCap else { return false }
        guard userSavedRegexes.count < Self.userSavedCap else { return false }
        guard DocumentSearcher.validateRegexPattern(trimmedPattern) != nil else { return false }
        guard !regexes.contains(where: { $0.label == trimmedLabel }) else { return false }
        userSavedRegexes.append(
            SavedRegex(label: trimmedLabel, pattern: trimmedPattern)
        )
        persist()
        return true
    }

    /// Delete a user-saved regex by id. Built-in ids are a no-op.
    func delete(id: UUID) {
        guard let idx = userSavedRegexes.firstIndex(where: { $0.id == id }) else { return }
        userSavedRegexes.remove(at: idx)
        persist()
    }

    /// Delete user-saved entries at the given offsets within the
    /// `userSavedRegexes` array (NOT within the merged `regexes`).
    /// Used by `List.onDelete` inside `SavedRegexLibraryView`.
    func deleteUserSaved(at offsets: IndexSet) {
        userSavedRegexes.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        blob.save(SavedRegexEnvelope(
            schemaVersion: 1,
            userSavedRegexes: userSavedRegexes,
            unrecognized: unrecognizedRows
        ))
    }
}
