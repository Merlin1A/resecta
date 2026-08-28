import Testing
import Foundation
@testable import RedactionEngine

// ZIPStateTableLoader JSON loader + ZIPStateTable fallback tests.

@Suite("ZIPStateTableLoader")
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

    @Test("Empty bundle throws and ZIPStateTable falls back to hardcoded enum")
    func testFallbackToHardcoded() {
        // A bare Bundle() has no resources; loader init must throw.
        #expect(throws: ZIPStateTableLoader.LoaderError.self) {
            _ = try ZIPStateTableLoader(bundle: Bundle())
        }
        // ZIPStateTable must still answer from its hardcoded switch even if
        // the JSON is ever removed — verify a known prefix still resolves.
        #expect(ZIPStateTable.state(forZIPPrefix: "902") == "CA")
    }

    @Test("Version-fence rejects out-of-range version")
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
