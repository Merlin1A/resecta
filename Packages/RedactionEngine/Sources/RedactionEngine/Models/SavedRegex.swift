import Foundation

/// Shareable saved regex pattern. `label` and `pattern` are user-supplied
/// on user-owned entries; built-ins ship with fixed UUIDs (so in-memory
/// merging is idempotent) and mechanism-description labels resolved via
/// `Legal.xcstrings` at render time. The app-wide store is
/// `SavedRegexStore` in the app target.
public struct SavedRegex: Codable, Sendable, Identifiable, Equatable, Hashable {
    public static let labelLengthCap = 80
    public static let patternLengthCap = 200

    public let id: UUID
    public var label: String
    public var pattern: String
    public var createdAt: Date
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        pattern: String,
        createdAt: Date = Date(),
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.label = String(label.prefix(Self.labelLengthCap))
        self.pattern = String(pattern.prefix(Self.patternLengthCap))
        self.createdAt = createdAt
        self.isBuiltIn = isBuiltIn
    }

    // Pkg G.2 — TRUST-savedregex-codable-decoder-bypass.
    // Explicit decoder locks the built-in invariant on the deserialization
    // boundary. Built-ins are merged in-process from `allBuiltIns` (see
    // `SavedRegexStore.regexes`), never deserialized; any incoming JSON is
    // therefore user-saved by construction, regardless of what the encoded
    // payload claims. A tampered or out-of-band-edited blob that sets
    // `"isBuiltIn": true` would otherwise bypass the built-in invariant
    // (built-ins cannot be deleted, ship with stable ids, render their
    // labels through `Legal.xcstrings`). The same length clamps applied by
    // the memberwise init are mirrored here so a persisted-then-edited
    // payload cannot smuggle oversize `label` / `pattern` strings past the
    // schema floor.
    public enum CodingKeys: String, CodingKey {
        case id, label, pattern, createdAt, isBuiltIn
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        let rawLabel = try container.decode(String.self, forKey: .label)
        self.label = String(rawLabel.prefix(Self.labelLengthCap))
        let rawPattern = try container.decode(String.self, forKey: .pattern)
        self.pattern = String(rawPattern.prefix(Self.patternLengthCap))
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        // Per Pkg G.2 / Jesse Q6 — locked, ignoring whatever the JSON
        // payload claims. Built-ins are merged from in-process state, not
        // decoded.
        self.isBuiltIn = false
    }
}

// MARK: - Built-in saved regexes
//
// Shared, mechanism-description-labeled patterns shipped so the app-wide
// saved-regex library has a useful starting set. Each pattern is validated
// in `BuiltInSavedRegexesCompileTest`.

public extension SavedRegex {
    /// UUID scheme: namespace `AAAAAAAA-BBBB-CCCC-DDDD-00000000000N`
    /// where `N` disambiguates the shared built-in patterns. Fixed
    /// values keep in-memory merging idempotent across launches and let
    /// import/export round-trip through label changes.
    static let builtInCaseNumber = SavedRegex(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000001")!,
        label: "profile.builtin.regex.caseNumber",
        pattern: #"\b\d{2,4}[-\s]?[A-Z]{1,4}[-\s]?\d{3,6}\b"#,
        createdAt: Date(timeIntervalSince1970: 0),
        isBuiltIn: true
    )

    static let builtInIBAN = SavedRegex(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000003")!,
        label: "profile.builtin.regex.iban",
        pattern: #"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#,
        createdAt: Date(timeIntervalSince1970: 0),
        isBuiltIn: true
    )

    // Pattern unrolled from `\b(?:\d{1,3}\.){3}\d{1,3}\b` to avoid the
    // group-followed-by-quantifier heuristic in
    // `DocumentSearcher.validateRegexPattern`. Match semantics unchanged.
    static let builtInIPv4 = SavedRegex(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000004")!,
        label: "profile.builtin.regex.ipv4",
        pattern: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#,
        createdAt: Date(timeIntervalSince1970: 0),
        isBuiltIn: true
    )

    static let builtInUUID = SavedRegex(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000005")!,
        label: "profile.builtin.regex.uuid",
        pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
        createdAt: Date(timeIntervalSince1970: 0),
        isBuiltIn: true
    )

    // Pattern flattened to top-level alternation (in most-specific-first
    // order). The original `\b\d{4}-\d{2}-\d{2}(?:T…(?:…)?)?\b` nested
    // quantifiers inside optional groups, which the searcher's
    // validateRegexPattern heuristic rejects; top-level alternation has no
    // groups and keeps match semantics for the date-only, Z, and numeric-
    // offset variants.
    static let builtInISO8601 = SavedRegex(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000006")!,
        label: "profile.builtin.regex.iso8601",
        pattern: #"\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\b|\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:?\d{2}\b|\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\b|\b\d{4}-\d{2}-\d{2}\b"#,
        createdAt: Date(timeIntervalSince1970: 0),
        isBuiltIn: true
    )

    // MARK: - Financial identity patterns

    // US Social Security Number.
    // `(?!000|666|9\d{2})` rejects area 000/666/900-series per SSA
    // never-issued rules; `(?!00)` rejects group 00; `(?!0000)` rejects
    // serial 0000. Separators are optional hyphens or spaces. Lookaheads
    // are non-capturing and carry no quantifiers, so the safety precheck
    // passes without adjustment.
    static let builtInSSN = SavedRegex(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000007")!,
        label: "profile.builtin.regex.ssn",
        pattern: #"\b(?!000|666|9\d{2})\d{3}[-\s]?(?!00)\d{2}[-\s]?(?!0000)\d{4}\b"#,
        createdAt: Date(timeIntervalSince1970: 0),
        isBuiltIn: true
    )

    // US Employer Identification Number.
    // `(?!00|07|08|09)` rejects never-issued EIN prefixes per IRS
    // Publication 1635. Separator is optional hyphen or space.
    static let builtInEIN = SavedRegex(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000008")!,
        label: "profile.builtin.regex.ein",
        pattern: #"\b(?!00|07|08|09)\d{2}[-\s]?\d{7}\b"#,
        createdAt: Date(timeIntervalSince1970: 0),
        isBuiltIn: true
    )

    // US Individual Taxpayer Identification Number.
    // ITIN area starts with 9; the non-capturing alternation
    // `(?:5\d|6[0-5]|7\d|8[0-8]|9[0-2]|9[4-9])` implements the IRS-
    // issued group buckets 50-65, 70-88, 90-92, 94-99 per IRS Publication
    // 1915. The `5\d|6[0-5]` arm covers groups 50-65 per PIIDetector.swift
    // §762. This pattern uses `\b` while abaRouting below uses digit
    // lookarounds — the style difference is an intentional
    // anchoring choice. The alternation group is not followed by an
    // unbounded quantifier, so the safety precheck passes.
    static let builtInITIN = SavedRegex(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000009")!,
        label: "profile.builtin.regex.itin",
        pattern: #"\b9\d{2}[-\s]?(?:5\d|6[0-5]|7\d|8[0-8]|9[0-2]|9[4-9])[-\s]?\d{4}\b"#,
        createdAt: Date(timeIntervalSince1970: 0),
        isBuiltIn: true
    )

    // ABA Routing Number.
    // Alternation `(?:0[1-9]|1[0-2]|2[1-9]|3[0-2]|6[1-9]|7[0-2]|80)`
    // guards Federal Reserve valid first-two-digit prefixes: 01-12
    // (paper), 21-32 (thrift/savings), 61-72 (electronic/ACH), 80
    // (traveler's cheques). Digit lookarounds `(?<!\d)…(?!\d)` prevent
    // matches inside longer digit runs (e.g., 10-digit runs are rejected).
    // This pattern validates the prefix only — the mod-10 checksum is a
    // runtime validator in the 1.8 detector, not a regex concern.
    static let builtInABARouting = SavedRegex(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000010")!,
        label: "profile.builtin.regex.abaRouting",
        pattern: #"(?<!\d)(?:0[1-9]|1[0-2]|2[1-9]|3[0-2]|6[1-9]|7[0-2]|80)\d{7}(?!\d)"#,
        createdAt: Date(timeIntervalSince1970: 0),
        isBuiltIn: true
    )

    // Generic financial account number.
    // Optional 0-3 letter prefix (`[A-Z]{0,3}`) followed by a 6-17 digit
    // body. The lookbehind `(?<![A-Z]{4})` rejects a 4+-letter run
    // immediately before the digits (keeping "ABCD1234567" out). The
    // pattern is intentionally broad; designed for use with context
    // filters or multi-term conjunction with an "account" keyword.
    static let builtInAccountNumber = SavedRegex(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000011")!,
        label: "profile.builtin.regex.accountNumber",
        pattern: #"\b[A-Z]{0,3}(?<![A-Z]{4})\d{6,17}\b"#,
        createdAt: Date(timeIntervalSince1970: 0),
        isBuiltIn: true
    )

    /// Built-in patterns shipped by default. Bates is intentionally
    /// omitted from this set — the legal-discovery framing it served is
    /// out of scope for the general-purpose redaction tool, and the
    /// matching detection category was removed alongside this pivot.
    static let allBuiltIns: [SavedRegex] = [
        .builtInCaseNumber,
        .builtInIBAN,
        .builtInIPv4,
        .builtInUUID,
        .builtInISO8601,
        // Financial identity additions:
        .builtInSSN,
        .builtInEIN,
        .builtInITIN,
        .builtInABARouting,
        .builtInAccountNumber,
    ]
}
