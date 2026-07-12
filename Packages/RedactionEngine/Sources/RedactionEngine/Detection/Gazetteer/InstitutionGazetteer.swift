import Foundation
import OSLog

// L4 / C10 — government-institution gazetteer. Loads `institutions.json`
// produced by DataPipeline's src/resecta_data/gazetteers/institutions/ (C9).
// Schema at DataPipeline/schemas/institutions.schema.json. Each entry:
// name, aliases, category (e.g., "federal_agency"), jurisdictions.
//
// Two uses per findings L4 §"Swift-side integration":
//   1. A5 coreference anchor — if a known institution appears in the
//      document header, bias doctype classification (federal_agency → .foia).
//   2. A6 negative-context expansion — header-anchored category suppression
//      (e.g., dampen SSN/NPI in the body of SSA correspondence).

public struct InstitutionGazetteer: Sendable {

    public struct Entry: Sendable, Equatable, Codable {
        public let name: String
        public let aliases: [String]
        public let category: String
        public let jurisdictions: [String]
    }

    public enum LoaderError: Error {
        case resourceMissing
        case decodingFailed(underlying: Error)
        case unsupportedVersion(actual: Int, supported: ClosedRange<Int>)
    }

    private static let supportedVersions: ClosedRange<Int> = 1...1

    public let entries: [Entry]

    /// Lowercased name / alias → Entry. All keys normalized via
    /// `TextNormalizer.normalize(_:)` to match the scanning path.
    private let byLoweredKey: [String: Entry]

    /// Keys sorted longest-first so `findInstitution(in:)` prefers the most
    /// specific match (e.g., "Social Security Administration" over "SSA").
    private let scanKeys: [String]

    // MARK: - Init

    /// Load the gazetteer from the module bundle.
    public init() throws {
        try self.init(bundle: .module)
    }

    /// Testing / composition init — inject a custom bundle.
    init(bundle: Bundle) throws {
        guard let url = bundle.url(
            forResource: "institutions",
            withExtension: "json",
            subdirectory: "Gazetteers"
        ) else {
            logger.info("institutions.json not bundled; institution gazetteer inert")
            throw LoaderError.resourceMissing
        }

        do {
            let bytes = try Data(contentsOf: url)
            let wire = try JSONDecoder().decode(WireFormat.self, from: bytes)
            try LoaderVersionFence.assert(
                actual: wire.version,
                supported: Self.supportedVersions,
                assetName: "institutions",
                logger: logger,
                throwing: { LoaderError.unsupportedVersion(actual: $0, supported: $1) }
            )
            self.init(entries: wire.entries)
        } catch let error as LoaderError {
            throw error
        } catch {
            logger.warning("institutions.json decode failed: \(String(describing: error), privacy: .public)")
            throw LoaderError.decodingFailed(underlying: error)
        }
    }

    /// Minimum alias length considered for the header-scan path. The GSA
    /// source corpus contains a long tail of 1–2 char alias fragments (e.g.,
    /// "i", "em", "or") that are data-quality artifacts. Keeping them in the
    /// exact-match index is fine — nobody looks up by "i" — but letting them
    /// into the substring scanner produces spurious hits inside ordinary
    /// English words ("internal", "corp", "memo"). 3 chars keeps legitimate
    /// short acronyms like "SSA", "IRS", "FBI", "CIA", "NPS".
    private static let minScanKeyLength = 3

    /// Direct-init path for tests and composition.
    public init(entries: [Entry]) {
        self.entries = entries

        var byKey: [String: Entry] = [:]
        for entry in entries {
            let nameKey = Self.normalize(entry.name)
            if !nameKey.isEmpty { byKey[nameKey] = entry }
            for alias in entry.aliases {
                let aliasKey = Self.normalize(alias)
                guard !aliasKey.isEmpty, byKey[aliasKey] == nil else { continue }
                byKey[aliasKey] = entry
            }
        }
        self.byLoweredKey = byKey
        self.scanKeys = byKey.keys
            .filter { $0.count >= Self.minScanKeyLength }
            .sorted { $0.count > $1.count }
    }

    /// Canonical lookup key: NFKC-normalized, lowercased, whitespace-trimmed.
    private static func normalize(_ s: String) -> String {
        TextNormalizer.normalize(s)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lookup

    /// Exact match on the normalized full name or any alias. Case-insensitive,
    /// NFKC-normalized, and whitespace-trimmed so "  IRS  " and "irs" both
    /// resolve to the same entry.
    public func institution(named name: String) -> Entry? {
        byLoweredKey[Self.normalize(name)]
    }

    /// Scan `text` (e.g., a document header) for any known name or alias.
    /// Returns the longest word-bounded match found; `nil` if none present.
    /// Matching requires the key to sit on a word boundary on both sides so
    /// 3-letter acronyms like "IRS" hit "IRS Form" without also hitting
    /// "prIRSnyk" or similar letter runs in ordinary English.
    public func findInstitution(in text: String) -> Entry? {
        let haystack = TextNormalizer.normalize(text).lowercased()
        guard !haystack.isEmpty else { return nil }
        for key in scanKeys where Self.wordBoundedContains(haystack, key: key) {
            return byLoweredKey[key]
        }
        return nil
    }

    /// Returns true iff `key` appears in `haystack` with a non-letter (or
    /// string boundary) on each side. Operates on Unicode scalars so CJK
    /// headers don't false-negative due to `isLetter` on the script boundary.
    private static func wordBoundedContains(_ haystack: String, key: String) -> Bool {
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: key, range: searchRange) {
            let leftOK: Bool
            if range.lowerBound == haystack.startIndex {
                leftOK = true
            } else {
                let prev = haystack[haystack.index(before: range.lowerBound)]
                leftOK = !prev.isLetter && !prev.isNumber
            }
            let rightOK: Bool
            if range.upperBound == haystack.endIndex {
                rightOK = true
            } else {
                let next = haystack[range.upperBound]
                rightOK = !next.isLetter && !next.isNumber
            }
            if leftOK && rightOK { return true }
            searchRange = range.upperBound..<haystack.endIndex
        }
        return false
    }

    // MARK: - Doctype anchoring

    /// Forward-feedback hint for `DocumentTypeClassifier`: maps an institution
    /// category to the doctype class that institution most plausibly indicates.
    /// `federal_agency` → `.foia`; `financial_institution` and `employer` both
    /// → `.financial` (employer entries are included so W-2 / pay
    /// stub issuer names suppress body-text SSN/name matches identically to bank
    /// statement headers). Other categories return `nil` until their mapping is
    /// authorized. Extend here (not at call sites) so the mapping stays auditable.
    public static func anchoredDoctype(for entry: Entry) -> DoctypeClass? {
        switch entry.category {
        case "federal_agency":
            return .foia
        case "financial_institution", "employer":
            return .financial
        default:
            return nil
        }
    }
}

// MARK: - Wire format

private struct WireFormat: Decodable {
    let version: Int
    let entries: [InstitutionGazetteer.Entry]
}

private let logger = Logger(subsystem: "app.resecta.engine", category: "InstitutionGazetteer")
