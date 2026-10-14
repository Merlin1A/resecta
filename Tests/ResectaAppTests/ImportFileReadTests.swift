import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The Files door's read, driven through the loader's URL entry rather than
// the security-scoped picker (whose access guard a test cannot satisfy).
// A file over the cap is refused from its size on disk before any byte is
// read: the fixture is a sparse 60 MB file with its read permission
// removed, so a read-first implementation fails on the read instead.

@Suite("Import file read", .tags(.importFlow))
struct ImportFileReadTests {

    /// The import failure a read threw, spelled the way the cases are, or
    /// "none" / "other".
    private func refusalName(_ body: () throws -> Data) -> String {
        do {
            _ = try body()
            return "none"
        } catch let error as PipelineError {
            if case .importError(let failure) = error {
                return String(describing: failure)
            }
            return "other"
        } catch {
            return "other"
        }
    }

    /// A scratch file of `bytes` bytes, sparse, with the given permissions.
    private func makeScratchFile(bytes: UInt64, permissions: Int, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-file-read-\(name)-\(UUID().uuidString).pdf")
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data("%PDF-1.4\n".utf8)))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes)
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    @Test("A file over the cap is refused by its size on disk before any byte is read")
    func oversizedFileRefusedBeforeAnyRead() throws {
        let sixtyMB: UInt64 = 60 * 1024 * 1024
        let url = try makeScratchFile(bytes: sixtyMB, permissions: 0o000, name: "unreadable")
        defer { remove(url) }

        #expect(refusalName { try ImportService.readPayload(from: url) }
                == "tooLarge(bytesRead: \(sixtyMB))")
    }

    @Test("A readable file under the cap reads back its bytes")
    func readableFileReadsBack() throws {
        let url = try makeScratchFile(bytes: 4_096, permissions: 0o600, name: "readable")
        defer { remove(url) }

        let data = try ImportService.readPayload(from: url)
        #expect(data.count == 4_096)
        #expect(data.starts(with: Array("%PDF".utf8)))
    }

    @Test("A smaller cap refuses a small file by its size, naming the size")
    func smallerCapNamesTheSize() throws {
        let url = try makeScratchFile(bytes: 4_096, permissions: 0o600, name: "capped")
        defer { remove(url) }

        #expect(refusalName { try ImportService.readPayload(from: url, limits: ImportLimits(maxBytes: 1_024)) }
                == "tooLarge(bytesRead: 4096)")
        #expect(refusalName { try ImportService.readPayload(from: url, limits: ImportLimits(maxBytes: 4_096)) }
                == "none")
    }
}
