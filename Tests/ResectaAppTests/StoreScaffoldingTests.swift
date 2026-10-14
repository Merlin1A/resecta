import Testing
import Foundation
@testable import ResectaApp

// The persistence scaffolding the file-backed stores share: the lenient
// row wrapper and the one-shot legacy move, driven on scratch types with
// a scratch defaults suite and a temporary file.

@Suite("Store scaffolding")
struct StoreScaffoldingTests {

    private struct Row: Codable, Equatable, Sendable {
        let name: String
        let count: Int
    }

    @Test("A lenient decode keeps the rows that decode and parks the ones that do not")
    func lenientRows() throws {
        let json = Data(#"[{"name":"a","count":1},{"name":"b"},{"name":"c","count":3}]"#.utf8)
        let rows = try JSONDecoder().decode([FailableRow<Row>].self, from: json)

        #expect(rows.compactMap(\.value) == [Row(name: "a", count: 1), Row(name: "c", count: 3)])
        #expect(rows.compactMap(\.raw).count == 1)
        // The parked row re-encodes as the JSON it arrived as.
        let parked = try JSONEncoder().encode(rows.compactMap(\.raw)[0])
        let roundTrip = try JSONSerialization.jsonObject(with: parked) as? [String: Any]
        #expect(roundTrip?["name"] as? String == "b")
    }

    @Test("The legacy move writes the file, then removes the key; a missing key does nothing")
    func legacyMigration() throws {
        let suite = "store-scaffolding-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-scaffolding-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let empty = Row(name: "", count: 0)
        let blob = FileJSONBlob<Row>(fileURL: fileURL, schemaVersion: 1, fallback: empty)

        // No key under the legacy name: nothing is written.
        blob.migrateLegacyDefaultsIfNeeded(from: defaults, key: "legacy.v1")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        // A legacy envelope under the key: moved into the file, key removed.
        UserDefaultsJSONBlob<Row>(key: "legacy.v1", schemaVersion: 1, defaults: defaults, fallback: empty)
            .save(Row(name: "moved", count: 7))
        #expect(defaults.data(forKey: "legacy.v1") != nil)

        blob.migrateLegacyDefaultsIfNeeded(from: defaults, key: "legacy.v1")

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(blob.load() == Row(name: "moved", count: 7))
        #expect(defaults.data(forKey: "legacy.v1") == nil)
    }
}
