import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-03 — `SavedSearchStore` schema + reject-unknown-keys decoder
// per D-25. The decoder fails closed on any
// non-whitelisted key; this corpus pins exhaustive positive coverage
// of the V1.x forbidden-key list per RR-43.
// UI ships in [WU-26](WORK_UNITS.md#wu-26) (V1.1+ defer).

@Suite("SavedSearchStore schema + decoder (WU-03)", .tags(.search))
@MainActor
struct SavedSearchStoreTests {

    // MARK: - Round-trip

    @Test("Round-trip encode/decode preserves single-mode SavedSearch")
    func roundTripSingleMode() throws {
        let original = SavedSearch(
            id: UUID(),
            name: "SSN scan",
            mode: .piiScan,
            enabledPIICategories: [.ssn, .phone],
            caseSensitive: false,
            wholeWord: false,
            sourceFilter: .all,
            minimumOCRConfidence: 0.0,
            minimumPIIConfidence: 0.65
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedSearch.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Round-trip encode/decode preserves text-mode SavedSearch")
    func roundTripText() throws {
        let original = SavedSearch(
            name: "John Doe",
            mode: .text,
            queryText: "John Doe",
            caseSensitive: true,
            wholeWord: true,
            sourceFilter: .ocrOnly,
            minimumOCRConfidence: 0.85
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedSearch.self, from: encoded)
        #expect(decoded == original)
    }

    // MARK: - S7 / design 04 §4.4 — normalization-extension keys (11 → 14)

    @Test("Round-trip preserves the three normalization-extension flags")
    func roundTripNormalizationFlags() throws {
        let original = SavedSearch(
            name: "digit shape",
            mode: .text,
            queryText: "123456789",
            stripDigitSeparators: true,
            normalizeSmartPunctuation: false,
            foldDiacritics: true
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedSearch.self, from: encoded)
        #expect(decoded == original)
        #expect(decoded.stripDigitSeparators)
        #expect(!decoded.normalizeSmartPunctuation)
        #expect(decoded.foldDiacritics)
    }

    @Test("Pre-S7 11-key blob decodes with the engine-default flag values")
    func preS7BlobDecodesWithDefaults() throws {
        let json = #"""
        {
            "id": "00000000-0000-0000-0000-000000000003",
            "name": "legacy",
            "mode": "Text",
            "queryText": "alpha",
            "caseSensitive": false,
            "wholeWord": false,
            "sourceFilter": "All",
            "minimumOCRConfidence": 0.0,
            "minimumPIIConfidence": 0.5
        }
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SavedSearch.self, from: json)
        #expect(!decoded.stripDigitSeparators)
        #expect(decoded.normalizeSmartPunctuation)
        #expect(!decoded.foldDiacritics)
    }

    @Test("Rename preserves the normalization-extension flags")
    func renamePreservesNormalizationFlags() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SavedSearchStore(defaults: defaults)
        let original = SavedSearch(
            name: "before", mode: .text, queryText: "x",
            stripDigitSeparators: true, normalizeSmartPunctuation: false, foldDiacritics: true
        )
        store.add(original)
        store.rename(id: original.id, to: "after")

        let renamed = store.lookup(id: original.id)
        #expect(renamed?.stripDigitSeparators == true)
        #expect(renamed?.normalizeSmartPunctuation == false)
        #expect(renamed?.foldDiacritics == true)
    }

    // MARK: - Reject unknown keys ([D-25])

    @Test("Decoder rejects unknown keys")
    func decoderRejectsUnknownKeys() {
        let json = #"""
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "rogue",
            "mode": "Text",
            "caseSensitive": false,
            "wholeWord": false,
            "sourceFilter": "All",
            "minimumOCRConfidence": 0.0,
            "minimumPIIConfidence": 0.5,
            "matchedText": "leakage attempt"
        }
        """#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SavedSearch.self, from: json)
        }
    }

    @Test(
        "Decoder rejects every forbidden V1.x runtime/document-derived key",
        arguments: [
            // Original [D-25] forbidden seeds:
            "matchedText", "contextSnippet", "pageIndex", "normalizedRect",
            "appliedResultIDs", "priorScanFingerprints", "ocrConfidence",
            // Engine-derived runtime fields ([RR-43] extension):
            "regexTimeoutPages", "multiTermFilter",
            "livePreview", "livePreviewRects",
            "lastDoctypeExplanation", "lastCoverageReport",
            "pendingOverlapSuppressed", "results",
            // q13 (ST-83 / QW-12) runtime fields — document-derived:
            "ocrSkippedPages", "capUnscannedPageCount",
            // Legacy Compose-mode key — removed from the whitelist
            // when Compose mode was dropped; surviving payloads must
            // fail closed rather than silently dropping the field.
            "composedSubModes"
        ]
    )
    func decoderRejectsForbiddenKeys(forbiddenKey: String) {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000002",
            "name": "leak",
            "mode": "Text",
            "caseSensitive": false,
            "wholeWord": false,
            "sourceFilter": "All",
            "minimumOCRConfidence": 0.0,
            "minimumPIIConfidence": 0.5,
            "\(forbiddenKey)": "value"
        }
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SavedSearch.self, from: json)
        }
    }

    // MARK: - S7 / design 04 §4.1 — recall application + capture seams

    @Test("Recall applies the full saved shape to SearchState")
    func recallAppliesSavedShape() {
        let searchState = SearchState()
        searchState.searchModeType = .text
        let saved = SavedSearch(
            name: "shape",
            mode: .regex,
            queryText: "\\d{3}-\\d{2}-\\d{4}",
            caseSensitive: true,
            wholeWord: true,
            sourceFilter: .textOnly,
            minimumOCRConfidence: 0.7,
            minimumPIIConfidence: 0.8,
            stripDigitSeparators: true,
            normalizeSmartPunctuation: false,
            foldDiacritics: true
        )
        SavedSearchListSheet.apply(saved, to: searchState)

        #expect(searchState.searchModeType == .regex)
        #expect(searchState.queryText == "\\d{3}-\\d{2}-\\d{4}")
        #expect(searchState.options.caseSensitive)
        #expect(searchState.options.wholeWord)
        #expect(searchState.options.stripDigitSeparators)
        #expect(!searchState.options.normalizeSmartPunctuation)
        #expect(searchState.options.foldDiacritics)
        #expect(searchState.sourceFilter == .textOnly)
        #expect(searchState.minimumOCRConfidence == 0.7)
        #expect(searchState.minimumPIIConfidence == 0.8)
        // Mode changed → the programmatic flag is armed for the hub's
        // onChange handler ([D-10]).
        #expect(searchState.isProgrammaticModeChange)
    }

    @Test("Recall with an unchanged mode does not arm the programmatic flag")
    func recallSameModeLeavesFlagClear() {
        let searchState = SearchState()
        searchState.searchModeType = .text
        let saved = SavedSearch(name: "same mode", mode: .text, queryText: "alpha")
        SavedSearchListSheet.apply(saved, to: searchState)
        #expect(searchState.queryText == "alpha")
        // No onChange will fire to consume the flag, so arming it would
        // mis-classify the NEXT user-initiated mode switch.
        #expect(!searchState.isProgrammaticModeChange)
    }

    @Test("Capture/recall round-trip preserves the query shape")
    func captureRecallRoundTrip() {
        let original = SearchState()
        original.searchModeType = .multiTerm
        original.searchTerms = ["routing", "account"]
        original.options.caseSensitive = true
        original.options.stripDigitSeparators = true
        original.sourceFilter = .ocrOnly
        original.minimumOCRConfidence = 0.6

        let captured = SavedSearchListSheet.capture(from: original, name: "round trip")
        let restored = SearchState()
        SavedSearchListSheet.apply(captured, to: restored)

        #expect(restored.searchModeType == .multiTerm)
        #expect(restored.searchTerms == ["routing", "account"])
        #expect(restored.options.caseSensitive)
        #expect(restored.options.stripDigitSeparators)
        #expect(restored.sourceFilter == .ocrOnly)
        #expect(restored.minimumOCRConfidence == 0.6)
    }

    @Test("Capture stores shape only — never results or matched text")
    func captureContainsNoDocumentDerivedData() throws {
        let searchState = SearchState()
        searchState.searchModeType = .text
        searchState.queryText = "query"
        searchState.appendResult(SearchResult(
            pageIndex: 3,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
            matchedText: "SECRET-VALUE",
            contextSnippet: "around SECRET-VALUE here",
            source: .textLayer,
            term: "query"
        ))
        searchState.flushPendingResults()

        let captured = SavedSearchListSheet.capture(from: searchState, name: "clean")
        let encoded = try JSONEncoder().encode(captured)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("SECRET-VALUE"))
        #expect(!json.contains("pageIndex"))
        #expect(!json.contains("matchedText"))
    }

    @Test("Generated names route by mode")
    func generatedNamesByMode() {
        let textState = SearchState()
        textState.searchModeType = .text
        textState.queryText = "John Smith"
        #expect(SavedSearchListSheet.generatedName(for: textState) == "Text: John Smith")

        let multiState = SearchState()
        multiState.searchModeType = .multiTerm
        multiState.searchTerms = ["a", "b", "c", "d"]
        #expect(SavedSearchListSheet.generatedName(for: multiState) == "Terms: a, b, c")

        let piiState = SearchState()
        piiState.searchModeType = .piiScan
        #expect(SavedSearchListSheet.generatedName(for: piiState).hasPrefix("PII Scan"))
    }

    @Test("Row preview prefers query text, falls back to terms, truncates at 40")
    func queryPreviewShape() {
        let long = String(repeating: "q", count: 60)
        let textSaved = SavedSearch(name: "t", mode: .text, queryText: long)
        #expect(SavedSearchListSheet.queryPreview(for: textSaved)?.count == 40)

        let termsSaved = SavedSearch(name: "m", mode: .multiTerm, searchTerms: ["a", "b", "c", "d"])
        #expect(SavedSearchListSheet.queryPreview(for: termsSaved) == "a, b, c")

        let bare = SavedSearch(name: "p", mode: .piiScan)
        #expect(SavedSearchListSheet.queryPreview(for: bare) == nil)
    }

    @Test("Filter summary renders only non-default departures")
    func filterSummaryOnlyNonDefault() {
        let allDefault = SavedSearch(name: "d", mode: .text, queryText: "x")
        #expect(SavedSearchListSheet.filterSummary(for: allDefault) == nil)

        let departed = SavedSearch(
            name: "f", mode: .text, queryText: "x",
            sourceFilter: .ocrOnly, minimumOCRConfidence: 0.5
        )
        let summary = SavedSearchListSheet.filterSummary(for: departed)
        #expect(summary?.contains("OCR ≥50%") == true)
        #expect(summary?.contains("Source: OCR") == true)
    }

    // MARK: - Privacy floor ([D-02] / spec §S7)

    @Test("Persisted shape contains no document-derived fields")
    func privacyFloor() throws {
        let saved = SavedSearch(
            name: "audit",
            mode: .text,
            queryText: "Smith",
            caseSensitive: false,
            wholeWord: false
        )
        let encoded = try JSONEncoder().encode(saved)
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let keys = Set(json?.keys ?? Dictionary<String, Any>().keys)
        let forbidden: Set<String> = [
            "matchedText", "contextSnippet", "pageIndex", "normalizedRect",
            "appliedResultIDs", "priorScanFingerprints", "ocrConfidence",
            "regexTimeoutPages", "multiTermFilter",
            "livePreview", "livePreviewRects",
            "lastDoctypeExplanation", "lastCoverageReport",
            "pendingOverlapSuppressed", "results",
            "ocrSkippedPages", "capUnscannedPageCount"
        ]
        #expect(keys.isDisjoint(with: forbidden))
    }

    // MARK: - Store mutation

    @Test("Store add/remove/rename round-trips through UserDefaults")
    func storeMutationRoundTrip() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SavedSearchStore(defaults: defaults)
        let s1 = SavedSearch(name: "A", mode: .text, queryText: "alpha")
        let s2 = SavedSearch(name: "B", mode: .text, queryText: "beta")
        store.add(s1)
        store.add(s2)

        // Re-hydrate from the same suite — exercises the full
        // encode/decode round-trip through UserDefaults.
        let rehydrated = SavedSearchStore(defaults: defaults)
        #expect(rehydrated.savedSearches.count == 2)
        #expect(rehydrated.lookup(id: s1.id) == s1)

        rehydrated.rename(id: s1.id, to: "Renamed")
        #expect(rehydrated.lookup(id: s1.id)?.name == "Renamed")

        rehydrated.remove(id: s2.id)
        #expect(rehydrated.savedSearches.count == 1)
    }

    @Test("Empty store hydrates as empty list, not crash")
    func emptyStoreHydrate() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SavedSearchStore(defaults: defaults)
        #expect(store.savedSearches.isEmpty)
    }

    // MARK: - Name length clamp (Pkg G.2 — TRUST-savedsearch-name-no-cap)

    /// Builds a minimal whitelisted `SavedSearch` JSON payload with a
    /// caller-supplied `name`. Used by the decoder-clamp tests to
    /// confirm the `.prefix(nameLengthCap)` floor holds against
    /// tampered persisted blobs.
    private static func makeSavedSearchJSON(name: String) -> Data {
        let blob: [String: Any] = [
            "id": "00000000-0000-0000-0000-000000000099",
            "name": name,
            "mode": "Text",
            "caseSensitive": false,
            "wholeWord": false,
            "sourceFilter": "All",
            "minimumOCRConfidence": 0.0,
            "minimumPIIConfidence": 0.5
        ]
        // Force-try is fine in a test fixture helper.
        return try! JSONSerialization.data(withJSONObject: blob, options: [])
    }

    @Test("Decoder clamps a 300-char name to nameLengthCap")
    func testNameDecodedAtOrUnderCap() throws {
        let oversize = String(repeating: "n", count: 300)
        let data = Self.makeSavedSearchJSON(name: oversize)
        let decoded = try JSONDecoder().decode(SavedSearch.self, from: data)
        #expect(decoded.name.count == SavedSearch.nameLengthCap,
                "Decoder must clamp name to nameLengthCap (200) per Pkg G.2")
        #expect(SavedSearch.nameLengthCap == 200,
                "Cap is locked at 200 per Jesse Q6")
    }

    @Test("Rename clamps a 300-char name to nameLengthCap, matching decoder")
    func testRenameAndDecoderClampMatch() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let oversize = String(repeating: "r", count: 300)
        let store = SavedSearchStore(defaults: defaults)
        let original = SavedSearch(name: "before", mode: .text, queryText: "x")
        store.add(original)
        store.rename(id: original.id, to: oversize)

        let renamed = store.lookup(id: original.id)
        #expect(renamed?.name.count == SavedSearch.nameLengthCap,
                "rename(id:to:) must produce the same clamp as the decoder")
    }

    @Test("Memberwise init clamps a 300-char name to nameLengthCap")
    func testMemberwiseInitClampsName() {
        let oversize = String(repeating: "m", count: 300)
        let saved = SavedSearch(name: oversize, mode: .text)
        #expect(saved.name.count == SavedSearch.nameLengthCap)
    }

    @Test("A name at exactly nameLengthCap survives the decoder unmodified")
    func testNameAtCapIsUnchanged() throws {
        let atCap = String(repeating: "a", count: SavedSearch.nameLengthCap)
        let data = Self.makeSavedSearchJSON(name: atCap)
        let decoded = try JSONDecoder().decode(SavedSearch.self, from: data)
        #expect(decoded.name == atCap)
    }

    @Test("A short name survives the decoder unmodified")
    func testShortNameUnchanged() throws {
        let data = Self.makeSavedSearchJSON(name: "Tiny")
        let decoded = try JSONDecoder().decode(SavedSearch.self, from: data)
        #expect(decoded.name == "Tiny")
    }
}
