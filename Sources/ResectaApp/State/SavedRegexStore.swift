import Foundation
import RedactionEngine

// App-wide saved regex library — a top-level user preference shared by
// every document and search session.
//
// Built-ins from `SavedRegex.allBuiltIns` merge in-memory at hydrate so
// future built-in additions don't require a migration. Only user-saved
// entries persist — one protected JSON file under Application Support;
// built-in IDs are stable across launches, so any saved-search that
// referenced a built-in by id keeps resolving correctly.

/// Persistence envelope. `schemaVersion = 1` in V1.x. Stored at
/// `Application Support/SavedRegexes/saved-regexes.v1.json` (pre-file
/// installs migrate off the `savedRegexes.v1` `UserDefaults` key once).
// nonisolated: persisted via `FileJSONBlob<T: Codable & Sendable>` and
// read off-MainActor; keep its Codable conformance nonisolated under
// the SE-0466 MainActor-default flip (mirrors UserTermsBlob).
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
        let wrapped = try container.decode([FailableRow<SavedRegex>].self, forKey: .userSavedRegexes)
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

@Observable
@MainActor
final class SavedRegexStore {

    // `nonisolated` constants for the detached-task
    // hydrate path. Compile-time constants, never mutated.
    // `storageKey` is the pre-file `UserDefaults` location, retained as
    // the one-shot migration source (see `migrateLegacyDefaultsIfNeeded`).
    nonisolated static let storageKey = "savedRegexes.v1"
    nonisolated static let schemaVersion: UInt8 = 1
    nonisolated static let userSavedCap = 100
    nonisolated static let patternLengthCap = SavedRegex.patternLengthCap

    /// Production file location: one JSON file under Application
    /// Support, written with `.completeFileProtection` and excluded
    /// from backups by `FileJSONBlob` on every save — the same posture
    /// `SavedSearchStore` established for persisted user data.
    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SavedRegexes", isDirectory: true)
            .appendingPathComponent("saved-regexes.v1.json")
    }

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

    private let blob: FileJSONBlob<SavedRegexEnvelope>

    /// The file is there and could not be read: the store shows no saved
    /// entries, writes nothing and answers every change `held` until a read
    /// succeeds.
    private var isHeld: Bool

    @ObservationIgnored private var readAgain: NoticeObservers?

    /// Default production init — reads the Application Support file.
    convenience init() {
        self.init(fileURL: Self.defaultFileURL)
    }

    // Hydration is deliberately synchronous (the former async path
    // published `[]` until a later tick, and the `isHydrated` barrier
    // only stopped the LATE write-back — a mutation landing first still
    // persisted a one-entry envelope over the real library on disk).
    // One small file read is not worth that window. The one-shot legacy
    // migration runs first for the same reason — it must complete
    // before the hydrate read, and it is a no-op on every launch after
    // the first (the legacy key is removed once migrated).
    init(fileURL: URL, legacyDefaults: UserDefaults = .standard) {
        self.blob = FileJSONBlob(
            fileURL: fileURL,
            schemaVersion: Self.schemaVersion,
            fallback: SavedRegexEnvelope(schemaVersion: 1, userSavedRegexes: [])
        )
        blob.migrateLegacyDefaultsIfNeeded(from: legacyDefaults, key: Self.storageKey)
        // A file that is there and cannot be read holds the store; it reads
        // again when the app comes to the front, when protected files become
        // available, and at the start of every change.
        let opened = blob.storeValue(blob.readAtOpen())
        let envelope = opened ?? blob.fallback
        self.userSavedRegexes = envelope.userSavedRegexes
        self.unrecognizedRows = envelope.unrecognized
        self.isHeld = opened == nil
        self.readAgain = NoticeObservers(StoreReadAgain.notices) { [weak self] in
            _ = self?.loadIfHeld()
        }
    }

    /// While held, read the file again. True when the store takes changes.
    private func loadIfHeld() -> Bool {
        guard isHeld else { return true }
        guard let envelope = blob.storeValue(blob.read()) else { return false }
        userSavedRegexes = envelope.userSavedRegexes
        unrecognizedRows = envelope.unrecognized
        isHeld = false
        return true
    }

    // MARK: - Mutate

    /// Append a user-saved regex. Refused if the pattern fails
    /// the synchronous safety pre-check, the label/pattern is empty,
    /// the user list is at cap, or the label collides with an existing
    /// entry (built-in or user-saved). Async ReDoS sentinel validation
    /// stays a separate, awaitable seam — callers should run
    /// `RegexSentinelCheck.validate(_:)` BEFORE invoking this method
    /// on user-typed patterns.
    @discardableResult
    func add(label: String, pattern: String) -> ListChange {
        guard loadIfHeld() else { return .held }
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty, !trimmedPattern.isEmpty else { return .refused(.invalid) }
        guard trimmedPattern.count <= Self.patternLengthCap else { return .refused(.invalid) }
        guard userSavedRegexes.count < Self.userSavedCap else { return .refused(.full) }
        guard DocumentSearcher.validateRegexPattern(trimmedPattern) != nil else { return .refused(.invalid) }
        guard !regexes.contains(where: { $0.label == trimmedLabel }) else { return .refused(.duplicate) }
        let next = userSavedRegexes + [SavedRegex(label: trimmedLabel, pattern: trimmedPattern)]
        guard persist(next, unrecognizedRows) else { return .notSaved }
        userSavedRegexes = next
        return .saved
    }

    /// Delete user-saved entries at the given offsets within the
    /// `userSavedRegexes` array (NOT within the merged `regexes`).
    /// Used by `List.onDelete` inside `SavedRegexLibraryView`.
    @discardableResult
    func deleteUserSaved(at offsets: IndexSet) -> ListChange {
        guard loadIfHeld() else { return .held }
        var next = userSavedRegexes
        next.remove(atOffsets: offsets)
        guard persist(next, unrecognizedRows) else { return .notSaved }
        userSavedRegexes = next
        return .saved
    }

    /// Remove every user-saved entry and persist the empty library.
    /// Built-ins are compile-time constants and unaffected. The parked
    /// `unrecognized` rows are dropped too: their retention contract
    /// protects them from UNRELATED saves, and an explicit
    /// delete-everything request is the one save that should not
    /// re-emit them. Backs the destructive "Delete All Your Patterns"
    /// row in `SavedRegexLibraryView`.
    @discardableResult
    func clearAllUserSaved() -> ListChange {
        guard loadIfHeld() else { return .held }
        guard persist([], []) else { return .notSaved }
        userSavedRegexes = []
        unrecognizedRows = []
        return .saved
    }

    /// Write the next library to the file; true when the file holds it.
    /// Changes no state.
    private func persist(_ regexes: [SavedRegex], _ unrecognized: [RetainedJSONValue]) -> Bool {
        blob.save(SavedRegexEnvelope(
            schemaVersion: 1,
            userSavedRegexes: regexes,
            unrecognized: unrecognized
        ))
    }
}
