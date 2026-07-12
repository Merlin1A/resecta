import Testing
import Foundation
@testable import RedactionEngine

// D-13 — DLPatternGazetteer JSON loader + lookup tests. Mirrors
// AddressComponentsGazetteerTests structure. Samples used as positive
// controls are taken verbatim from the row's `sample` field in the
// shipping artifact `dl_patterns.json` (DataPipeline commit 9940520,
// SHA-256 b1966de…d25b5a).

@Suite("DLPatternGazetteer (D-13)")
struct DLPatternGazetteerTests {

    // MARK: - Smoke

    @Test("Loader exposes all 51 jurisdictions")
    func testFullCoverage() throws {
        let gazetteer = try DLPatternGazetteer()
        #expect(gazetteer.stateCodes.count == 51)
        // Spot-check both lexical extremes of the closed enum (AK, WY).
        #expect(gazetteer.stateCodes.first == "AK")
        #expect(gazetteer.stateCodes.last == "WY")
    }

    @Test("Advisory note carries the F-32 Tier-2 specimen-image audit")
    func testAdvisoryNote() throws {
        let gazetteer = try DLPatternGazetteer()
        let note = try #require(gazetteer.advisoryNote())
        #expect(note.contains("F-32"))
        #expect(note.contains("WA"))
    }

    @Test("Empty bundle throws resourceMissing")
    func testEmptyBundleThrows() {
        #expect(throws: DLPatternGazetteer.LoaderError.self) {
            _ = try DLPatternGazetteer(bundle: Bundle())
        }
    }

    // MARK: - Envelope rows (11 — F-25 / F-39 closure surfaces)

    @Test("AAMVA M1 envelope accepts canonical 8-13 A-Z0-9 samples", arguments: [
        ("AK", "06244114"),
        ("MT", "0312345200141"),
        ("SC", "100179226"),
        ("SD", "12345678"),
        ("WV", "03054217"),
        ("WY", "203847516"),
        ("DC", "04829105"),
        ("IL", "D40078360001"),
        ("WA", "WDL123ABC23B"),
        ("NV", "1234567890"),
        ("NJ", "S123456789012"),
    ])
    func testEnvelopeRowsAcceptCanonicalSample(_ pair: (String, String)) throws {
        let gazetteer = try DLPatternGazetteer()
        #expect(gazetteer.matches(pair.1, in: pair.0),
                "Envelope row \(pair.0) should accept its own sample \(pair.1)")
    }

    @Test("Envelope rows reject under-length input (< 8 chars)")
    func testEnvelopeRowsRejectShort() throws {
        let gazetteer = try DLPatternGazetteer()
        for state in ["AK", "MT", "SC", "SD", "WV", "WY", "DC", "IL", "WA", "NV", "NJ"] {
            #expect(!gazetteer.matches("ABC", in: state),
                    "Envelope row \(state) must reject 3-char input")
        }
    }

    @Test("Envelope row metadata reports aamva-envelope posture")
    func testEnvelopeMetadata() throws {
        let gazetteer = try DLPatternGazetteer()
        for state in ["AK", "MT", "SC", "SD", "WV", "WY", "DC", "IL", "WA", "NV", "NJ"] {
            let meta = try #require(gazetteer.metadata(for: state))
            #expect(meta.licensePosture == "aamva-envelope",
                    "\(state) license_posture should be aamva-envelope")
            #expect(meta.attestation == "aamva-envelope",
                    "\(state) attestation should be aamva-envelope")
            #expect(meta.stateFormatClaimed == false,
                    "\(state) must retract state-format claim")
        }
    }

    // MARK: - Statute-anchored rows (NC/TN/UT — F-25 closure)

    @Test("Statute-anchored rows accept their own samples", arguments: [
        ("NC", "801330315987"),
        ("TN", "101915638"),
        ("UT", "400138831"),
    ])
    func testStatuteAnchoredRowsAcceptSample(_ pair: (String, String)) throws {
        let gazetteer = try DLPatternGazetteer()
        #expect(gazetteer.matches(pair.1, in: pair.0))
    }

    @Test("Statute-anchored row metadata pins primary-published-spec")
    func testStatuteAnchoredMetadata() throws {
        let gazetteer = try DLPatternGazetteer()
        for state in ["NC", "TN", "UT"] {
            let meta = try #require(gazetteer.metadata(for: state))
            #expect(meta.licensePosture == "state-statute-anchored")
            #expect(meta.attestation == "primary-published-spec")
            #expect(meta.stateFormatClaimed == true)
        }
    }

    // MARK: - Historical variants (MA/NH/RI — dual-format rows)

    @Test("MA row accepts current sample and legacy alpha-prefix variant")
    func testMAHistoricalVariant() throws {
        let gazetteer = try DLPatternGazetteer()
        // Current pattern `^[A-Z]{2}[0-9]{7}$` (sample SA1234567) and the
        // legacy `^[A-Z][0-9]{8}$` form both still in active circulation.
        #expect(gazetteer.matches("SA1234567", in: "MA"))
        #expect(gazetteer.matches("S12345678", in: "MA"))
    }

    @Test("NH row accepts current alpha-prefix sample and legacy mixed form")
    func testNHHistoricalVariant() throws {
        let gazetteer = try DLPatternGazetteer()
        // Current `^[A-Z]{3}[0-9]{8}$` (sample ABC12345678); legacy
        // `^[0-9]{2}[A-Z]{3}[0-9]{5}$` (the prior NH format).
        #expect(gazetteer.matches("ABC12345678", in: "NH"))
        #expect(gazetteer.matches("12ABC34567", in: "NH"))
    }

    @Test("RI row accepts current 8-digit and legacy 7-digit samples")
    func testRIHistoricalVariant() throws {
        let gazetteer = try DLPatternGazetteer()
        // Current `^[0-9]{8}$` + legacy `^[0-9]{7}$`.
        #expect(gazetteer.matches("12345678", in: "RI"))
        #expect(gazetteer.matches("1234567", in: "RI"))
    }

    // MARK: - Bad input

    @Test("Empty / whitespace / unknown-state inputs reject")
    func testBadInput() throws {
        let gazetteer = try DLPatternGazetteer()
        #expect(!gazetteer.matches("", in: "AK"))
        #expect(!gazetteer.matches("   ", in: "AK"))
        #expect(!gazetteer.matches("A1234567", in: "ZZ"),
                "Unknown state code returns false (not a crash)")
    }

    @Test("Case-sensitive matching: lowercase rejected against A-Z patterns")
    func testCaseSensitive() throws {
        let gazetteer = try DLPatternGazetteer()
        // CA pattern `^[A-Z][0-9]{7}$` requires uppercase A-Z prefix.
        #expect(gazetteer.matches("A1234567", in: "CA"))
        #expect(!gazetteer.matches("a1234567", in: "CA"),
                "CA pattern should reject lowercase prefix (NSRegularExpression default is case-sensitive)")
    }

    // MARK: - F-35 SSN/DLN ambiguity surface (AR/HI/ID/LA/MS)

    @Test("F-35: each ambiguity row accepts its own 9-digit-shape sample", arguments: [
        ("AR", "123456789"),
        ("HI", "123456789"),
        ("ID", "123456789"),
        ("LA", "123456789"),
        ("MS", "123456789"),
    ])
    func testF35AmbiguityRowsAcceptShape(_ pair: (String, String)) throws {
        let gazetteer = try DLPatternGazetteer()
        #expect(gazetteer.matches(pair.1, in: pair.0))
    }

    @Test("F-35: 9-digit candidate matches multiple jurisdictions via anyState")
    func testF35AmbiguityViaAnyState() throws {
        let gazetteer = try DLPatternGazetteer()
        let hits = gazetteer.matches("123456789", anyState: ())
        // The 5 F-35 rows must all be in the hit list. Other states'
        // patterns (envelope / TN / NC / UT / MA) also accept this shape;
        // we assert superset, not equality.
        for state in ["AR", "HI", "ID", "LA", "MS"] {
            #expect(hits.contains(state),
                    "F-35 ambiguity row \(state) should match 9-digit candidate via anyState")
        }
    }

    @Test("F-35: dln_overlap_note exposed only for AR/HI/ID/LA/MS")
    func testF35MetadataScoping() throws {
        let gazetteer = try DLPatternGazetteer()
        let f35Set: Set<String> = ["AR", "HI", "ID", "LA", "MS"]
        for state in gazetteer.stateCodes {
            let meta = try #require(gazetteer.metadata(for: state))
            if f35Set.contains(state) {
                #expect(meta.dlnOverlapNote != nil,
                        "F-35 row \(state) must carry dln_overlap_note")
            } else {
                #expect(meta.dlnOverlapNote == nil,
                        "Non-F-35 row \(state) must not carry dln_overlap_note")
            }
        }
    }

    // MARK: - Metadata audit

    @Test("Posture distribution matches d13-DONE record (11/26/3/11)")
    func testPostureDistribution() throws {
        let gazetteer = try DLPatternGazetteer()
        var counts: [String: Int] = [:]
        for state in gazetteer.stateCodes {
            let meta = try #require(gazetteer.metadata(for: state))
            counts[meta.licensePosture, default: 0] += 1
        }
        #expect(counts["state-work"] == 11)
        #expect(counts["permissive-OSS-MIT"] == 26)
        #expect(counts["state-statute-anchored"] == 3)
        #expect(counts["aamva-envelope"] == 11)
    }

    @Test("Version-fence rejects out-of-range version (W-O)")
    func versionFenceRejectsOutOfRange() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appending(path: "wo-followers-dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let fixtureURL = gazetteersDir.appending(path: "dl_patterns.json")
        let fixtureJSON = #"""
        {"version": 99, "generated_by": "wo-test", "generated_date": "2026-05-06", "seed": 0, "source_briefs": [], "rows": [], "_test_note": "W-O fence-test fixture for dl_patterns"}
        """#
        try fixtureJSON.write(to: fixtureURL, atomically: true, encoding: .utf8)

        guard let bundle = Bundle(path: tempBase.path()) else {
            Issue.record("Failed to create test bundle from \(tempBase.path())")
            return
        }

        do {
            _ = try DLPatternGazetteer(bundle: bundle)
            Issue.record("Expected LoaderError.unsupportedVersion but no error was thrown")
        } catch DLPatternGazetteer.LoaderError.unsupportedVersion(let actual, let supported) {
            #expect(actual == 99)
            #expect(supported == 1...1)
        } catch {
            Issue.record("Expected LoaderError.unsupportedVersion but got \(error)")
        }
    }
}
