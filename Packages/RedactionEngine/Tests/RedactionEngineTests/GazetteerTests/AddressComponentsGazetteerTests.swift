import Testing
import Foundation
@testable import RedactionEngine

// L6 / C12 / search-impl S5 item 2.9 -- AddressComponentsGazetteer JSON
// loader + lookup tests, including the new streetTypes surface.

@Suite("AddressComponentsGazetteer (L6 / C12 / S5)")
struct AddressComponentsGazetteerTests {

    // MARK: - Helper: build a temp bundle with injected fixture JSON

    /// Write *json* into a temp bundle under Gazetteers/address_components.json
    /// and return the bundle.  Caller is responsible for cleanup.
    private static func makeTempBundle(json: String) throws -> (Bundle, URL) {
        let tempBase = FileManager.default.temporaryDirectory
            .appending(
                path: "addr-gazetteer-test-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let gazetteersDir = tempBase.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: gazetteersDir, withIntermediateDirectories: true
        )
        let fixtureURL = gazetteersDir.appending(path: "address_components.json")
        try json.write(to: fixtureURL, atomically: true, encoding: .utf8)
        guard let bundle = Bundle(path: tempBase.path()) else {
            throw TestBundleError.cannotCreateBundle(tempBase.path())
        }
        return (bundle, tempBase)
    }

    private enum TestBundleError: Error {
        case cannotCreateBundle(String)
    }

    // MARK: - Existing corpus tests

    @Test("Loads a known city from the GNIS-seeded corpus")
    func testCityLookup() throws {
        let gazetteer = try AddressComponentsGazetteer()
        #expect(gazetteer.containsCity("Los Angeles"))
        #expect(gazetteer.containsCity("Austin"))
        #expect(!gazetteer.containsCity("Zzzfake Nonexistent City"))
    }

    @Test("Loads a known county from the Census-seeded corpus")
    func testCountyLookup() throws {
        let gazetteer = try AddressComponentsGazetteer()
        #expect(gazetteer.containsCounty("Los Angeles County"))
        #expect(gazetteer.containsCounty("Abbeville County"))
        #expect(!gazetteer.containsCounty("Zzzfake Nonexistent County"))
    }

    @Test("Lookups are case- and whitespace-insensitive")
    func testCaseInsensitive() throws {
        let gazetteer = try AddressComponentsGazetteer()
        #expect(gazetteer.containsCity("los angeles"))
        #expect(gazetteer.containsCity("LOS ANGELES"))
        #expect(gazetteer.containsCity("  Los Angeles  "))
        #expect(gazetteer.containsCounty("abbeville county"))
    }

    @Test("Empty bundle throws resourceMissing")
    func testEmptyBundleThrows() {
        #expect(throws: AddressComponentsGazetteer.LoaderError.self) {
            _ = try AddressComponentsGazetteer(bundle: Bundle())
        }
    }

    @Test("Version-fence rejects out-of-range version (W-O)")
    func versionFenceRejectsOutOfRange() throws {
        let fixtureJSON = #"""
            {"version": 99, "cities": [], "counties": [], "street_types": []}
            """#
        let (bundle, tempBase) = try Self.makeTempBundle(json: fixtureJSON)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        do {
            _ = try AddressComponentsGazetteer(bundle: bundle)
            Issue.record("Expected LoaderError.unsupportedVersion but no error was thrown")
        } catch AddressComponentsGazetteer.LoaderError.unsupportedVersion(let actual, let supported) {
            #expect(actual == 99)
            #expect(supported == 1...1)
        } catch {
            Issue.record("Expected LoaderError.unsupportedVersion but got \(error)")
        }
    }

    // MARK: - S5 street_types tests

    @Test("street_types decoded into streetTypes set (S5 item 2.9)")
    func testStreetTypesDecoded() throws {
        let fixtureJSON = #"""
            {
              "version": 1,
              "cities": ["Chicago"],
              "counties": ["Cook County"],
              "street_types": ["Avenue", "Boulevard", "Street"]
            }
            """#
        let (bundle, tempBase) = try Self.makeTempBundle(json: fixtureJSON)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let gazetteer = try AddressComponentsGazetteer(bundle: bundle)
        // The set should contain all three entries (normalised = lowercased).
        #expect(gazetteer.streetTypes.contains("avenue"))
        #expect(gazetteer.streetTypes.contains("boulevard"))
        #expect(gazetteer.streetTypes.contains("street"))
        #expect(gazetteer.streetTypes.count == 3)
    }

    @Test("containsStreetType is case-insensitive (S5 item 2.9)")
    func testContainsStreetTypeNormalization() throws {
        let fixtureJSON = #"""
            {
              "version": 1,
              "cities": [],
              "counties": [],
              "street_types": ["Avenue", "Boulevard"]
            }
            """#
        let (bundle, tempBase) = try Self.makeTempBundle(json: fixtureJSON)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let gazetteer = try AddressComponentsGazetteer(bundle: bundle)
        // containsStreetType normalizes before lookup.
        #expect(gazetteer.containsStreetType("Avenue"))
        #expect(gazetteer.containsStreetType("avenue"))
        #expect(gazetteer.containsStreetType("AVENUE"))
        #expect(gazetteer.containsStreetType("  Avenue  "))
        #expect(!gazetteer.containsStreetType("Alley"))
        #expect(!gazetteer.containsStreetType("ZZZFakeType"))
    }

    @Test("Bundled artifact contains the expected 20 street types (S5 item 2.9)")
    func testBundledStreetTypeCount() throws {
        let gazetteer = try AddressComponentsGazetteer()
        // The pipeline emits exactly 20 street types (the fixed top-20 list).
        #expect(gazetteer.streetTypes.count == 20)
        // Spot-check a few well-known entries (normalised form).
        #expect(gazetteer.containsStreetType("Street"))
        #expect(gazetteer.containsStreetType("Avenue"))
        #expect(gazetteer.containsStreetType("Boulevard"))
        #expect(gazetteer.containsStreetType("Highway"))
    }
}
