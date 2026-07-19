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

    // MARK: - Scratch storage helpers (schema v2 file-backed store)

    /// Unique on-disk location for a file-backed store. Caller removes
    /// the parent directory in a `defer`.
    private static func makeScratchFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedSearchStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("saved-searches.v2.json")
    }

    /// Scratch UserDefaults suite for the legacy-key cleanup seam so
    /// tests never touch `.standard`.
    private static func makeScratchDefaults() -> (UserDefaults, suiteName: String) {
        let name = UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

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

    @Test("Round-trip preserves the v2 option keys (includeOCR + conjunction)")
    func roundTripV2OptionKeys() throws {
        let original = SavedSearch(
            name: "v2 options",
            mode: .multiTerm,
            searchTerms: ["routing", "account"],
            includeOCR: false,
            multiTermConjunction: true
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedSearch.self, from: encoded)
        #expect(decoded == original)
        #expect(!decoded.includeOCR)
        #expect(decoded.multiTermConjunction)
    }

    @Test("Blob without optional option keys decodes with the engine-default values")
    func partialBlobDecodesWithDefaults() throws {
        let json = #"""
        {
            "id": "00000000-0000-0000-0000-000000000003",
            "name": "legacy",
            "mode": "text",
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
        #expect(decoded.includeOCR)
        #expect(!decoded.multiTermConjunction)
    }

    // MARK: - Stable wire values (mode is decoupled from display strings)

    @Test("Mode wire values are frozen and decoupled from display names")
    func modeWireValuesAreFrozen() {
        // The persisted rawValues are a compatibility contract; the
        // user-facing strings live in `displayName` only. A failure here
        // means a rename reached the wire layer — that is a schema
        // migration, not a copy edit.
        #expect(SearchModeType.text.rawValue == "text")
        #expect(SearchModeType.regex.rawValue == "regex")
        #expect(SearchModeType.multiTerm.rawValue == "multiTerm")
        #expect(SearchModeType.piiScan.rawValue == "scan")
        #expect(SearchModeType.text.displayName == "Text")
        #expect(SearchModeType.regex.displayName == "Regex")
        #expect(SearchModeType.multiTerm.displayName == "Multi-term")
        // Display renamed "PII Scan" → "Scan" with the two-interface
        // chassis; the wire value above is untouched — that is the
        // whole point of the decoupling.
        #expect(SearchModeType.piiScan.displayName == "Scan")
    }

    @Test("Rename preserves the normalization-extension and v2 option flags")
    func renamePreservesNormalizationFlags() {
        let fileURL = Self.makeScratchFileURL()
        let (defaults, suiteName) = Self.makeScratchDefaults()
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: defaults)
        let original = SavedSearch(
            name: "before", mode: .text, queryText: "x",
            stripDigitSeparators: true, normalizeSmartPunctuation: false, foldDiacritics: true,
            includeOCR: false, multiTermConjunction: true
        )
        store.add(original)
        store.rename(id: original.id, to: "after")

        let renamed = store.lookup(id: original.id)
        #expect(renamed?.stripDigitSeparators == true)
        #expect(renamed?.normalizeSmartPunctuation == false)
        #expect(renamed?.foldDiacritics == true)
        #expect(renamed?.includeOCR == false)
        #expect(renamed?.multiTermConjunction == true)
    }

    // MARK: - Reject unknown keys ([D-25])

    @Test("Decoder rejects unknown keys")
    func decoderRejectsUnknownKeys() {
        let json = #"""
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "rogue",
            "mode": "text",
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
            "mode": "text",
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
            foldDiacritics: true,
            includeOCR: false,
            multiTermConjunction: true
        )
        SavedSearchListSheet.apply(saved, to: searchState)

        #expect(searchState.searchModeType == .regex)
        #expect(searchState.queryText == "\\d{3}-\\d{2}-\\d{4}")
        #expect(searchState.options.caseSensitive)
        #expect(searchState.options.wholeWord)
        #expect(searchState.options.stripDigitSeparators)
        #expect(!searchState.options.normalizeSmartPunctuation)
        #expect(searchState.options.foldDiacritics)
        #expect(!searchState.options.includeOCR)
        #expect(searchState.options.multiTermConjunction)
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
        original.options.includeOCR = false
        original.options.multiTermConjunction = true
        original.sourceFilter = .ocrOnly
        original.minimumOCRConfidence = 0.6

        let captured = SavedSearchListSheet.capture(from: original, name: "round trip")
        let restored = SearchState()
        SavedSearchListSheet.apply(captured, to: restored)

        #expect(restored.searchModeType == .multiTerm)
        #expect(restored.searchTerms == ["routing", "account"])
        #expect(restored.options.caseSensitive)
        #expect(restored.options.stripDigitSeparators)
        #expect(!restored.options.includeOCR)
        #expect(restored.options.multiTermConjunction)
        #expect(restored.sourceFilter == .ocrOnly)
        #expect(restored.minimumOCRConfidence == 0.6)
    }

    /// Schema-v2 acceptance: for EVERY mode, save → encode → decode →
    /// restore reproduces each sheet-settable option field-for-field.
    /// The option surface enumerated here is the full set the live sheet
    /// can set (mode, query/terms/categories, matching + normalization
    /// options, includeOCR, conjunction, source filter, confidence
    /// floors). Session-scoped result state (applied filter, sort order,
    /// navigation scope) is excluded by design — it is not query shape.
    @Test(
        "Save → load → restore round-trips every persisted option per mode",
        arguments: [SearchModeType.text, .regex, .multiTerm, .piiScan]
    )
    func fullOptionRoundTripPerMode(mode: SearchModeType) throws {
        let original = SearchState()
        original.searchModeType = mode
        switch mode {
        case .text: original.queryText = "John Doe"
        case .regex: original.queryText = "\\d{3}-\\d{2}-\\d{4}"
        case .multiTerm: original.searchTerms = ["routing", "account"]
        case .piiScan: original.enabledPIICategories = [.ssn, .phone]
        }
        // Depart from every option default so a dropped field cannot
        // hide behind its default value.
        original.options.caseSensitive = true
        original.options.wholeWord = true
        original.options.stripDigitSeparators = true
        original.options.normalizeSmartPunctuation = false
        original.options.foldDiacritics = true
        original.options.includeOCR = false
        original.options.multiTermConjunction = true
        original.sourceFilter = .ocrOnly
        original.minimumOCRConfidence = 0.65
        original.minimumPIIConfidence = 0.85

        // Full persistence pass: capture → JSON → decode → restore.
        let captured = SavedSearchListSheet.capture(from: original, name: "per-mode")
        let data = try JSONEncoder().encode(captured)
        let decoded = try JSONDecoder().decode(SavedSearch.self, from: data)
        #expect(decoded == captured)

        let restored = SearchState()
        SavedSearchListSheet.apply(decoded, to: restored)

        #expect(restored.searchModeType == mode)
        #expect(restored.queryText == original.queryText)
        #expect(restored.searchTerms == original.searchTerms)
        if mode == .piiScan {
            #expect(restored.enabledPIICategories == [.ssn, .phone])
        }
        #expect(restored.options.caseSensitive == original.options.caseSensitive)
        #expect(restored.options.wholeWord == original.options.wholeWord)
        #expect(restored.options.stripDigitSeparators == original.options.stripDigitSeparators)
        #expect(restored.options.normalizeSmartPunctuation == original.options.normalizeSmartPunctuation)
        #expect(restored.options.foldDiacritics == original.options.foldDiacritics)
        #expect(restored.options.includeOCR == original.options.includeOCR)
        #expect(restored.options.multiTermConjunction == original.options.multiTermConjunction)
        #expect(restored.sourceFilter == original.sourceFilter)
        #expect(restored.minimumOCRConfidence == original.minimumOCRConfidence)
        #expect(restored.minimumPIIConfidence == original.minimumPIIConfidence)
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
        // Generated scan names follow the displayName ("Scan") — the
        // "PII Scan" brand retired with the two-interface chassis.
        #expect(SavedSearchListSheet.generatedName(for: piiState).hasPrefix("Scan – "))
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

    @Test("Store add/remove/rename round-trips through the storage file")
    func storeMutationRoundTrip() {
        let fileURL = Self.makeScratchFileURL()
        let (defaults, suiteName) = Self.makeScratchDefaults()
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: defaults)
        let s1 = SavedSearch(name: "A", mode: .text, queryText: "alpha")
        let s2 = SavedSearch(name: "B", mode: .text, queryText: "beta")
        store.add(s1)
        store.add(s2)

        // Re-hydrate from the same file — exercises the full
        // encode/decode round-trip through disk.
        let rehydrated = SavedSearchStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(rehydrated.savedSearches.count == 2)
        #expect(rehydrated.lookup(id: s1.id) == s1)

        rehydrated.rename(id: s1.id, to: "Renamed")
        #expect(rehydrated.lookup(id: s1.id)?.name == "Renamed")

        rehydrated.remove(id: s2.id)
        #expect(rehydrated.savedSearches.count == 1)
    }

    @Test("Empty store hydrates as empty list, not crash")
    func emptyStoreHydrate() {
        let fileURL = Self.makeScratchFileURL()
        let (defaults, suiteName) = Self.makeScratchDefaults()
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.savedSearches.isEmpty)
    }

    // MARK: - Lenient per-element decode (one bad row never zeroes the list)

    /// Minimal valid v2 row as a JSON object string.
    private static func validRowJSON(id: String, name: String) -> String {
        #"{"id": "\#(id)", "name": "\#(name)", "mode": "text", "queryText": "q", "caseSensitive": false, "wholeWord": false, "sourceFilter": "All", "minimumOCRConfidence": 0.0, "minimumPIIConfidence": 0.5}"#
    }

    @Test("Envelope decode drops an undecodable row and keeps the rest")
    func lenientDecodeOneBadRowSurvives() throws {
        let good1 = Self.validRowJSON(id: "00000000-0000-0000-0000-00000000000A", name: "keep one")
        let good2 = Self.validRowJSON(id: "00000000-0000-0000-0000-00000000000B", name: "keep two")
        // Bad row: forbidden key → the per-row fail-closed decoder throws.
        let bad = #"{"id": "00000000-0000-0000-0000-00000000000C", "name": "bad", "mode": "text", "caseSensitive": false, "wholeWord": false, "sourceFilter": "All", "minimumOCRConfidence": 0.0, "minimumPIIConfidence": 0.5, "matchedText": "leak"}"#
        let json = #"{"schemaVersion": 2, "savedSearches": [\#(good1), \#(bad), \#(good2)]}"#
            .data(using: .utf8)!

        let envelope = try JSONDecoder().decode(SavedSearchEnvelope.self, from: json)
        #expect(envelope.savedSearches.count == 2)
        #expect(envelope.savedSearches.map(\.name) == ["keep one", "keep two"])
    }

    @Test("Envelope decode with every row undecodable yields empty, not a throw")
    func lenientDecodeAllBadRowsYieldEmpty() throws {
        let bad1 = #"{"id": "not-a-uuid", "name": "x", "mode": "text", "caseSensitive": false, "wholeWord": false, "sourceFilter": "All", "minimumOCRConfidence": 0.0, "minimumPIIConfidence": 0.5}"#
        let bad2 = #"{"totally": "unrelated"}"#
        let json = #"{"schemaVersion": 2, "savedSearches": [\#(bad1), \#(bad2)]}"#
            .data(using: .utf8)!

        let envelope = try JSONDecoder().decode(SavedSearchEnvelope.self, from: json)
        #expect(envelope.savedSearches.isEmpty)
    }

    @Test("A row carrying a legacy display-string mode drops without taking the list with it")
    func legacyModeStringRowDropsAlone() throws {
        // Pre-v2 rows persisted the display strings as mode values
        // ("PII Scan"-class). Under the v2 clean break those rows fail
        // per-element decode and drop; the defect this pins is the old
        // blast radius, where one such row read the WHOLE list as empty.
        let legacy = #"{"id": "00000000-0000-0000-0000-00000000000D", "name": "old", "mode": "PII Scan", "caseSensitive": false, "wholeWord": false, "sourceFilter": "All", "minimumOCRConfidence": 0.0, "minimumPIIConfidence": 0.5}"#
        let good = Self.validRowJSON(id: "00000000-0000-0000-0000-00000000000E", name: "survivor")
        let json = #"{"schemaVersion": 2, "savedSearches": [\#(legacy), \#(good)]}"#
            .data(using: .utf8)!

        let envelope = try JSONDecoder().decode(SavedSearchEnvelope.self, from: json)
        #expect(envelope.savedSearches.map(\.name) == ["survivor"])
    }

    @Test("A parked undecodable row survives an unrelated save")
    func parkedRowSurvivesResave() throws {
        let fileURL = Self.makeScratchFileURL()
        let (defaults, suiteName) = Self.makeScratchDefaults()
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            defaults.removePersistentDomain(forName: suiteName)
        }

        // A future-version row: unknown key → the [D-25] fail-closed row
        // decoder throws, so the row parks in `unrecognized`.
        let good = Self.validRowJSON(id: "00000000-0000-0000-0000-000000000011", name: "good row")
        let future = #"{"id": "00000000-0000-0000-0000-000000000012", "name": "future", "mode": "text", "queryText": "q", "caseSensitive": false, "wholeWord": false, "sourceFilter": "All", "minimumOCRConfidence": 0.0, "minimumPIIConfidence": 0.5, "futureKey": true}"#
        let fileJSON = #"{"schemaVersion": 2, "payload": {"schemaVersion": 2, "savedSearches": [\#(good), \#(future)]}}"#
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileJSON.data(using: .utf8)!.write(to: fileURL)

        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.savedSearches.map(\.name) == ["good row"],
                "the parked row is invisible to the UI")

        // The mutation that used to make the drop permanent.
        let added = try JSONDecoder().decode(
            SavedSearch.self,
            from: Self.validRowJSON(
                id: "00000000-0000-0000-0000-000000000013", name: "added"
            ).data(using: .utf8)!)
        store.add(added)

        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(raw.contains("futureKey"),
                "the undecodable row must survive the re-save on disk")

        let reloaded = SavedSearchStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(Set(reloaded.savedSearches.map(\.name)) == ["good row", "added"],
                "survivors and the new entry reload; the parked row keeps parking")
    }

    @Test("Store hydrating a file with one bad row keeps the good rows")
    func storeHydratesPastBadRow() throws {
        let fileURL = Self.makeScratchFileURL()
        let (defaults, suiteName) = Self.makeScratchDefaults()
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Hand-craft the double envelope (outer FileJSONBlob envelope +
        // inner SavedSearchEnvelope) with one undecodable row baked in.
        let good = Self.validRowJSON(id: "00000000-0000-0000-0000-00000000000F", name: "good row")
        let bad = #"{"id": "00000000-0000-0000-0000-000000000010", "name": "bad", "mode": "Regex Legacy", "caseSensitive": false, "wholeWord": false, "sourceFilter": "All", "minimumOCRConfidence": 0.0, "minimumPIIConfidence": 0.5}"#
        let fileJSON = #"{"schemaVersion": 2, "payload": {"schemaVersion": 2, "savedSearches": [\#(good), \#(bad)]}}"#
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileJSON.data(using: .utf8)!.write(to: fileURL)

        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.savedSearches.map(\.name) == ["good row"])
    }

    // MARK: - Clean-break storage move (v1 blob + legacy key)

    @Test("A v1-versioned storage file reads as the empty fallback (deliberate clean break)")
    func v1FileFallsBackEmpty() throws {
        let fileURL = Self.makeScratchFileURL()
        let (defaults, suiteName) = Self.makeScratchDefaults()
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            defaults.removePersistentDomain(forName: suiteName)
        }

        let row = Self.validRowJSON(id: "00000000-0000-0000-0000-000000000011", name: "v1 row")
        let fileJSON = #"{"schemaVersion": 1, "payload": {"schemaVersion": 1, "savedSearches": [\#(row)]}}"#
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileJSON.data(using: .utf8)!.write(to: fileURL)

        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.savedSearches.isEmpty)
    }

    @Test("An inner-envelope version mismatch alone reads as empty (both declared versions are load-bearing)")
    func innerVersionMismatchFallsBackEmpty() throws {
        let fileURL = Self.makeScratchFileURL()
        let (defaults, suiteName) = Self.makeScratchDefaults()
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Outer envelope current, inner envelope stale — discriminates
        // the store-level gate from FileJSONBlob's outer gate.
        let row = Self.validRowJSON(id: "00000000-0000-0000-0000-000000000012", name: "skewed")
        let fileJSON = #"{"schemaVersion": 2, "payload": {"schemaVersion": 1, "savedSearches": [\#(row)]}}"#
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileJSON.data(using: .utf8)!.write(to: fileURL)

        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.savedSearches.isEmpty)
    }

    @Test("The store's storage file carries protection + backup exclusion after a write")
    func storeFileIsProtectedAndBackupExcluded() throws {
        let fileURL = Self.makeScratchFileURL()
        let (defaults, suiteName) = Self.makeScratchDefaults()
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: defaults)
        store.add(SavedSearch(name: "protected", mode: .text, queryText: "x"))

        // Simulator coalescing tolerance (see FileJSONBlobTests header);
        // strict on nil by design — this iOS-only bundle always runs on
        // an iOS destination, where nil means never-applied.
        let protection = try TempFileHardening.currentProtection(of: fileURL)
        let acceptable: Set<URLFileProtection> = [
            .complete, .completeUntilFirstUserAuthentication,
        ]
        #expect(protection.map(acceptable.contains) == true,
                "expected a complete-class protection attribute, got \(String(describing: protection))")

        let values = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("Init removes the pre-v2 UserDefaults blob (no data migration)")
    func initRemovesLegacyDefaultsKey() {
        let fileURL = Self.makeScratchFileURL()
        let (defaults, suiteName) = Self.makeScratchDefaults()
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(Data([0x7B, 0x7D]), forKey: SavedSearchStore.legacyDefaultsKey)
        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.savedSearches.isEmpty)
        #expect(defaults.object(forKey: SavedSearchStore.legacyDefaultsKey) == nil)
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
            "mode": "text",
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
        let fileURL = Self.makeScratchFileURL()
        let (defaults, suiteName) = Self.makeScratchDefaults()
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            defaults.removePersistentDomain(forName: suiteName)
        }

        let oversize = String(repeating: "r", count: 300)
        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: defaults)
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
