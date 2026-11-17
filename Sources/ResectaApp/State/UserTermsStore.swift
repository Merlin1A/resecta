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
// `FileJSONBlob<T: Codable & Sendable>`. Under SE-0466 MainActor-default
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

    // `nonisolated` so the pure validation helpers below can read these
    // constants without the main actor. They are compile-time
    // constants and never mutated, so opting out of @MainActor isolation
    // here is sound.
    // `storageKey` is the pre-file `UserDefaults` location, retained as
    // the one-shot migration source (see `migrateLegacyDefaultsIfNeeded`).
    nonisolated static let storageKey = "userTerms.v1"
    nonisolated static let schemaVersion: UInt8 = 1
    nonisolated static let perListCap = 100
    nonisolated static let patternLengthCap = 200

    /// Production file location: one JSON file under Application
    /// Support, written with `.completeFileProtection` and excluded
    /// from backups by `FileJSONBlob` on every save — the same posture
    /// `SavedSearchStore` established for persisted user data.
    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UserTerms", isDirectory: true)
            .appendingPathComponent("user-terms.v1.json")
    }

    /// Composed envelope read by the engine via
    /// `DocumentSearcher.setUserTerms(_:)`.
    private(set) var blob: UserTermsBlob

    private let storage: FileJSONBlob<UserTermsBlob>

    /// Default production init — reads the Application Support file.
    convenience init() {
        self.init(fileURL: Self.defaultFileURL)
    }

    // The file is read and cleaned here, synchronously, on purpose: the
    // store holds the stored lists from its first moment, so no change
    // (and no scan) can act on an empty list before a delayed read lands.
    // The one-time move of the old settings record runs first, before the
    // read, as it always has.
    init(fileURL: URL, legacyDefaults: UserDefaults = .standard) {
        self.storage = FileJSONBlob(
            fileURL: fileURL,
            schemaVersion: Self.schemaVersion,
            fallback: .empty
        )
        storage.migrateLegacyDefaultsIfNeeded(from: legacyDefaults, key: Self.storageKey)
        self.blob = Self.sanitize(storage.load())
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

    /// Remove every term from both lists and persist the empty pair.
    /// Backs the destructive "Delete All Custom Terms" row in
    /// `CustomTermsView`; the row's confirmation copy names exactly this
    /// scope (both lists, this store only).
    func clearAllTerms() {
        blob = .empty
        persist()
    }

    // MARK: - Validation

    /// Accept the term if it passes length (a literal floor of
    /// `literalMinimumLength` scalars, the `patternLengthCap` ceiling) +
    /// (optional) regex validation.
    /// `nonisolated`: a pure function — it reads only its argument and
    /// the `nonisolated` constants above, so it needs no main actor.
    /// The shortest literal term, in Unicode scalars: a one-character
    /// literal matches inside nearly every word and fills a scan with
    /// matches before its later pages are read.
    nonisolated static let literalMinimumLength = 2

    nonisolated static func isValidUserTerm(_ term: UserTerm) -> Bool {
        guard !term.pattern.isEmpty else { return false }
        guard term.isRegex || term.pattern.unicodeScalars.count >= literalMinimumLength else { return false }
        guard term.pattern.count <= patternLengthCap else { return false }
        if term.isRegex {
            return DocumentSearcher.validateRegexPattern(term.pattern) != nil
        }
        return true
    }

    /// Drop invalid entries and cap each list at `perListCap`. Used when
    /// the file is read so a corrupted or out-of-date blob can't leak
    /// invalid terms into a scan.
    ///
    /// `nonisolated`: the function is pure — it reads only its argument
    /// and the `nonisolated` validator helper above.
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
        storage.save(blob)
    }
}
