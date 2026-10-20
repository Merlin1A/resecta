import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Where the password may and may not go. Source pins over the sheet, the
// holder and the loader keep the sinks out (no content type on the field, no
// logging, no store, no serialization); the state checks pin the holder's
// lifetime: set by a successful unlock, wiped at Start Over, Done and Home
// (one reset) and at the workspace's teardown.

@Suite("Import password lifetime", .tags(.importFlow))
@MainActor
struct ImportPasswordLifetimeTests {

    private static let sinks = [
        "textContentType", "Logger(", "os_log", "print(", "NSLog(", "UserDefaults",
        "@AppStorage", "@SceneStorage", "Keychain", "Codable", "description", "write(to:", "FileManager",
    ]

    @Test("The sheet, the holder, the search copy and the loader name none of the password sinks",
          arguments: [
            "Sources/ResectaApp/Views/ImportPasswordSheet.swift",
            "Sources/ResectaApp/Services/Import/DocumentPasswordHolder.swift",
            "Sources/ResectaApp/Services/Import/SearchCopy.swift",
            "Sources/ResectaApp/Services/Import/PDFImportLoader.swift",
          ])
    func noPasswordSinks(path: String) throws {
        let source = try loadRepoFile(path)
        for sink in Self.sinks {
            #expect(!source.contains(sink), "\(path) names \(sink)")
        }
    }

    @Test("The holder is not serializable and does not describe itself")
    func holderIsNotCodable() {
        #expect(!(DocumentPasswordHolder.self is any Codable.Type))
        #expect(!(DocumentPasswordHolder.self is any CustomStringConvertible.Type))
        #expect(!(DocumentPasswordHolder.self is any CustomDebugStringConvertible.Type))
    }

    @Test("The holder copies the bytes, hands back a transient string and wipes to empty")
    func holderSetsAndWipes() {
        let holder = DocumentPasswordHolder()
        #expect(holder.isEmpty)
        #expect(holder.withPassword { $0 } == nil)
        holder.set("secret-7731")
        #expect(!holder.isEmpty)
        #expect(holder.withPassword { $0.count } == 11)
        holder.set("x")
        #expect(holder.withPassword { $0 } == "x")
        holder.wipe()
        #expect(holder.isEmpty)
        #expect(holder.withPassword { $0 } == nil)
    }

    @Test("Start Over wipes the password and the encryption record")
    func resetWipesThePassword() {
        let doc = DocumentState()
        let redaction = RedactionState()
        let settings = SettingsState(defaults: UserDefaults(suiteName: "ImportPasswordLifetimeTests.reset")!)
        let coordinator = PipelineCoordinator(documentState: doc, redactionState: redaction, settingsState: settings)
        // A document is open: the reset leaves the editing phase.
        #expect(doc.transition(to: .importing))
        #expect(doc.transition(to: .editing))
        doc.documentPassword.set("user")
        doc.sourceFacts = ImportFacts.Summary(origin: .pdf, wasEncrypted: true, hadRestrictions: true)
        doc.resetForStartOver(redactionState: redaction, coordinator: coordinator)
        #expect(doc.documentPassword.isEmpty)
        #expect(doc.sourceFacts == ImportFacts.Summary())
    }

    @Test("The workspace's teardown wipes the password and drops a held import")
    func tearDownWipesThePassword() {
        let defaults = UserDefaults(suiteName: "ImportPasswordLifetimeTests.teardown")!
        let settings = SettingsState(defaults: defaults)
        let termsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-password-lifetime-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: termsURL) }
        let workspace = RedactWorkspace(
            settingsState: settings,
            userTermsStore: UserTermsStore(fileURL: termsURL, legacyDefaults: defaults))
        workspace.documentState.documentPassword.set("user")
        workspace.lockedImport = LockedImportHold(bytes: Data([1, 2, 3]), declaredType: nil, door: .drop, returnPhase: .empty)
        workspace.tearDown()
        #expect(workspace.documentState.documentPassword.isEmpty)
        #expect(workspace.lockedImport == nil)
    }

    @Test("Done and Home end at the empty phase, whose return to Home tears the workspace down and wipes")
    func doneAndHomeWipeThroughTheTeardown() throws {
        // The Done/Home close path either calls the reset (which wipes) or
        // ends at `.empty`, which returns to Home through the coordinator's
        // teardown (which wipes). Either way the wipe is on its route.
        let home = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView+Home.swift")
        let doneBody = try #require(functionText(from: "func performDoneCloseSession()", upTo: "// MARK:", in: home))
        #expect(doneBody.contains("resetForStartOver(") || doneBody.contains("transition(to: .empty)"))
        let workspace = try loadRepoFile("Sources/ResectaApp/App/RedactWorkspace.swift")
        let tearDown = try #require(functionText(from: "func tearDown()", upTo: "\n    }", in: workspace))
        #expect(tearDown.contains("documentPassword.wipe()"))
    }

    @Test("The source is serialized in one place: the search copy")
    func dataRepresentationHasOneSite() throws {
        let root = repoRoot().appendingPathComponent("Sources/ResectaApp")
        var sites: [String] = []
        for file in try swiftFiles(under: root) {
            let text = try String(contentsOf: file, encoding: .utf8)
            // The write itself, or the engine's exception-guarded form of
            // it (`RSGuardedDataRepresentation`, the search copy's call).
            if text.contains("dataRepresentation(") || text.contains("RSGuardedDataRepresentation(") {
                sites.append(file.lastPathComponent)
            }
        }
        #expect(sites.sorted() == ["DocumentState.swift"], "\(sites)")
    }

    // MARK: - Helpers

    private func functionText(from start: String, upTo end: String, in text: String) -> String? {
        guard let startRange = text.range(of: start),
              let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    private func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }

    private func loadRepoFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
