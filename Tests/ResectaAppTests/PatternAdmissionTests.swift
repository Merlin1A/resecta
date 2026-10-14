import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// One path admits a user-typed pattern: the sentinel runs through
// PatternAdmission, whatever surface the pattern came from. The pin reads
// the app sources so a new direct sentinel call fails here.

@Suite("Pattern admission")
@MainActor
struct PatternAdmissionTests {

    @Test("Every sentinel call in the app goes through the admission path")
    func sentinelCallsGoThroughTheAdmission() throws {
        let root = repoRoot().appendingPathComponent("Sources/ResectaApp")
        let admission = root.appendingPathComponent("State/PatternAdmission.swift").standardizedFileURL
        var offenders: [String] = []
        for file in try swiftFiles(under: root) where file.standardizedFileURL != admission {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n")
            where line.contains("RegexSentinelCheck.validate(") && !line.contains("validate(_:)") {
                offenders.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "sentinel calls outside the admission path: \(offenders)")
    }

    // MARK: - Helpers

    private func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
