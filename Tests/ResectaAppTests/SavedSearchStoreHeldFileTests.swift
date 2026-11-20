import Testing
import Foundation
import UIKit
@testable import ResectaApp

// The saved-search store while its file is there and cannot be read, and
// the list sheet's Save and Rename prompts coming back when a change was
// not stored.

@Suite("Saved searches: a file that cannot be read", .tags(.search), .serialized)
@MainActor
struct SavedSearchStoreHeldFileTests {

    private static func makeSuite(_ function: String = #function) -> UserDefaults {
        let name = "app.resecta.tests.SavedSearchHeld.\(function).\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    private static func makeScratchFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedSearchHeldTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("saved-searches.v2.json")
    }

    private static func removeScratch(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// A file holding one saved search, the search, and the file's bytes.
    private static func seed(_ fileURL: URL) throws -> (SavedSearch, Data) {
        let stored = SavedSearch(name: "Stored", mode: .text, queryText: "stored")
        let seed = SavedSearchStore(fileURL: fileURL, legacyDefaults: makeSuite())
        #expect(seed.add(stored) == .saved)
        return (stored, try Data(contentsOf: fileURL))
    }

    enum Change: CaseIterable, Sendable {
        case add, remove, clearAll, rename
    }

    private static func apply(_ change: Change, to store: SavedSearchStore, stored: SavedSearch) -> ListChange {
        switch change {
        case .add: store.add(SavedSearch(name: "New", mode: .text, queryText: "new"))
        case .remove: store.remove(id: stored.id)
        case .clearAll: store.clearAll(interface: .search)
        case .rename: store.rename(id: stored.id, to: "Renamed")
        }
    }

    @Test("Saved searches have four changes")
    func changeCount() { #expect(Change.allCases.count == 4) }

    @Test("Saved searches: while the stored file cannot be read, every change answers held and the file is left as it is",
          arguments: Change.allCases)
    func held(_ change: Change) throws {
        let fileURL = Self.makeScratchFileURL()
        defer { Self.removeScratch(fileURL) }
        let (stored, seeded) = try Self.seed(fileURL)
        try UnreadableFile.take(fileURL)
        defer { UnreadableFile.restore(fileURL) }

        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(store.savedSearches.isEmpty)
        #expect(Self.apply(change, to: store, stored: stored) == .held)
        #expect(store.savedSearches.isEmpty)

        UnreadableFile.restore(fileURL)
        #expect(try Data(contentsOf: fileURL) == seeded)
    }

    @Test("Saved searches: once the file can be read, the stored entries load before the change is applied")
    func heldThenReadable() throws {
        let fileURL = Self.makeScratchFileURL()
        defer { Self.removeScratch(fileURL) }
        _ = try Self.seed(fileURL)
        try UnreadableFile.take(fileURL)
        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        UnreadableFile.restore(fileURL)

        #expect(store.add(SavedSearch(name: "New", mode: .text, queryText: "new")) == .saved)

        #expect(store.savedSearches.map(\.name) == ["Stored", "New"])
        let again = SavedSearchStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(again.savedSearches.map(\.name) == ["Stored", "New"])
    }

    enum Notice: CaseIterable, Sendable {
        case cameToTheFront, protectedFilesAvailable
        var name: Notification.Name {
            switch self {
            case .cameToTheFront: UIApplication.didBecomeActiveNotification
            case .protectedFilesAvailable: UIApplication.protectedDataDidBecomeAvailableNotification
            }
        }
    }

    @Test("Saved searches: the stored entries load when the app comes to the front, and when protected files become available",
          arguments: Notice.allCases)
    func readsAgainOnNotice(_ notice: Notice) throws {
        #expect(Notice.allCases.count == 2)
        let fileURL = Self.makeScratchFileURL()
        defer { Self.removeScratch(fileURL) }
        _ = try Self.seed(fileURL)
        try UnreadableFile.take(fileURL)
        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        UnreadableFile.restore(fileURL)
        #expect(store.savedSearches.isEmpty)

        NotificationCenter.default.post(name: notice.name, object: nil)

        #expect(store.savedSearches.map(\.name) == ["Stored"])
    }

    enum Refusal: CaseIterable, Sendable {
        case addTakenName, renameOntoAnother, renameMissing, addOrdinary, renameOrdinary, renameToItsOwnName
    }

    @Test("Saved searches have six refusal and save cases")
    func refusalCount() { #expect(Refusal.allCases.count == 6) }

    @Test("Saved searches: each refusal names its reason, and an ordinary change is saved",
          arguments: Refusal.allCases)
    func refusals(_ row: Refusal) {
        let fileURL = Self.makeScratchFileURL()
        defer { Self.removeScratch(fileURL) }
        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        let alpha = SavedSearch(name: "Alpha", mode: .text, queryText: "a")
        let beta = SavedSearch(name: "Beta", mode: .text, queryText: "b")
        #expect(store.add(alpha) == .saved)
        #expect(store.add(beta) == .saved)
        let answer: ListChange
        let expected: ListChange
        switch row {
        case .addTakenName:
            answer = store.add(SavedSearch(name: "Alpha", mode: .text, queryText: "c"))
            expected = .refused(.duplicate)
        case .renameOntoAnother:
            answer = store.rename(id: beta.id, to: "Alpha"); expected = .refused(.duplicate)
        case .renameMissing:
            answer = store.rename(id: UUID(), to: "Gamma"); expected = .refused(.missing)
        case .addOrdinary:
            answer = store.add(SavedSearch(name: "Gamma", mode: .text, queryText: "c")); expected = .saved
        case .renameOrdinary:
            answer = store.rename(id: beta.id, to: "Gamma"); expected = .saved
        case .renameToItsOwnName:
            answer = store.rename(id: beta.id, to: "Beta"); expected = .saved
        }
        #expect(answer == expected)
    }

    // MARK: - The prompts' way back

    enum PromptInput: CaseIterable, Sendable {
        case nothing, refusalWords, notStored, both
    }

    @Test("A prompt comes back when a refusal has words or when a change was not stored",
          arguments: PromptInput.allCases)
    func promptReturn(_ input: PromptInput) {
        #expect(PromptInput.allCases.count == 4)
        let (error, notSaved, expected): (String?, Bool, Bool) = switch input {
        case .nothing: (nil, false, false)
        case .refusalWords: ("words", false, true)
        case .notStored: (nil, true, true)
        case .both: ("words", true, true)
        }
        #expect(SavedSearchListSheet.promptReturnOwed(error: error, notSaved: notSaved) == expected)
    }

    private static func sheetSource(file: StaticString = #filePath) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: "\(file)")
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ResectaApp/Views/Search/SavedSearchListSheet.swift"),
            encoding: .utf8)
    }

    /// The lines from `start` to the next `end`, inclusive of neither.
    private static func span(_ source: String, from start: String, to end: String) throws -> Substring {
        let head = try #require(source.range(of: start))
        let tail = try #require(source.range(of: end, range: head.upperBound..<source.endIndex))
        return source[head.upperBound..<tail.lowerBound]
    }

    @Test("The Save prompt's way back asks one function")
    func savePromptWayBack() throws {
        let source = try Self.sheetSource()
        let arm = try Self.span(source, from: "                    case .notSaved, .held:", to: "                    }")
        #expect(arm.contains("savePromptNotSaved = true"))
        #expect(!source.contains("savePromptError != nil"), "a guard reads the error alone")
        #expect(source.components(separatedBy: "Self.promptReturnOwed(error: savePromptError, notSaved: savePromptNotSaved)").count - 1 == 4)
    }

    @Test("The Rename prompt's way back asks one function")
    func renamePromptWayBack() throws {
        let source = try Self.sheetSource()
        let arm = try Self.span(source, from: "                    case .notSaved?, .held?:", to: "                    case .saved?, nil:")
        #expect(arm.contains("renameNotSaved = true"))
        #expect(arm.contains("renameRetryTarget = search"))
        #expect(!source.contains("renameError != nil"), "a guard reads the error alone")
        #expect(source.components(separatedBy: "Self.promptReturnOwed(error: renameError, notSaved: renameNotSaved)").count - 1 == 3)
    }
}
