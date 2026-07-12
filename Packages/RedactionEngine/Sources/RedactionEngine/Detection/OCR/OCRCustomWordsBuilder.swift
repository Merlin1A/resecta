import Foundation

// OCR quality program — customWords vocabulary.
//
// Builds the ≤150-word domain vocabulary passed to Vision on the DETECTION
// path. Derivation reads the runtime loaders (ContextKeywordsLoader,
// InstitutionGazetteer) — never raw JSON — so the list cannot drift from
// the shipped assets.
//
// Version coupling: the consumed assets
// are bundle-immutable for the life of a process — an asset change implies
// an app update implies a fresh process — so a process-lifetime cache
// (`static let`) IS the GazetteerManifestVersion-keyed cache the design
// asks for; the manifest version can only change together with the process.
// A schema change to either asset must revisit this builder.

enum OCRCustomWordsBuilder {

    /// Hard budget from the design: Apple recommends ≤ 200 words for
    /// performance; the design sets the target at ≤ 150.
    static let wordBudget = 150

    /// PII label anchors.
    static let labelAnchors: [String] = [
        "taxpayer", "recipient", "payer", "employer", "employee",
        "beneficiary", "SSN", "TIN", "EIN", "ITIN", "routing", "account",
    ]

    /// Process-lifetime cached vocabulary (thread-safe one-time init).
    static let financialCustomWords: [String] = assemble()

    private static func assemble() -> [String] {
        let contextTokens = (try? ContextKeywordsLoader())
            .map(contextKeywordTokens(from:)) ?? []
        let institutionTokens = (try? InstitutionGazetteer())
            .map(institutionNameTokens(from:)) ?? []
        return compose(
            anchors: labelAnchors,
            contextTokens: contextTokens,
            institutionTokens: institutionTokens
        )
    }

    /// Testable seam — same composition from injected loaders.
    static func build(
        contextKeywords: ContextKeywordsLoader,
        institutions: InstitutionGazetteer
    ) -> [String] {
        compose(
            anchors: labelAnchors,
            contextTokens: contextKeywordTokens(from: contextKeywords),
            institutionTokens: institutionNameTokens(from: institutions)
        )
    }

    // MARK: - Tier 1+2: context keywords (financial/tax vocabulary)

    /// All positive keywords across categories for the financial doctype
    /// (globals + financial-scoped), split into single-word tokens —
    /// Vision's customWords is a word-level vocabulary; phrases like
    /// "social security number" contribute their constituent words.
    /// Sorted for deterministic output.
    private static func contextKeywordTokens(
        from loader: ContextKeywordsLoader
    ) -> [String] {
        var tokens: Set<String> = []
        for category in PIICategory.allCases {
            guard let keywords = loader.positiveKeywords(
                for: category, doctype: .financial
            ) else { continue }
            for keyword in keywords {
                for token in keyword.split(separator: " ") {
                    let word = token.lowercased()
                    if word.count >= 3 { tokens.insert(word) }
                }
            }
        }
        return tokens.sorted()
    }

    // MARK: - Tier 3: institution name tokens

    /// Single-word tokens from entry names + aliases, ≥ 5 chars (avoids
    /// stopwords per the design), ranked by corpus frequency, top 50.
    private static func institutionNameTokens(
        from gazetteer: InstitutionGazetteer
    ) -> [String] {
        var frequency: [String: Int] = [:]
        for entry in gazetteer.entries {
            for name in [entry.name] + entry.aliases {
                for token in name.split(separator: " ") {
                    let word = token.lowercased()
                        .trimmingCharacters(in: .punctuationCharacters)
                    if word.count >= 5 {
                        frequency[word, default: 0] += 1
                    }
                }
            }
        }
        return frequency
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }  // freq desc, alpha asc
            .prefix(50)
            .map(\.key)
    }

    // MARK: - Composition (budget-capped, deduped, deterministic)

    /// Anchors first (highest value), then context tokens, then
    /// institution tokens fill the remaining budget. Dedup is
    /// case-insensitive with first occurrence winning, so the uppercase
    /// acronym anchors (SSN/EIN/…) survive over later lowercase twins.
    private static func compose(
        anchors: [String],
        contextTokens: [String],
        institutionTokens: [String]
    ) -> [String] {
        var seen: Set<String> = []
        var words: [String] = []
        for word in anchors + contextTokens + institutionTokens {
            guard words.count < wordBudget else { break }
            if seen.insert(word.lowercased()).inserted {
                words.append(word)
            }
        }
        return words
    }
}
