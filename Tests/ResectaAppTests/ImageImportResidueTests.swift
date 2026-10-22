import Testing
import Foundation
@testable import ResectaApp

// An image import writes nothing: the Photos transfer stays in memory (the
// system's own item provider leaves no copy in the app's container — read
// on the simulator with a census of tmp/, Library/Caches and Documents
// before and after a six-item pick), and the loader and the picker hold no
// write sink. These pins read the container around a load and the two
// sources for any sink.

@Suite("Image import: no residue", .tags(.importFlow))
struct ImageImportResidueTests {

    static let containerDirectories = ["tmp", "Library/Caches", "Documents"]

    static func census() -> [String: Set<String>] {
        let home = NSHomeDirectory()
        var result: [String: Set<String>] = [:]
        for sub in containerDirectories {
            var entries: Set<String> = []
            if let e = FileManager.default.enumerator(atPath: home + "/" + sub) {
                for case let f as String in e { entries.insert(f) }
            }
            result[sub] = entries
        }
        return result
    }

    @Test("Loading three images leaves the container's listings as they were")
    func loaderWritesNothing() async throws {
        let before = Self.census()
        _ = try await ImageImportLoaderTests.loadStream([
            ImageFixtures.jpegWithProbes(width: 1200, height: 900), ImageFixtures.png(width: 600, height: 400),
            ImageFixtures.jpeg(width: 800, height: 600)])
        let after = Self.census()
        for sub in Self.containerDirectories {
            let added = after[sub]!.subtracting(before[sub]!)
            #expect(added.isEmpty, "\(sub) gained \(added.sorted())")
            let removed = before[sub]!.subtracting(after[sub]!)
            #expect(removed.isEmpty, "\(sub) lost \(removed.sorted())")
        }
    }

    @Test("The loader and the picker hold no logging or write sink")
    func noSinkInTheLoaderOrThePicker() throws {
        for file in ["Sources/ResectaApp/Services/Import/ImageImportLoader.swift",
                     "Sources/ResectaApp/Views/PhotoImportPicker.swift"] {
            let text = try String(contentsOf: repoRoot().appendingPathComponent(file), encoding: .utf8)
            for sink in ["Logger(", "os_log", "print(", "write(to:", "FileManager", "NSLog("] {
                #expect(!text.contains(sink), "\(file) contains \(sink)")
            }
        }
    }

    private func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
