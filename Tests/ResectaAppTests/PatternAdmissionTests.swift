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

    @Test("A benign pattern passes the sentinel; the refusal copy is the catalog string")
    func benignPatternPasses() async {
        #expect(await PatternAdmission.sentinelAdmits("[0-9]{3}-[0-9]{4}"))
        #expect(PatternAdmission.sentinelRejectedMessage
                == String(localized: "profile.regex.sentinel.rejected", table: "Legal", bundle: .main))
        #expect(!PatternAdmission.sentinelRejectedMessage.isEmpty)
    }

    @Test("Admission commits a new pattern and refuses a label the store already holds")
    func admissionCommitsThenRefusesADuplicate() async throws {
        let suite = "pattern-admission-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pattern-admission-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = SavedRegexStore(fileURL: fileURL, legacyDefaults: defaults)

        let first = await PatternAdmission.admit(label: "Ticket", pattern: "[A-Z]{2}-[0-9]{4}", into: store)
        #expect(first == .added)
        #expect(store.userSavedRegexes.count == 1)

        let duplicate = await PatternAdmission.admit(label: "Ticket", pattern: "[A-Z]{3}", into: store)
        #expect(duplicate == .refused(message: PatternAdmission.storeRejectedMessage))
        #expect(store.userSavedRegexes.count == 1)
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
