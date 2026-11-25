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

    /// The file is there and could not be read: the store shows the empty
    /// list, writes nothing and answers every change `held` until a read
    /// succeeds.
    private var isHeld: Bool

    @ObservationIgnored private var readAgain: NoticeObservers?

    /// Default production init — reads the Application Support file.
    convenience init() {
        self.init(fileURL: Self.defaultFileURL)
    }

    // The file is read and cleaned here, synchronously, on purpose: the
    // store holds the stored lists from its first moment, so no change
    // (and no scan) can act on an empty list before a delayed read lands.
    // The one-time move of the old settings record runs first, before the
    // read, as it always has. A file that is there and cannot be read holds
    // the store; it reads again when the app comes to the front, when
    // protected files become available, and at the start of every change.
    init(fileURL: URL, legacyDefaults: UserDefaults = .standard) {
        self.storage = FileJSONBlob(
            fileURL: fileURL,
            schemaVersion: Self.schemaVersion,
            fallback: .empty
        )
        storage.migrateLegacyDefaultsIfNeeded(from: legacyDefaults, key: Self.storageKey)
        let opened = storage.storeValue(storage.readAtOpen())
        self.blob = Self.sanitize(opened ?? .empty)
        self.isHeld = opened == nil
        self.readAgain = NoticeObservers(StoreReadAgain.notices) { [weak self] in
            _ = self?.loadIfHeld()
        }
    }

    /// While held, read the file again. True when the store takes changes.
    private func loadIfHeld() -> Bool {
        guard isHeld else { return true }
        guard let value = storage.storeValue(storage.read()) else { return false }
        blob = Self.sanitize(value)
        isHeld = false
        return true
    }

    // MARK: - Mutate

    @discardableResult
    func addAlwaysFlag(_ term: UserTerm) -> ListChange {
        guard loadIfHeld() else { return .held }
        guard Self.isValidUserTerm(term) else { return .refused(.invalid) }
        guard blob.alwaysFlag.count < Self.perListCap else { return .refused(.full) }
        guard !blob.alwaysFlag.contains(term) else { return .refused(.duplicate) }
        var next = blob
        next.alwaysFlag.append(term)
        guard persist(next) else { return .notSaved }
        blob = next
        return .saved
    }

    @discardableResult
    func addNeverFlag(_ term: UserTerm) -> ListChange {
        guard loadIfHeld() else { return .held }
        guard Self.isValidUserTerm(term) else { return .refused(.invalid) }
        guard blob.neverFlag.count < Self.perListCap else { return .refused(.full) }
        guard !blob.neverFlag.contains(term) else { return .refused(.duplicate) }
        var next = blob
        next.neverFlag.append(term)
        guard persist(next) else { return .notSaved }
        blob = next
        return .saved
    }

    @discardableResult
    func removeAlwaysFlag(at indices: IndexSet) -> ListChange {
        guard loadIfHeld() else { return .held }
        var next = blob
        next.alwaysFlag.remove(atOffsets: indices)
        guard persist(next) else { return .notSaved }
        blob = next
        return .saved
    }

    @discardableResult
    func removeNeverFlag(at indices: IndexSet) -> ListChange {
        guard loadIfHeld() else { return .held }
        var next = blob
        next.neverFlag.remove(atOffsets: indices)
        guard persist(next) else { return .notSaved }
        blob = next
        return .saved
    }

    /// Remove every term from both lists and persist the empty pair.
    /// Backs the destructive "Delete All Custom Terms" row in
    /// `CustomTermsView`; the row's confirmation copy names exactly this
    /// scope (both lists, this store only).
    @discardableResult
    func clearAllTerms() -> ListChange {
        guard loadIfHeld() else { return .held }
        guard persist(.empty) else { return .notSaved }
        blob = .empty
        return .saved
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

    /// Write `next` to the file; true when the file holds it. Changes no state.
    private func persist(_ next: UserTermsBlob) -> Bool {
        storage.save(next)
    }
}
