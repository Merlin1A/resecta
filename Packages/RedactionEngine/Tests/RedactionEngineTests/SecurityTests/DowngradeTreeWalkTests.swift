import Testing
import Foundation
@testable import RedactionEngine

// The session-close walk (`TempFileHardening.downgradeTree`), proved through
// its injected applier: which files the walk hands on, not the class a file
// reads back. The simulator does not change a protection class through
// `FileManager.setAttributes`, and the Mac host does not report one, so the
// class itself is a device check (FileProtectionTests on a phone).
@Suite("The session-close walk hands on every regular file", .tags(.security))
struct DowngradeTreeWalkTests {

    /// A fresh folder under the temporary directory, removed by the caller.
    private static func makeFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downgrade-walk-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    /// The path of `url` under `root`, with folders resolved and the last
    /// component kept as handed (so a link handed on reads as the link).
    private static func relative(_ url: URL, to root: URL) -> String {
        let base = root.resolvingSymlinksInPath().path
        let path = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : "OUTSIDE:" + path
    }

    /// A session folder: three regular files at three depths, an empty
    /// folder, a link to a file and a link to a folder, both outside it.
    private static func makeTree() throws -> (root: URL, outside: URL) {
        let root = try makeFolder("root")
        let outside = try makeFolder("outside")
        try write(root.appendingPathComponent("out.pdf"))
        try write(root.appendingPathComponent("pages/page-1.bin"))
        try write(root.appendingPathComponent("pages/deeper/page-2.bin"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"),
                                                withIntermediateDirectories: true)
        try write(outside.appendingPathComponent("elsewhere.pdf"))
        try write(outside.appendingPathComponent("folder/inside-link.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-to-file.pdf"),
                                                   withDestinationURL: outside.appendingPathComponent("elsewhere.pdf"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-to-folder"),
                                                   withDestinationURL: outside.appendingPathComponent("folder"))
        return (root, outside)
    }

    static let regularFiles: Set<String> = ["out.pdf", "pages/page-1.bin", "pages/deeper/page-2.bin"]

    @Test("The walk hands on each regular file once, at every depth, at the level asked, and no folder or link",
          arguments: [TempFileProtection.completeUntilFirstUserAuthentication, .complete])
    func walkHandsOnEachRegularFileOnce(level: TempFileProtection) throws {
        let (root, outside) = try Self.makeTree()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        var handed: [(String, TempFileProtection)] = []
        TempFileHardening.downgradeTree(at: root, to: level) { url, l in
            handed.append((Self.relative(url, to: root), l))
        }
        let paths = handed.map(\.0)
        #expect(Set(paths) == Self.regularFiles, "handed on: \(paths.sorted())")
        #expect(paths.count == Self.regularFiles.count, "each file once: \(paths.sorted())")
        #expect(handed.allSatisfy { $0.1 == level }, "every file at the level asked")
    }

    @Test("A file that cannot be changed does not stop the walk: the rest are still handed on")
    func failingFileDoesNotStopTheWalk() throws {
        let (root, outside) = try Self.makeTree()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        struct Refused: Error {}
        var handed: [String] = []
        TempFileHardening.downgradeTree(at: root, to: .completeUntilFirstUserAuthentication) { url, _ in
            handed.append(Self.relative(url, to: root))
            if handed.count == 1 { throw Refused() }
        }
        #expect(Set(handed) == Self.regularFiles, "handed on: \(handed.sorted())")
    }

    @Test("A root that is a file is handed on alone; a missing root hands on nothing")
    func rootFileAndMissingRoot() throws {
        let folder = try Self.makeFolder("single")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("out.pdf")
        try Self.write(file)
        var handed: [URL] = []
        TempFileHardening.downgradeTree(at: file, to: .completeUntilFirstUserAuthentication) { url, _ in
            handed.append(url)
        }
        #expect(handed.map(\.lastPathComponent) == ["out.pdf"])

        handed = []
        TempFileHardening.downgradeTree(at: folder.appendingPathComponent("gone", isDirectory: true),
                                        to: .completeUntilFirstUserAuthentication) { url, _ in
            handed.append(url)
        }
        #expect(handed.isEmpty)
    }
}
