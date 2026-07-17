import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// Round-trip + schema-version + corrupt-payload coverage for the
// file-backed persistence helper (sibling of `UserDefaultsJSONBlobTests`),
// plus the two properties that motivated the file move: complete file
// protection and backup exclusion, asserted on the written file.
//
// Host-tolerance note (mirrors the engine's file-protection suites): on
// the iOS Simulator, protection classes are coalesced — requesting
// `.complete` reads back as `.completeUntilFirstUserAuthentication`
// because the host filesystem cannot enforce the lock-screen gate. The
// assertions accept either value; both confirm a protection class was
// applied.

@Suite("FileJSONBlob")
struct FileJSONBlobTests {

    // nonisolated: passed as the `T` of `FileJSONBlob<T: Codable & Sendable>`,
    // so its Codable conformance must be usable from a nonisolated (Sendable)
    // context under the s04 SE-0466 MainActor-default flip (mirrors the
    // UserDefaultsJSONBlobTests payload).
    nonisolated private struct Payload: Codable, Sendable, Equatable {
        var items: [String: Double]
    }

    /// Unique file URL inside a fresh scratch directory. Caller removes
    /// the directory in a `defer`.
    private func makeScratchFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FileJSONBlobTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("blob.json")
    }

    private func removeScratch(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    @Test("Absent file yields fallback value")
    func emptyLoadReturnsFallback() {
        let url = makeScratchFileURL()
        defer { removeScratch(url) }
        let blob = FileJSONBlob(
            fileURL: url, schemaVersion: 1,
            fallback: Payload(items: ["default": 1.0]))
        #expect(blob.load() == Payload(items: ["default": 1.0]))
    }

    @Test("Round-trip preserves payload at same schema version")
    func roundTripPreserves() {
        let url = makeScratchFileURL()
        defer { removeScratch(url) }
        let blob = FileJSONBlob(
            fileURL: url, schemaVersion: 1, fallback: Payload(items: [:]))
        let value = Payload(items: ["ssn": 0.92, "name": 0.55])
        blob.save(value)
        #expect(blob.load() == value)
    }

    @Test("Save creates the parent directory when missing")
    func saveCreatesParentDirectory() {
        let url = makeScratchFileURL()
        defer { removeScratch(url) }
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        let blob = FileJSONBlob(
            fileURL: url, schemaVersion: 1, fallback: Payload(items: [:]))
        blob.save(Payload(items: ["a": 1.0]))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Schema mismatch falls back")
    func schemaMismatchFallback() {
        let url = makeScratchFileURL()
        defer { removeScratch(url) }
        let writer = FileJSONBlob(
            fileURL: url, schemaVersion: 1, fallback: Payload(items: [:]))
        writer.save(Payload(items: ["ssn": 0.92]))

        // Reader requests a newer schema version → falls back.
        let reader = FileJSONBlob(
            fileURL: url, schemaVersion: 2,
            fallback: Payload(items: ["fallback": 1.0]))
        #expect(reader.load() == Payload(items: ["fallback": 1.0]))
    }

    @Test("Corrupt payload falls back")
    func corruptPayloadFallback() throws {
        let url = makeScratchFileURL()
        defer { removeScratch(url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0x01, 0x02]).write(to: url)
        let blob = FileJSONBlob(
            fileURL: url, schemaVersion: 1,
            fallback: Payload(items: ["fallback": 1.0]))
        #expect(blob.load() == Payload(items: ["fallback": 1.0]))
    }

    @Test("clear() removes the file and load returns fallback")
    func clearRestoresFallback() {
        let url = makeScratchFileURL()
        defer { removeScratch(url) }
        let blob = FileJSONBlob(
            fileURL: url, schemaVersion: 1,
            fallback: Payload(items: ["default": 0.70]))
        blob.save(Payload(items: ["ssn": 0.92]))
        #expect(blob.load() == Payload(items: ["ssn": 0.92]))
        blob.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(blob.load() == Payload(items: ["default": 0.70]))
    }

    @Test("Save output is deterministic (sortedKeys encoding)")
    func encodingIsDeterministic() throws {
        let urlA = makeScratchFileURL()
        let urlB = makeScratchFileURL()
        defer {
            removeScratch(urlA)
            removeScratch(urlB)
        }
        let blobA = FileJSONBlob(fileURL: urlA, schemaVersion: 1, fallback: Payload(items: [:]))
        let blobB = FileJSONBlob(fileURL: urlB, schemaVersion: 1, fallback: Payload(items: [:]))

        let payload = Payload(items: ["zeta": 0.9, "alpha": 0.1, "mu": 0.5])
        blobA.save(payload)
        blobB.save(payload)

        let a = try Data(contentsOf: urlA)
        let b = try Data(contentsOf: urlB)
        #expect(a == b, "sortedKeys output must be byte-identical for equal payloads")
    }

    // MARK: - Protection + backup exclusion (the point of the file move)

    @Test("Written file carries a complete-class protection attribute")
    func writtenFileHasProtectionClass() throws {
        let url = makeScratchFileURL()
        defer { removeScratch(url) }
        let blob = FileJSONBlob(
            fileURL: url, schemaVersion: 1, fallback: Payload(items: [:]))
        blob.save(Payload(items: ["ssn": 0.92]))

        // Read back through the same helper the engine's protection
        // suites use. Simulator coalescing tolerance — see the header.
        // Deliberately STRICTER than the engine suites on nil: those
        // guard-pass for bare-macOS/Linux hosts, but this iOS-only app
        // bundle always runs on an iOS destination, where a nil readback
        // means the protection attribute was never applied.
        let protection = try TempFileHardening.currentProtection(of: url)
        let acceptable: Set<URLFileProtection> = [
            .complete, .completeUntilFirstUserAuthentication,
        ]
        #expect(protection.map(acceptable.contains) == true,
                "expected a complete-class protection attribute, got \(String(describing: protection))")
    }

    @Test("Written file is excluded from backup, including after an atomic re-save")
    func writtenFileIsExcludedFromBackup() throws {
        let url = makeScratchFileURL()
        defer { removeScratch(url) }
        let blob = FileJSONBlob(
            fileURL: url, schemaVersion: 1, fallback: Payload(items: [:]))
        blob.save(Payload(items: ["a": 1.0]))

        let first = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(first.isExcludedFromBackup == true,
                "isExcludedFromBackup must be true after the first save")

        // An atomic write replaces the underlying file; the flag must be
        // re-applied on every save, not just the first.
        blob.save(Payload(items: ["a": 2.0]))
        let second = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(second.isExcludedFromBackup == true,
                "isExcludedFromBackup must survive an atomic re-save")
    }
}
