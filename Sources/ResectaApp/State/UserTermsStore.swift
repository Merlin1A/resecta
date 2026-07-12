import Foundation
import RedactionEngine

// App-wide always-flag / never-flag custom keyword lists — a top-level
// user preference shared by every document and search session. The blob
// shape is the input to `DocumentSearcher.setUserTerms(_:)`, so the
// scan-kickoff seam reads this store directly without remapping.

/// Persisted always-flag / never-flag list pair. Composed into the
/// existing `UserTermsIndex.compile(alwaysFlag:neverFlag:)` engine seam
/// at scan kickoff.
// nonisolated: a Sendable value blob persisted via the generic
// `UserDefaultsJSONBlob<T: Codable & Sendable>` and read off-MainActor on the
// detached hydrate path. Under SE-0466 MainActor-default (fix-series s04 flip)
// the synthesized Decodable conformance would become main-actor-isolated and
// fail the Sendable generic bound — keep the whole type nonisolated.
nonisolated struct UserTermsBlob: Codable, Sendable, Equatable {
    var alwaysFlag: [UserTerm]
    var neverFlag: [UserTerm]
    static let empty = UserTermsBlob(alwaysFlag: [], neverFlag: [])
}

@Observable
@MainActor
final class UserTermsStore {

    // CONC-1 (Pkg N): `nonisolated` so the detached-task hydrate path
    // can read these constants off-MainActor. They are compile-time
    // constants and never mutated, so opting out of @MainActor isolation
    // here is sound.
    nonisolated static let storageKey = "userTerms.v1"
    nonisolated static let schemaVersion: UInt8 = 1
    nonisolated static let perListCap = 100
    nonisolated static let patternLengthCap = 200

    /// Composed envelope read by the engine via
    /// `DocumentSearcher.setUserTerms(_:)`.
    private(set) var blob: UserTermsBlob

    private let storage: UserDefaultsJSONBlob<UserTermsBlob>

    // Hydration-race barrier. The async-hydrate write-back must not
    // clobber a term the user adds in the window between the detached snapshot
    // and the MainActor write-back. Any mutation (via `persist()`) sets this,
    // and `applyHydration` skips once it is set — storage is already
    // authoritative because `persist()` wrote the user's change.
    private var isHydrated = false

    // Handle to the async-hydrate task so tests can deterministically
    // await the write-back attempt. nil on the synchronous path.
    private(set) var hydrationTask: Task<Void, Never>?

    /// Default production init — reads from `UserDefaults.standard`.
    convenience init() {
        self.init(defaults: .standard, asyncHydrate: true)
    }

    // P2.1: `asyncHydrate` moves the UserDefaults read + sanitize off the
    // cold-start critical path. Default is false so tests calling
    // `init(defaults:)` keep their synchronous contract.
    //
    // CONC-1 (Pkg N): the async path runs the UserDefaults read and
    // `sanitize` on a detached Task so the work happens off-MainActor.
    // The previous `Task { @MainActor in ... }` formulation only
    // deferred the work to a later MainActor tick — it never left the
    // main thread. The detached awaiter hops back to MainActor here
    // to publish the result.
    init(defaults: UserDefaults, asyncHydrate: Bool = false) {
        self.storage = UserDefaultsJSONBlob(
            key: Self.storageKey,
            schemaVersion: Self.schemaVersion,
            defaults: defaults,
            fallback: .empty
        )
        if asyncHydrate {
            self.blob = .empty
            let captured = self.storage
            self.hydrationTask = Task { @MainActor in
                let hydrated = await Task.detached {
                    UserTermsStore.loadAndSanitize(from: captured)
                }.value
                self.applyHydration(hydrated)
            }
        } else {
            let loaded = storage.load()
            self.blob = Self.sanitize(loaded)
            self.isHydrated = true
        }
    }

    /// Publish the async-hydrate snapshot unless a mutation already
    /// superseded it (see `isHydrated`). Internal — not private — so the race
    /// guard is testable without depending on detached-task read timing.
    func applyHydration(_ hydrated: UserTermsBlob) {
        guard !isHydrated else { return }
        blob = hydrated
        isHydrated = true
    }

    /// CONC-1 (Pkg N): nonisolated helper invoked from `Task.detached` so
    /// the UserDefaults read and the `sanitize` pass run off-MainActor.
    /// Pure function of the storage handle; no MainActor state read.
    nonisolated private static func loadAndSanitize(
        from storage: UserDefaultsJSONBlob<UserTermsBlob>
    ) -> UserTermsBlob {
        sanitize(storage.load())
    }

    // MARK: - Mutate

    @discardableResult
    func addAlwaysFlag(_ term: UserTerm) -> Bool {
        guard Self.isValidUserTerm(term) else { return false }
        guard blob.alwaysFlag.count < Self.perListCap else { return false }
        guard !blob.alwaysFlag.contains(term) else { return false }
        blob.alwaysFlag.append(term)
        persist()
        return true
    }

    @discardableResult
    func addNeverFlag(_ term: UserTerm) -> Bool {
        guard Self.isValidUserTerm(term) else { return false }
        guard blob.neverFlag.count < Self.perListCap else { return false }
        guard !blob.neverFlag.contains(term) else { return false }
        blob.neverFlag.append(term)
        persist()
        return true
    }

    func removeAlwaysFlag(at indices: IndexSet) {
        blob.alwaysFlag.remove(atOffsets: indices)
        persist()
    }

    func removeNeverFlag(at indices: IndexSet) {
        blob.neverFlag.remove(atOffsets: indices)
        persist()
    }

    // MARK: - Validation

    /// Accept the term if it passes length + (optional) regex validation.
    /// CONC-1 (Pkg N): `nonisolated` so the detached-task hydrate path
    /// (via `sanitize`) can call this off-MainActor. Pure function —
    /// reads only its argument and the `nonisolated` constants above.
    nonisolated static func isValidUserTerm(_ term: UserTerm) -> Bool {
        guard !term.pattern.isEmpty else { return false }
        guard term.pattern.count <= patternLengthCap else { return false }
        if term.isRegex {
            return DocumentSearcher.validateRegexPattern(term.pattern) != nil
        }
        return true
    }

    /// Drop invalid entries and cap each list at `perListCap`. Used on
    /// hydrate so a corrupted or out-of-date blob can't leak invalid
    /// terms into a scan.
    ///
    /// CONC-1 (Pkg N): `nonisolated` so the detached-task hydrate path
    /// can call this off-MainActor. The function is pure — reads only
    /// its argument and the `nonisolated` validator helper below.
    nonisolated static func sanitize(_ blob: UserTermsBlob) -> UserTermsBlob {
        UserTermsBlob(
            alwaysFlag: Array(
                blob.alwaysFlag.filter(isValidUserTerm).prefix(perListCap)
            ),
            neverFlag: Array(
                blob.neverFlag.filter(isValidUserTerm).prefix(perListCap)
            )
        )
    }

    private func persist() {
        // A real mutation supersedes any in-flight async-hydrate
        // snapshot; mark hydrated so a late write-back is dropped.
        isHydrated = true
        storage.save(blob)
    }
}
