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
    // context under the SE-0466 MainActor-default flip (mirrors the
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
        #expect(blob.save(value))
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

    // MARK: - What a read came to

    enum ReadCase: CaseIterable, Sendable {
        case noFile, noFolder, stored, cannotBeRead, doesNotDecode, otherVersion
    }

    private enum ReadKind: Equatable {
        case absent, value, notReadable, notUnderstood
    }

    @Test("A read has six cases")
    func readCaseCount() {
        #expect(ReadCase.allCases.count == 6)
    }

    @Test("A read tells an absent file, a stored value, a file that cannot be read and a file that is not understood apart",
          arguments: ReadCase.allCases)
    @MainActor
    func readTellsTheStatesApart(_ readCase: ReadCase) throws {
        var url = makeScratchFileURL()
        defer { removeScratch(url) }
        let fallback = Payload(items: ["default": 1.0])
        let blob = FileJSONBlob<Payload>(fileURL: url, schemaVersion: 2, fallback: fallback)
        let stored = Payload(items: ["stored": 2.0])
        let expected: ReadKind
        switch readCase {
        case .noFile:
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            expected = .absent
        case .noFolder:
            url = url.deletingLastPathComponent().appendingPathComponent("missing", isDirectory: true)
                .appendingPathComponent("blob.json")
            expected = .absent
        case .stored:
            blob.save(stored)
            expected = .value
        case .cannotBeRead:
            blob.save(stored)
            try UnreadableFile.take(url)
            expected = .notReadable
        case .doesNotDecode:
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: url)
            expected = .notUnderstood
        case .otherVersion:
            FileJSONBlob<Payload>(fileURL: url, schemaVersion: 1, fallback: fallback).save(stored)
            expected = .notUnderstood
        }
        defer { UnreadableFile.restore(url) }
        let reader = FileJSONBlob<Payload>(fileURL: url, schemaVersion: 2, fallback: fallback)
        let kind: ReadKind
        switch reader.read() {
        case .absent: kind = .absent
        case .value(let value):
            kind = .value
            #expect(value == stored)
        case .notReadable: kind = .notReadable
        case .notUnderstood: kind = .notUnderstood
        }
        #expect(kind == expected)
        #expect(reader.load() == (readCase == .stored ? stored : fallback))
    }

    @Test("The read decides an absent file by its own error, with no separate question whether the file is there")
    func readAsksNoSeparateQuestion() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: "\(#filePath)")
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ResectaApp/State/FileJSONBlob.swift"),
            encoding: .utf8)
        let start = try #require(source.range(of: "func read() -> ReadOutcome {"))
        let end = try #require(source.range(of: "func storeValue(", range: start.upperBound..<source.endIndex))
        #expect(!source[start.upperBound..<end.lowerBound].contains("fileExists"))
    }

    // MARK: - The write reports

    @Test("A save into a folder that cannot be written returns false and leaves the stored file as it was")
    @MainActor
    func saveIntoLockedFolder() throws {
        let url = makeScratchFileURL()
        defer { UnreadableFile.unlockFolder(url.deletingLastPathComponent()); removeScratch(url) }
        let blob = FileJSONBlob<Payload>(fileURL: url, schemaVersion: 1, fallback: Payload(items: [:]))
        #expect(blob.save(Payload(items: ["first": 1.0])))
        let first = try Data(contentsOf: url)
        try UnreadableFile.lockFolder(url.deletingLastPathComponent())

        #expect(blob.save(Payload(items: ["second": 2.0])) == false)
        #expect(try Data(contentsOf: url) == first)
    }

    @Test("A save of a value that cannot be encoded returns false and writes nothing")
    func saveOfUnencodableValue() throws {
        let url = makeScratchFileURL()
        defer { removeScratch(url) }
        let bad = Payload(items: ["nan": .nan])
        #expect(throws: (any Error).self) { try JSONEncoder().encode(bad) }
        let blob = FileJSONBlob<Payload>(fileURL: url, schemaVersion: 1, fallback: Payload(items: [:]))

        #expect(blob.save(bad) == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A save whose replace fails returns false and leaves the stored file as it was")
    func saveWhoseReplaceFails() throws {
        let url = makeScratchFileURL()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
            removeScratch(url)
        }
        let blob = FileJSONBlob<Payload>(fileURL: url, schemaVersion: 1, fallback: Payload(items: [:]))
        #expect(blob.save(Payload(items: ["first": 1.0])))
        let first = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        let scratch = url.deletingLastPathComponent().appendingPathComponent("scratch.json")
        try Data("x".utf8).write(to: scratch)
        try #require((try? FileManager.default.replaceItemAt(url, withItemAt: scratch)) == nil,
                     "replacing the immutable file must fail on this host")
        try? FileManager.default.removeItem(at: scratch)

        #expect(blob.save(Payload(items: ["second": 2.0])) == false)
        #expect(try Data(contentsOf: url) == first)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(!siblings.contains { $0.hasPrefix(".\(url.lastPathComponent).tmp-") })
    }

    @Test("The saved answer is set after the file is placed and before its attributes are asserted again")
    func savedAnswerPlacement() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: "\(#filePath)")
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ResectaApp/State/FileJSONBlob.swift"),
            encoding: .utf8)
        let start = try #require(source.range(of: "func save(_ value: T) -> Bool {"))
        let body = source[start.upperBound...]
        let move = try #require(body.range(of: "moveItem(at: tmpURL, to: fileURL)"))
        let placed = try #require(body.range(of: "placed = true"))
        let assertAgain = try #require(body.range(of: "TempFileHardening.applyProtection(fileURL"))
        #expect(move.upperBound <= placed.lowerBound)
        #expect(placed.upperBound <= assertAgain.lowerBound)
    }
}
