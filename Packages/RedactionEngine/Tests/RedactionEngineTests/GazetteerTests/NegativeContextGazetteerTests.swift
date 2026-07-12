import Testing
import Foundation
@testable import RedactionEngine

// A6 / G4 — NegativeContextGazetteer loader tests. Existing suppression-
// behaviour coverage lives in `NegativeContextInstitutionAnchorTests`
// inside `InstitutionGazetteerTests.swift`; this file scopes the W-O
// loader-version-fence + resource-missing surfaces that the followers
// chain added when the loader gained a `LoaderError` enum + throwing init.

// MARK: - Fixture bundle helper

/// Build a temporary bundle containing a `Gazetteers/negative-context.json`
/// file with the supplied entries JSON fragment. Caller is responsible for
/// cleanup via the returned base URL.
private func makeNegCtxBundle(entriesJSON: String) throws -> (bundle: Bundle, base: URL) {
    let tempBase = FileManager.default.temporaryDirectory
        .appending(path: "negctx-semantics-\(UUID().uuidString)", directoryHint: .isDirectory)
    let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)

    let fullJSON = #"{"version": 1, "entries": "# + entriesJSON + #"}"#
    let url = gazetteersDir.appending(path: "negative-context.json")
    try fullJSON.write(to: url, atomically: true, encoding: .utf8)

    guard let bundle = Bundle(path: tempBase.path()) else {
        throw NSError(domain: "NegCtxTest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "bundle creation failed"])
    }
    return (bundle, tempBase)
}

@Suite("NegativeContextGazetteer loader (A6 / G4)")
struct NegativeContextGazetteerTests {

    @Test("Empty bundle throws resourceMissing")
    func testEmptyBundleThrows() {
        #expect(throws: NegativeContextGazetteer.LoaderError.self) {
            _ = try NegativeContextGazetteer(bundle: Bundle())
        }
    }

    // MARK: - Suppression-weight semantics (S3 fix, design §1)

    /// (a) Weak keyword match in a bucket containing a strong keyword → suppresses
    /// at the WEAK weight, not the bucket max.
    @Test("Weak keyword matched → factor uses weak weight, not bucket max")
    func testWeakKeywordUsesWeakWeight() throws {
        // Bucket has two entries: "weak term" at 0.30 and "strong term" at 0.90.
        // Context contains only "weak term". Factor should be max(0.25, 1.0 - 0.30*0.75)
        // = max(0.25, 0.775) = 0.775 — NOT max(0.25, 1.0 - 0.90*0.75) = 0.325.
        let entriesJSON = #"""
        [
          {"keyword": "weak term", "category_scope": "ssn",
           "doctype_scope": "financial", "precedence_weight": 0.30,
           "source_id": "test"},
          {"keyword": "strong term", "category_scope": "ssn",
           "doctype_scope": "financial", "precedence_weight": 0.90,
           "source_id": "test"}
        ]
        """#
        let (bundle, base) = try makeNegCtxBundle(entriesJSON: entriesJSON)
        defer { try? FileManager.default.removeItem(at: base) }

        let gazetteer = try NegativeContextGazetteer(bundle: bundle)
        let context = "The weak term appears here but not the other keyword."
        let factor = gazetteer.suppressionScore(
            category: .ssn, doctype: .financial, context: context)

        let expectedFactor = max(0.25, 1.0 - 0.30 * 0.75)  // 0.775
        #expect(abs(factor - expectedFactor) < 0.001,
                "weak keyword should suppress at weight 0.30 (factor ~0.775), got \(factor)")
        // Confirm it is NOT the bucket-max factor:
        let bucketMaxFactor = max(0.25, 1.0 - 0.90 * 0.75)  // 0.325
        #expect(factor > bucketMaxFactor,
                "factor \(factor) should exceed the bucket-max factor \(bucketMaxFactor)")
    }

    /// (b) Both weak and strong keyword matched → strong weight wins.
    @Test("Both keywords matched → strong weight wins")
    func testBothMatchedStrongWins() throws {
        let entriesJSON = #"""
        [
          {"keyword": "weak term", "category_scope": "ssn",
           "doctype_scope": "financial", "precedence_weight": 0.30,
           "source_id": "test"},
          {"keyword": "strong term", "category_scope": "ssn",
           "doctype_scope": "financial", "precedence_weight": 0.90,
           "source_id": "test"}
        ]
        """#
        let (bundle, base) = try makeNegCtxBundle(entriesJSON: entriesJSON)
        defer { try? FileManager.default.removeItem(at: base) }

        let gazetteer = try NegativeContextGazetteer(bundle: bundle)
        let context = "The weak term and strong term both appear."
        let factor = gazetteer.suppressionScore(
            category: .ssn, doctype: .financial, context: context)

        let expectedFactor = max(0.25, 1.0 - 0.90 * 0.75)  // 0.325
        #expect(abs(factor - expectedFactor) < 0.001,
                "both matched → strong weight 0.90 wins (factor ~0.325), got \(factor)")
    }

    /// (c) No keyword matched → factor exactly 1.0.
    @Test("No keyword matched → factor is exactly 1.0")
    func testNoMatchFactor1() throws {
        let entriesJSON = #"""
        [
          {"keyword": "absent keyword", "category_scope": "ssn",
           "doctype_scope": "financial", "precedence_weight": 0.70,
           "source_id": "test"}
        ]
        """#
        let (bundle, base) = try makeNegCtxBundle(entriesJSON: entriesJSON)
        defer { try? FileManager.default.removeItem(at: base) }

        let gazetteer = try NegativeContextGazetteer(bundle: bundle)
        let context = "This context has no matching terms at all."
        let factor = gazetteer.suppressionScore(
            category: .ssn, doctype: .financial, context: context)

        #expect(factor == 1.0, "no match → factor must be exactly 1.0, got \(factor)")
    }

    @Test("Version-fence rejects out-of-range version (W-O)")
    func versionFenceRejectsOutOfRange() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appending(path: "wo-followers-negctx-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let fixtureURL = gazetteersDir.appending(path: "negative-context.json")
        let fixtureJSON = #"{"version": 99, "entries": [], "_test_note": "W-O fence-test fixture for negative-context"}"#
        try fixtureJSON.write(to: fixtureURL, atomically: true, encoding: .utf8)

        guard let bundle = Bundle(path: tempBase.path()) else {
            Issue.record("Failed to create test bundle from \(tempBase.path())")
            return
        }

        do {
            _ = try NegativeContextGazetteer(bundle: bundle)
            Issue.record("Expected LoaderError.unsupportedVersion but no error was thrown")
        } catch NegativeContextGazetteer.LoaderError.unsupportedVersion(let actual, let supported) {
            #expect(actual == 99)
            #expect(supported == 1...1)
        } catch {
            Issue.record("Expected LoaderError.unsupportedVersion but got \(error)")
        }
    }
}
