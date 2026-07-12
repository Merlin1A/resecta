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
// read off-MainActor; keep its synthesized Codable conformance nonisolated under
// the s04 SE-0466 MainActor-default flip (mirrors UserTermsBlob).
nonisolated struct SavedRegexEnvelope: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let userSavedRegexes: [SavedRegex]
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

    private let blob: UserDefaultsJSONBlob<SavedRegexEnvelope>

    // Hydration-race barrier (mirrors UserTermsStore). Any mutation
    // (via `persist()`) sets it; the async-hydrate write-back skips once set so
    // a regex saved before hydration completes is not clobbered.
    private var isHydrated = false

    // Async-hydrate task handle for deterministic test awaiting. nil
    // on the synchronous path.
    private(set) var hydrationTask: Task<Void, Never>?

    /// Default production init — reads from `UserDefaults.standard`.
    convenience init() {
        self.init(defaults: .standard, asyncHydrate: true)
    }

    // P2.1: `asyncHydrate` moves the UserDefaults read off the cold-start
    // critical path. Default is false so tests calling `init(defaults:)`
    // keep their synchronous round-trip contract.
    //
    // CONC-1 (Pkg N): the async path runs the UserDefaults read on a
    // detached Task so the decode work happens off-MainActor. The
    // previous `Task { @MainActor in ... }` formulation only deferred
    // the work to a later MainActor tick — it never left the main
    // thread. The detached awaiter hops back to MainActor here to
    // publish the result.
    init(defaults: UserDefaults, asyncHydrate: Bool = false) {
        self.blob = UserDefaultsJSONBlob(
            key: Self.storageKey,
            schemaVersion: Self.schemaVersion,
            defaults: defaults,
            fallback: SavedRegexEnvelope(schemaVersion: 1, userSavedRegexes: [])
        )
        if asyncHydrate {
            self.userSavedRegexes = []
            let captured = self.blob
            self.hydrationTask = Task { @MainActor in
                let hydrated = await Task.detached {
                    SavedRegexStore.loadUserSavedRegexes(from: captured)
                }.value
                self.applyHydration(hydrated)
            }
        } else {
            self.userSavedRegexes = blob.load().userSavedRegexes
            self.isHydrated = true
        }
    }

    /// Publish the async-hydrate snapshot unless a mutation already
    /// superseded it (see `isHydrated`). Internal — not private — so the race
    /// guard is testable without depending on detached-task read timing.
    func applyHydration(_ hydrated: [SavedRegex]) {
        guard !isHydrated else { return }
        userSavedRegexes = hydrated
        isHydrated = true
    }

    /// CONC-1 (Pkg N): nonisolated helper invoked from `Task.detached` so
    /// the UserDefaults decode runs off-MainActor. Pure function of the
    /// blob handle; no MainActor state read.
    nonisolated private static func loadUserSavedRegexes(
        from blob: UserDefaultsJSONBlob<SavedRegexEnvelope>
    ) -> [SavedRegex] {
        blob.load().userSavedRegexes
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
        // A real mutation supersedes any in-flight async-hydrate
        // snapshot; mark hydrated so a late write-back is dropped.
        isHydrated = true
        blob.save(SavedRegexEnvelope(
            schemaVersion: 1,
            userSavedRegexes: userSavedRegexes
        ))
    }
}
