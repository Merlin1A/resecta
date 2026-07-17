import Foundation
import OSLog
import RedactionEngine

// MARK: - Raw key helper for fail-closed decoders

/// Accepts any string key. Used by `SavedSearch` to walk the JSON's
/// actual key set on the first pass — a typed
/// `KeyedDecodingContainer<CodingKeys>` only surfaces keys that match
/// the typed enum, so foreign ("forbidden") keys never appear via
/// `.allKeys` on the typed container.
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// `SavedSearchStore` is the single named departure from `SearchState`
// ephemerality (a deliberate exception).
// Persists query *shape* only — mode, query text, search terms,
// enabled categories, matching options, filter shape, threshold floors.
// Never persists matched text, page indices, applied IDs, OCR
// confidences, or any document-derived data. Storage is one JSON file
// under Application Support (protected + backup-excluded via
// `FileJSONBlob`); the pre-v2 UserDefaults blob is removed on init.
//
// The decoder fails closed on unknown keys
// — `init(from:)` walks the keyed container's `allKeys` against an
// explicit whitelist and throws `DecodingError.dataCorruptedError` on
// any mismatch. The forbidden-key list is enumerated for exhaustive
// positive coverage in `SavedSearchStoreTests.decoderRejectsForbiddenKeys`
// per [RR-43](RISK_REGISTER.md#rr-43).
//
// The consuming UI shipped in V1.0: `SavedSearchListSheet`
// lists / recalls / renames / deletes entries, plus the
// toolbar "Save as…" entry point in `SearchAndRedactSheet`.

// MARK: - SavedSearch shape

// nonisolated: a pure persisted value type (query *shape* only — see the file
// header) whose `Equatable` conformance is compared element-wise inside the
// `nonisolated SavedSearchEnvelope`. Under the s04 SE-0466 MainActor-default flip
// an unannotated app-target type's conformance becomes MainActor-isolated and
// cannot be used from the nonisolated envelope; pin the type nonisolated (the
// engine's sibling `SavedRegex` is already nonisolated as an SPM-package type).
nonisolated struct SavedSearch: Codable, Identifiable, Sendable, Equatable {
    /// 200-char cap on the user-visible name. Mirrored across the
    /// memberwise init, `SavedSearchStore.rename(id:to:)`, and the
    /// `init(from:)` decoder so a tampered or out-of-band-edited
    /// payload cannot smuggle an oversize name past the schema floor
    /// (Pkg G.2 — TRUST-savedsearch-name-no-cap).
    static let nameLengthCap = 200

    let id: UUID
    let name: String
    let mode: SearchModeType
    let queryText: String?
    let searchTerms: [String]?
    let enabledPIICategories: Set<PIICategory>?
    let caseSensitive: Bool
    let wholeWord: Bool
    let sourceFilter: SourceFilter
    let minimumOCRConfidence: Float
    let minimumPIIConfidence: Double
    // Normalization-extension flags are query
    // *shape* (no document-derived data), so they join the whitelist
    // (11 → 14 keys). Decoded with `decodeIfPresent` + the engine
    // defaults so pre-S7 blobs hydrate unchanged.
    let stripDigitSeparators: Bool
    let normalizeSmartPunctuation: Bool
    let foldDiacritics: Bool
    // Schema v2 completes the option round-trip: the two remaining
    // sheet-settable options join the whitelist (14 → 16 keys). Both are
    // query *shape*; decoded with `decodeIfPresent` + the engine defaults
    // (same idiom as the normalization trio).
    let includeOCR: Bool
    let multiTermConjunction: Bool

    init(
        id: UUID = UUID(),
        name: String,
        mode: SearchModeType,
        queryText: String? = nil,
        searchTerms: [String]? = nil,
        enabledPIICategories: Set<PIICategory>? = nil,
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        sourceFilter: SourceFilter = .all,
        minimumOCRConfidence: Float = 0.0,
        minimumPIIConfidence: Double = 0.50,
        stripDigitSeparators: Bool = false,
        normalizeSmartPunctuation: Bool = true,
        foldDiacritics: Bool = false,
        includeOCR: Bool = true,
        multiTermConjunction: Bool = false
    ) {
        self.id = id
        self.name = String(name.prefix(Self.nameLengthCap))
        self.mode = mode
        self.queryText = queryText
        self.searchTerms = searchTerms
        self.enabledPIICategories = enabledPIICategories
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.sourceFilter = sourceFilter
        self.minimumOCRConfidence = minimumOCRConfidence
        self.minimumPIIConfidence = minimumPIIConfidence
        self.stripDigitSeparators = stripDigitSeparators
        self.normalizeSmartPunctuation = normalizeSmartPunctuation
        self.foldDiacritics = foldDiacritics
        self.includeOCR = includeOCR
        self.multiTermConjunction = multiTermConjunction
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, mode
        case queryText, searchTerms, enabledPIICategories
        case caseSensitive, wholeWord
        case sourceFilter, minimumOCRConfidence, minimumPIIConfidence
        case stripDigitSeparators, normalizeSmartPunctuation, foldDiacritics
        case includeOCR, multiTermConjunction
    }

    /// Whitelist for the fail-closed decoder. Every key the schema
    /// accepts is enumerated here; any key NOT in this set causes
    /// `DecodingError.dataCorruptedError`.
    fileprivate static let allowedKeys: Set<String> = Set(
        CodingKeys.allCases.map(\.stringValue)
    )

    init(from decoder: Decoder) throws {
        // First pass: walk every key in the JSON via AnyCodingKey and
        // reject any that isn't in the SavedSearch whitelist. The
        // typed CodingKeys container would silently drop foreign
        // keys — `.allKeys` on it only surfaces typed members.
        let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
        for key in rawContainer.allKeys {
            guard Self.allowedKeys.contains(key.stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: rawContainer,
                    debugDescription: "SavedSearch unknown key '\(key.stringValue)' per [D-25]"
                )
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        // Pkg G.2 — TRUST-savedsearch-name-no-cap. Mirrors the
        // memberwise init's `.prefix(nameLengthCap)` clamp so a
        // tampered persisted blob can't bypass the 200-char floor.
        let rawName = try container.decode(String.self, forKey: .name)
        self.name = String(rawName.prefix(Self.nameLengthCap))
        self.mode = try container.decode(SearchModeType.self, forKey: .mode)
        self.queryText = try container.decodeIfPresent(String.self, forKey: .queryText)
        self.searchTerms = try container.decodeIfPresent([String].self, forKey: .searchTerms)
        self.enabledPIICategories = try container.decodeIfPresent(Set<PIICategory>.self, forKey: .enabledPIICategories)
        self.caseSensitive = try container.decode(Bool.self, forKey: .caseSensitive)
        self.wholeWord = try container.decode(Bool.self, forKey: .wholeWord)
        self.sourceFilter = try container.decode(SourceFilter.self, forKey: .sourceFilter)
        self.minimumOCRConfidence = try container.decode(Float.self, forKey: .minimumOCRConfidence)
        self.minimumPIIConfidence = try container.decode(Double.self, forKey: .minimumPIIConfidence)
        // S7 — absent in pre-S7 blobs; fall back to the engine defaults.
        self.stripDigitSeparators = try container.decodeIfPresent(Bool.self, forKey: .stripDigitSeparators) ?? false
        self.normalizeSmartPunctuation = try container.decodeIfPresent(Bool.self, forKey: .normalizeSmartPunctuation) ?? true
        self.foldDiacritics = try container.decodeIfPresent(Bool.self, forKey: .foldDiacritics) ?? false
        // Schema v2 option round-trip — engine defaults on absence.
        self.includeOCR = try container.decodeIfPresent(Bool.self, forKey: .includeOCR) ?? true
        self.multiTermConjunction = try container.decodeIfPresent(Bool.self, forKey: .multiTermConjunction) ?? false
    }
}

// MARK: - Persistence envelope

/// Wraps the saved-search list with a schema version. `schemaVersion = 2`
/// as of the pre-1.0 clean break (stable mode wire values + the full
/// option round-trip landed together as the one deliberate schema
/// change). Persisted as a protected Application Support file via
/// `FileJSONBlob`.
// nonisolated: persisted via `FileJSONBlob<T: Codable & Sendable>` and
// read off-MainActor; keep its Codable conformance nonisolated under
// the s04 SE-0466 MainActor-default flip (mirrors UserTermsBlob).
nonisolated struct SavedSearchEnvelope: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let savedSearches: [SavedSearch]

    init(schemaVersion: Int, savedSearches: [SavedSearch]) {
        self.schemaVersion = schemaVersion
        self.savedSearches = savedSearches
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, savedSearches
    }

    /// Lenient per-element decode: an element that fails to decode is
    /// DROPPED and the rest survive, so one bad row can never zero the
    /// whole list. The per-row posture is unchanged — each element still
    /// fails closed on unknown keys via the `SavedSearch` whitelist
    /// decoder; what this bounds is the blast radius of a row-level
    /// failure. Logs the dropped COUNT only (never content, never names),
    /// DEBUG builds only.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let wrapped = try container.decode([FailableSavedSearch].self, forKey: .savedSearches)
        let survivors = wrapped.compactMap(\.value)
        #if DEBUG
        let dropped = wrapped.count - survivors.count
        if dropped > 0 {
            envelopeLogger.debug("SavedSearchEnvelope: dropped \(dropped) undecodable row(s)")
        }
        #endif
        self.savedSearches = survivors
    }
}

/// Never-throwing element wrapper for the lenient envelope decode. The
/// wrapper's `init` always succeeds, so the unkeyed container advances
/// past a failing element instead of aborting the whole array.
nonisolated private struct FailableSavedSearch: Decodable {
    let value: SavedSearch?
    init(from decoder: Decoder) {
        self.value = try? SavedSearch(from: decoder)
    }
}

// nonisolated: a Sendable Logger referenced from the nonisolated envelope
// decoder. Globals default to MainActor under the s04 flip.
nonisolated private let envelopeLogger = Logger(subsystem: "app.resecta", category: "SavedSearchStore")

// MARK: - SavedSearchStore

/// `@Observable` store backed by `FileJSONBlob<SavedSearchEnvelope>` —
/// one JSON file under Application Support, written atomically with
/// `.completeFileProtection` and excluded from backups. Hydrates from
/// the file on init.
@Observable
@MainActor
final class SavedSearchStore {

    /// Pre-v2 storage location (`UserDefaults`). Removed on init as a
    /// clean break — no data migration: schema v2 changed the mode wire
    /// values, and the store moved to a protected file at the same time.
    static let legacyDefaultsKey = "savedSearches.v1"
    /// Bumped 1 → 2 with the stable mode wire values + full option
    /// round-trip. A version mismatch reads as the empty fallback —
    /// deliberate: the pre-1.0 clean break carries nothing forward, and
    /// this stays the fail-safe posture for any future version skew.
    static let schemaVersion: UInt8 = 2

    /// Production file location: one JSON file under Application
    /// Support. File protection + backup exclusion are applied by
    /// `FileJSONBlob` on every write.
    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SavedSearches", isDirectory: true)
            .appendingPathComponent("saved-searches.v2.json")
    }

    private(set) var savedSearches: [SavedSearch]

    private let blob: FileJSONBlob<SavedSearchEnvelope>

    /// Default production init — reads the Application Support file.
    convenience init() {
        self.init(fileURL: Self.defaultFileURL, asyncHydrate: true)
    }

    // P2.1: `asyncHydrate` moves the file read off the cold-start
    // critical path. Default is false so tests calling `init(fileURL:)`
    // keep their synchronous round-trip contract.
    init(
        fileURL: URL,
        legacyDefaults: UserDefaults = .standard,
        asyncHydrate: Bool = false
    ) {
        self.blob = FileJSONBlob(
            fileURL: fileURL,
            schemaVersion: Self.schemaVersion,
            fallback: SavedSearchEnvelope(schemaVersion: Int(Self.schemaVersion), savedSearches: [])
        )
        // One-time cleanup of the pre-v2 UserDefaults blob (idempotent —
        // nothing writes that key anymore).
        legacyDefaults.removeObject(forKey: Self.legacyDefaultsKey)
        if asyncHydrate {
            self.savedSearches = []
            Task { @MainActor in
                self.savedSearches = Self.hydrate(from: self.blob)
            }
        } else {
            self.savedSearches = Self.hydrate(from: blob)
        }
    }

    /// Hydration gate for the INNER envelope version. The outer
    /// `FileJSONBlob` envelope already gates its own version; this keeps
    /// the two declared versions honest against each other — a future
    /// edit that bumps one without the other reads as the empty fallback
    /// instead of silently succeeding on stale-shaped data.
    private static func hydrate(from blob: FileJSONBlob<SavedSearchEnvelope>) -> [SavedSearch] {
        let envelope = blob.load()
        guard envelope.schemaVersion == Int(Self.schemaVersion) else { return [] }
        return envelope.savedSearches
    }

    // MARK: - Read

    func lookup(id: UUID) -> SavedSearch? {
        savedSearches.first(where: { $0.id == id })
    }

    // MARK: - Mutate

    func add(_ search: SavedSearch) {
        savedSearches.append(search)
        persist()
    }

    func remove(id: UUID) {
        savedSearches.removeAll(where: { $0.id == id })
        persist()
    }

    /// Rename only — other fields are immutable in V1.x. The UI for
    /// in-place edit lives in [WU-26](WORK_UNITS.md#wu-26).
    func rename(id: UUID, to newName: String) {
        guard let idx = savedSearches.firstIndex(where: { $0.id == id }) else { return }
        let existing = savedSearches[idx]
        savedSearches[idx] = SavedSearch(
            id: existing.id,
            name: newName,
            mode: existing.mode,
            queryText: existing.queryText,
            searchTerms: existing.searchTerms,
            enabledPIICategories: existing.enabledPIICategories,
            caseSensitive: existing.caseSensitive,
            wholeWord: existing.wholeWord,
            sourceFilter: existing.sourceFilter,
            minimumOCRConfidence: existing.minimumOCRConfidence,
            minimumPIIConfidence: existing.minimumPIIConfidence,
            stripDigitSeparators: existing.stripDigitSeparators,
            normalizeSmartPunctuation: existing.normalizeSmartPunctuation,
            foldDiacritics: existing.foldDiacritics,
            includeOCR: existing.includeOCR,
            multiTermConjunction: existing.multiTermConjunction
        )
        persist()
    }

    private func persist() {
        blob.save(SavedSearchEnvelope(schemaVersion: Int(Self.schemaVersion), savedSearches: savedSearches))
    }
}
