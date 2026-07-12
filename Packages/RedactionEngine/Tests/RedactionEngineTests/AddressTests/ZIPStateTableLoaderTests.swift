import Testing
import Foundation
@testable import RedactionEngine

// L6 / C12 — ZIPStateTableLoader JSON loader + ZIPStateTable fallback tests.

@Suite("ZIPStateTableLoader (L6 / C12)")
struct ZIPStateTableLoaderTests {

    @Test("Loads zip_scf_states.json from the module bundle")
    func testBundleLoad() throws {
        let loader = try ZIPStateTableLoader()
        // Sanity-check a handful of canonical mappings against the JSON.
        #expect(loader.state(forZIPPrefix: "902") == "CA")
        #expect(loader.state(forZIPPrefix: "100") == "NY")
        #expect(loader.state(forZIPPrefix: "787") == "TX")
    }

    @Test("Prefix lookup returns nil for unassigned / malformed prefixes")
    func testPrefixLookup() throws {
        let loader = try ZIPStateTableLoader()
        #expect(loader.state(forZIPPrefix: "000") == nil)   // unassigned
        #expect(loader.state(forZIPPrefix: "90")  == nil)   // too short
        #expect(loader.state(forZIPPrefix: "ABC") == nil)   // non-numeric
    }

    @Test("Full-ZIP lookup applies 5-digit overrides before the SCF table")
    func testFullZIPOverride() throws {
        let loader = try ZIPStateTableLoader()
        // 82063 is in CO per the overrides map, but its 820 prefix maps to WY.
        #expect(loader.state(forZIP: "82063") == "CO")
        #expect(loader.state(forZIPPrefix: "820") == "WY")
        // Non-overridden ZIPs fall through to the prefix lookup.
        #expect(loader.state(forZIP: "90210") == "CA")
    }

    @Test("Empty bundle throws and ZIPStateTable falls back to hardcoded enum")
    func testFallbackToHardcoded() {
        // A bare Bundle() has no resources; loader init must throw.
        #expect(throws: ZIPStateTableLoader.LoaderError.self) {
            _ = try ZIPStateTableLoader(bundle: Bundle())
        }
        // ZIPStateTable must still answer from its hardcoded switch even if
        // the JSON is ever removed — verify a known prefix still resolves.
        #expect(ZIPStateTable.state(forZIPPrefix: "902") == "CA")
        #expect(ZIPStateTable.state(forZIP: "78701") == "TX")
    }

    @Test("W-Q user override beats shipped 5-digit override (audit §E.1: 82063→CO)")
    func testUserOverrideBeatsShipped() throws {
        // 82063 ships as CO in the loader's overrides map (correcting the
        // 820 SCF prefix → WY default). A user entry must override it with
        // an arbitrary value to prove user-tier wins over shipped-tier.
        let loader = try ZIPStateTableLoader(userOverrides: ["82063": "TX"])
        #expect(loader.state(forZIP: "82063") == "TX")
        // The shipped 5-digit overrides table still answers via a separate
        // loader without the user map.
        let shipped = try ZIPStateTableLoader()
        #expect(shipped.state(forZIP: "82063") == "CO")
    }

    @Test("W-Q user override on a SCF-only ZIP wins over the SCF prefix")
    func testUserOverrideBeatsSCFPrefix() throws {
        // 90210 has no shipped 5-digit override; the SCF prefix 902 → CA
        // is what the unmodified loader returns. A user entry must beat it.
        let loader = try ZIPStateTableLoader(userOverrides: ["90210": "NY"])
        #expect(loader.state(forZIP: "90210") == "NY")
        // Sanity-check the unmodified path.
        let shipped = try ZIPStateTableLoader()
        #expect(shipped.state(forZIP: "90210") == "CA")
    }

    @Test("W-Q empty user overrides leave shipped behavior unchanged")
    func testEmptyUserOverridesAreInert() throws {
        let loader = try ZIPStateTableLoader(userOverrides: [:])
        // Shipped 5-digit override still wins.
        #expect(loader.state(forZIP: "82063") == "CO")
        // SCF prefix lookup still works.
        #expect(loader.state(forZIP: "90210") == "CA")
        // Prefix-only path unaffected.
        #expect(loader.state(forZIPPrefix: "820") == "WY")
    }

    @Test("Version-fence rejects out-of-range version (W-O)")
    func versionFenceRejectsOutOfRange() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appending(path: "wo-pilot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let fixtureURL = gazetteersDir.appending(path: "zip_scf_states.json")
        let fixtureJSON = #"{"version": 99, "scf_table": {"902": "CA"}, "_test_note": "W-O fence-test fixture for zip_scf_states"}"#
        try fixtureJSON.write(to: fixtureURL, atomically: true, encoding: .utf8)

        guard let bundle = Bundle(path: tempBase.path()) else {
            Issue.record("Failed to create test bundle from \(tempBase.path())")
            return
        }

        do {
            _ = try ZIPStateTableLoader(bundle: bundle)
            Issue.record("Expected LoaderError.unsupportedVersion but no error was thrown")
        } catch ZIPStateTableLoader.LoaderError.unsupportedVersion(let actual, let supported) {
            #expect(actual == 99)
            #expect(supported == 1...1)
        } catch {
            Issue.record("Expected LoaderError.unsupportedVersion but got \(error)")
        }
    }
}
