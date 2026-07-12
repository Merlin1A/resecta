import Testing
import Foundation
@testable import RedactionEngine

// D-14 — PassportPatternGazetteer JSON loader + lookup tests. Mirrors
// DLPatternGazetteerTests structure. Samples used as positive controls
// are taken verbatim from the row's `sample` field in the shipping
// artifact `passport_patterns.json` (DataPipeline commit 5b19a84,
// SHA-256 f0bc22c2…d9d8509). The CA current-arm example used in the
// recent-format-changes test is engineer-synthetic, mechanically
// derived from the row's `current_pattern` regex; no ICAO 9303 prose
// is reproduced.

@Suite("PassportPatternGazetteer (D-14)")
struct PassportPatternGazetteerTests {

    // Closed enum of the 11 V1 shipping issuer codes.
    private static let allIssuers: [String] = [
        "CA", "CN", "DO", "GB", "IN", "KR", "MX", "PH", "SV", "US", "VN",
    ]

    // MARK: - Smoke

    @Test("Loader exposes all 11 V1 issuer codes")
    func testFullCoverage() throws {
        let gazetteer = try PassportPatternGazetteer()
        #expect(gazetteer.issuerCodes == Self.allIssuers,
                "Issuer codes must be the closed V1 set in ascending order")
        // Spot-check both lexical extremes.
        #expect(gazetteer.issuerCodes.first == "CA")
        #expect(gazetteer.issuerCodes.last == "VN")
    }

    @Test("Empty bundle throws resourceMissing")
    func testEmptyBundleThrows() {
        #expect(throws: PassportPatternGazetteer.LoaderError.self) {
            _ = try PassportPatternGazetteer(bundle: Bundle())
        }
    }

    // MARK: - Per-issuer JSON-sample matches

    @Test("Each issuer accepts its own JSON sample", arguments: [
        ("CA", "AB000000"),     // legacy arm of ^[A-Z]{2}[0-9]{6}$|^[A-Z][0-9]{6}[A-Z]{2}$
        ("CN", "G12345678"),    // G arm of ^(?:G[0-9]{8}|E[0-9]{8}|E[A-HJ-NP-Z][0-9]{7})$
        ("DO", "SCB123456"),    // ^[A-Z]{3}[0-9]{6}$
        ("GB", "204567813"),    // ^[0-9]{9}$
        ("IN", "Z9999991"),     // lenient arm ^[A-Z][0-9]{7}$ (Z excluded from strict [A-PR-WY])
        ("KR", "S12345678"),    // current S arm of ^[MSROD][0-9]{8}$
        ("MX", "N12345678"),    // ^[A-Z][0-9]{8}$
        ("PH", "P1234567A"),    // current arm of ^[A-Z]{2}[0-9]{7}$|^[A-Z][0-9]{7}[A-Z]$
        ("SV", "A04728361"),    // ^[A-Z0-9]{9}$
        ("US", "X00000000"),    // current arm of ^[0-9]{9}$|^[A-Z][0-9]{8}$
        ("VN", "B99999999"),    // ^[A-Z][0-9]{8}$
    ])
    func testIssuerAcceptsOwnSample(_ pair: (String, String)) throws {
        let gazetteer = try PassportPatternGazetteer()
        #expect(gazetteer.matches(pair.1, issuedBy: pair.0),
                "Row \(pair.0) should accept its own sample \(pair.1)")
    }

    // MARK: - CA recent-format-changes (legacy + current arms)

    @Test("CA accepts legacy arm sample (^[A-Z]{2}[0-9]{6}$)")
    func testCALegacyArm() throws {
        let gazetteer = try PassportPatternGazetteer()
        // From the JSON row's `sample` field — pre-2023-06-18 format.
        #expect(gazetteer.matches("AB000000", issuedBy: "CA"))
    }

    @Test("CA accepts current arm sample (^[A-Z][0-9]{6}[A-Z]{2}$)")
    func testCACurrentArm() throws {
        let gazetteer = try PassportPatternGazetteer()
        // Engineer-synthetic, mechanically derived from current_pattern.
        // Post-2023-06-18 alpha-sandwich redesign per IRCC announcement;
        // both arms remain in active circulation under 10-year validity.
        #expect(gazetteer.matches("A123456BC", issuedBy: "CA"))
    }

    // MARK: - Bad input

    @Test("Empty / whitespace / unknown-issuer inputs reject")
    func testBadInput() throws {
        let gazetteer = try PassportPatternGazetteer()
        #expect(!gazetteer.matches("", issuedBy: "CA"))
        #expect(!gazetteer.matches("   ", issuedBy: "CA"))
        #expect(!gazetteer.matches("AB000000", issuedBy: "XX"),
                "Unknown issuer code returns false (not a crash)")
        // CU is candidates-file-only per F-37 OFAC posture; never shipped.
        #expect(!gazetteer.matches("AB000000", issuedBy: "CU"),
                "CU is excluded from V1 shipping set")
    }

    @Test("Case-sensitive matching: lowercase rejected against A-Z patterns")
    func testCaseSensitive() throws {
        let gazetteer = try PassportPatternGazetteer()
        #expect(gazetteer.matches("AB000000", issuedBy: "CA"))
        #expect(!gazetteer.matches("ab000000", issuedBy: "CA"),
                "CA pattern should reject lowercase prefix (NSRegularExpression default is case-sensitive)")
    }

    // MARK: - anyIssuer dispatch + multi-issuer surface

    @Test("anyIssuer returns sorted hit list for unambiguous candidate")
    func testAnyIssuerDispatch() throws {
        let gazetteer = try PassportPatternGazetteer()
        // AB000000 — 8-char 2L+6D, CA-legacy-only shape. SV's permissive
        // ^[A-Z0-9]{9}$ requires 9 chars (no match at length 8); IN's
        // strict ^[A-PR-WY][1-9][0-9]{5}[1-9]$ and lenient ^[A-Z][0-9]{7}$
        // both require a digit at position 1 (B is a letter — no match).
        // All other issuers expect 9 chars. Result is genuinely CA-only.
        // Note: any 9-char alphanumeric candidate hits SV by construction
        // (W-R-4.1 §II.6 medium-confidence permissive ceiling), so
        // single-hit-at-9-chars is not achievable in V1 — the audit-only
        // multi-issuer surface is the V1 contract.
        let hits = gazetteer.matches("AB000000", anyIssuer: ())
        #expect(hits == ["CA"], "AB000000 (CA legacy shape) should hit only CA; got \(hits)")
    }

    @Test("anyIssuer surfaces multi-issuer ambiguity (8-char 1L+7D)")
    func testAnyIssuerMultiIssuer() throws {
        let gazetteer = try PassportPatternGazetteer()
        // A1234567 — 8-char 1L+7D. IN strict ^[A-PR-WY][1-9][0-9]{5}[1-9]$
        // accepts (A valid prefix; 1 nonzero; 23456 5-digit body; 7 nonzero).
        // IN lenient ^[A-Z][0-9]{7}$ also accepts. No other issuer's row
        // pattern admits the 1L+7D shape (CA expects 2L+6D legacy or
        // 1L+6D+2L current; KR/MX/US/VN/CN all expect 9 chars; PH expects
        // 1L+7D+1L; SV expects 9 chars; GB expects 9 digits; DO expects 3L+6D).
        let hits = gazetteer.matches("A1234567", anyIssuer: ())
        #expect(hits.contains("IN"), "IN should accept 1L+7D shape; hits=\(hits)")
    }

    // MARK: - GB F-38 V1-MOOT framing

    @Test("GB row matches normally; F-38 metadata exposed but unconsumed")
    func testGBF38Carrier() throws {
        let gazetteer = try PassportPatternGazetteer()
        // Sample matches like any other row — F-38 OGL attribution
        // posture is V1-MOOT per Disposition §4 cite-swap; the
        // pending_decision_memo is engineer-facing audit metadata only.
        #expect(gazetteer.matches("204567813", issuedBy: "GB"))

        let meta = try #require(gazetteer.metadata(for: "GB"))
        let memo = try #require(meta.pendingDecisionMemo,
                                "GB row must carry pending_decision_memo")
        #expect(memo.fItem == "F-38")
        #expect(memo.defaultRecommendation == "B")
        #expect(meta.licensePosture == "needs-legal-review")
    }

    // MARK: - Metadata exposure scoping

    @Test("pending_decision_memo is non-nil only for GB")
    func testPendingDecisionMemoScoping() throws {
        let gazetteer = try PassportPatternGazetteer()
        for issuer in Self.allIssuers {
            let meta = try #require(gazetteer.metadata(for: issuer))
            if issuer == "GB" {
                #expect(meta.pendingDecisionMemo != nil,
                        "GB must carry pending_decision_memo")
            } else {
                #expect(meta.pendingDecisionMemo == nil,
                        "Non-GB row \(issuer) must not carry pending_decision_memo")
            }
        }
    }

    @Test("ceiling_rationale is non-nil only for SV")
    func testCeilingRationaleScoping() throws {
        let gazetteer = try PassportPatternGazetteer()
        for issuer in Self.allIssuers {
            let meta = try #require(gazetteer.metadata(for: issuer))
            if issuer == "SV" {
                #expect(meta.ceilingRationale != nil,
                        "SV must carry ceiling_rationale (medium-confidence ceiling)")
            } else {
                #expect(meta.ceilingRationale == nil,
                        "Non-SV row \(issuer) must not carry ceiling_rationale")
            }
        }
    }

    @Test("post_v1_task scoping (CN-only) and post_v1_tasks scoping (SV-only)")
    func testPostV1FieldScoping() throws {
        let gazetteer = try PassportPatternGazetteer()
        for issuer in Self.allIssuers {
            let meta = try #require(gazetteer.metadata(for: issuer))
            if issuer == "CN" {
                #expect(meta.postV1Task != nil,
                        "CN must carry post_v1_task (NIA policy-page sentinel)")
            } else {
                #expect(meta.postV1Task == nil,
                        "Non-CN row \(issuer) must not carry post_v1_task")
            }
            if issuer == "SV" {
                #expect(meta.postV1Tasks != nil,
                        "SV must carry post_v1_tasks (V-ES-1/2/3)")
            } else {
                #expect(meta.postV1Tasks == nil,
                        "Non-SV row \(issuer) must not carry post_v1_tasks")
            }
        }
    }

    // MARK: - recent_format_changes presence

    @Test("recent_format_changes is non-empty exactly for CA/CN/KR/MX/PH/US")
    func testRecentFormatChangesScoping() throws {
        let gazetteer = try PassportPatternGazetteer()
        let withRFC: Set<String> = ["CA", "CN", "KR", "MX", "PH", "US"]
        for issuer in Self.allIssuers {
            let meta = try #require(gazetteer.metadata(for: issuer))
            if withRFC.contains(issuer) {
                #expect(!meta.recentFormatChanges.isEmpty,
                        "\(issuer) must carry recent_format_changes")
            } else {
                #expect(meta.recentFormatChanges.isEmpty,
                        "\(issuer) must have empty recent_format_changes")
            }
        }
    }

    @Test("Version-fence rejects out-of-range version (W-O)")
    func versionFenceRejectsOutOfRange() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appending(path: "wo-followers-passport-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let fixtureURL = gazetteersDir.appending(path: "passport_patterns.json")
        let fixtureJSON = #"""
        {"version": 99, "generated_by": "wo-test", "generated_date": "2026-05-06", "seed": 0, "source_briefs": [], "rows": [], "_test_note": "W-O fence-test fixture for passport_patterns"}
        """#
        try fixtureJSON.write(to: fixtureURL, atomically: true, encoding: .utf8)

        guard let bundle = Bundle(path: tempBase.path()) else {
            Issue.record("Failed to create test bundle from \(tempBase.path())")
            return
        }

        do {
            _ = try PassportPatternGazetteer(bundle: bundle)
            Issue.record("Expected LoaderError.unsupportedVersion but no error was thrown")
        } catch PassportPatternGazetteer.LoaderError.unsupportedVersion(let actual, let supported) {
            #expect(actual == 99)
            #expect(supported == 1...1)
        } catch {
            Issue.record("Expected LoaderError.unsupportedVersion but got \(error)")
        }
    }
}
