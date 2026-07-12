import Testing
import Foundation
@testable import ResectaApp

// W4 — round-trip + schema-version + corrupt-payload coverage for the
// shared persistence helper. Uses a scratch UserDefaults suite per test
// so the app's real defaults are untouched.

@Suite("UserDefaultsJSONBlob")
struct UserDefaultsJSONBlobTests {

    // nonisolated: passed as the `T` of `UserDefaultsJSONBlob<T: Codable & Sendable>`,
    // so its Codable conformance must be usable from a nonisolated (Sendable) context.
    // Under the s04 SE-0466 MainActor-default flip this nested test type would default
    // to MainActor (main-actor-isolated conformance can't satisfy the Sendable bound);
    // pin it nonisolated (mirrors the production UserTermsBlob/SavedSearch fix).
    nonisolated private struct Payload: Codable, Sendable, Equatable {
        var items: [String: Double]
    }

    private func makeSuite(_ function: String = #function) -> UserDefaults {
        let name = "app.resecta.tests.UserDefaultsJSONBlob.\(function)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test("Fresh defaults yields fallback value")
    func emptyLoadReturnsFallback() {
        let suite = makeSuite()
        let blob = UserDefaultsJSONBlob(
            key: "k", schemaVersion: 1, defaults: suite,
            fallback: Payload(items: ["default": 1.0]))
        #expect(blob.load() == Payload(items: ["default": 1.0]))
    }

    @Test("Round-trip preserves payload at same schema version")
    func roundTripPreserves() {
        let suite = makeSuite()
        let blob = UserDefaultsJSONBlob(
            key: "k", schemaVersion: 1, defaults: suite,
            fallback: Payload(items: [:]))
        let value = Payload(items: ["ssn": 0.92, "name": 0.55])
        blob.save(value)
        #expect(blob.load() == value)
    }

    @Test("Schema mismatch falls back")
    func schemaMismatchFallback() {
        let suite = makeSuite()
        let writer = UserDefaultsJSONBlob(
            key: "k", schemaVersion: 1, defaults: suite,
            fallback: Payload(items: [:]))
        writer.save(Payload(items: ["ssn": 0.92]))

        // Reader requests a newer schema version → falls back.
        let reader = UserDefaultsJSONBlob(
            key: "k", schemaVersion: 2, defaults: suite,
            fallback: Payload(items: ["fallback": 1.0]))
        #expect(reader.load() == Payload(items: ["fallback": 1.0]))
    }

    @Test("Corrupt payload falls back")
    func corruptPayloadFallback() {
        let suite = makeSuite()
        suite.set(Data([0xFF, 0x01, 0x02]), forKey: "k")
        let blob = UserDefaultsJSONBlob(
            key: "k", schemaVersion: 1, defaults: suite,
            fallback: Payload(items: ["fallback": 1.0]))
        #expect(blob.load() == Payload(items: ["fallback": 1.0]))
    }

    @Test("clear() removes stored value and load returns fallback")
    func clearRestoresFallback() {
        let suite = makeSuite()
        let blob = UserDefaultsJSONBlob(
            key: "k", schemaVersion: 1, defaults: suite,
            fallback: Payload(items: ["default": 0.70]))
        blob.save(Payload(items: ["ssn": 0.92]))
        #expect(blob.load() == Payload(items: ["ssn": 0.92]))
        blob.clear()
        #expect(blob.load() == Payload(items: ["default": 0.70]))
    }

    @Test("Save output is deterministic (sortedKeys encoding)")
    func encodingIsDeterministic() {
        let suite1 = makeSuite("a")
        let suite2 = makeSuite("b")
        let blobA = UserDefaultsJSONBlob(
            key: "k", schemaVersion: 1, defaults: suite1,
            fallback: Payload(items: [:]))
        let blobB = UserDefaultsJSONBlob(
            key: "k", schemaVersion: 1, defaults: suite2,
            fallback: Payload(items: [:]))

        let payload = Payload(items: ["zeta": 0.9, "alpha": 0.1, "mu": 0.5])
        blobA.save(payload)
        blobB.save(payload)

        let a = suite1.data(forKey: "k")
        let b = suite2.data(forKey: "k")
        #expect(a == b, "sortedKeys output must be byte-identical for equal payloads")
    }
}
