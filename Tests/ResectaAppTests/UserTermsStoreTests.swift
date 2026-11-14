import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The custom-terms store and the saved-pattern store each read their file
// inside their initialiser, so from the first moment a store exists it holds
// the stored lists: a term added at once is added to them, and the duplicate
// check and the per-list cap read them, never an empty list waiting on a
// delayed read. A second store opened on the same file reads what was saved.

@Suite("Stores hold their file's lists from the first moment")
@MainActor
struct UserTermsStoreHydrationTests {

    private func makeEmptyDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Scratch Application Support stand-in — one throwaway file per
    /// test so stores never touch the production location (mirrors
    /// `SavedSearchStoreTests.makeScratchFileURL`).
    private func makeScratchFileURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("UserTermsStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    /// The store as the app opens it.
    private func openStore(_ fileURL: URL, _ defaults: UserDefaults) -> UserTermsStore {
        UserTermsStore(fileURL: fileURL, legacyDefaults: defaults)
    }

    enum TermList: String, CaseIterable, Sendable {
        case alwaysFlag, neverFlag
    }

    private func add(_ term: UserTerm, to list: TermList, in store: UserTermsStore) -> Bool {
        switch list {
        case .alwaysFlag: store.addAlwaysFlag(term)
        case .neverFlag: store.addNeverFlag(term)
        }
    }

    private func terms(_ list: TermList, in store: UserTermsStore) -> [String] {
        switch list {
        case .alwaysFlag: store.blob.alwaysFlag.map(\.pattern)
        case .neverFlag: store.blob.neverFlag.map(\.pattern)
        }
    }

    @Test("A term added the moment the store exists keeps every stored term", arguments: TermList.allCases)
    func termAddedAtOnceKeepsStoredTerms(_ list: TermList) {
        let name = "UserTermsStoreTests.atOnce.\(list.rawValue)"
        let defaults = makeEmptyDefaults(name)
        let fileURL = makeScratchFileURL("user-terms.v1.json")
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        let seed = UserTermsStore(fileURL: fileURL, legacyDefaults: defaults)
        for pattern in ["first-term", "second-term", "third-term"] {
            #expect(add(UserTerm(pattern: pattern, isRegex: false), to: list, in: seed))
        }

        let store = openStore(fileURL, defaults)
        #expect(add(UserTerm(pattern: "fourth-term", isRegex: false), to: list, in: store))
        let expected = ["first-term", "second-term", "third-term", "fourth-term"]
        #expect(terms(list, in: store) == expected)

        let reopened = UserTermsStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(terms(list, in: reopened) == expected)
    }

    @Test("The duplicate check and the cap read the stored list from the first moment")
    func duplicateAndCapReadStoredList() throws {
        let name = "UserTermsStoreTests.dupCap"
        let defaults = makeEmptyDefaults(name)
        let dupURL = makeScratchFileURL("user-terms.v1.json")
        let capURL = makeScratchFileURL("user-terms.v1.json")
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: capURL.deletingLastPathComponent())
        }
        let stored = UserTerm(pattern: "stored-term", isRegex: false)
        #expect(UserTermsStore(fileURL: dupURL, legacyDefaults: defaults).addAlwaysFlag(stored))
        let dupBytes = try Data(contentsOf: dupURL)
        #expect(!openStore(dupURL, defaults).addAlwaysFlag(stored), "the stored term is a duplicate")
        #expect(try Data(contentsOf: dupURL) == dupBytes, "a refused add leaves the file as it was")

        let seed = UserTermsStore(fileURL: capURL, legacyDefaults: defaults)
        for i in 0..<UserTermsStore.perListCap {
            #expect(seed.addAlwaysFlag(UserTerm(pattern: "capped-term-\(i)", isRegex: false)))
        }
        let capBytes = try Data(contentsOf: capURL)
        #expect(!openStore(capURL, defaults).addAlwaysFlag(UserTerm(pattern: "one-over-the-cap", isRegex: false)),
                "the stored list is at the cap")
        #expect(try Data(contentsOf: capURL) == capBytes, "a refused add leaves the file as it was")
    }

    @Test("Terms the rules refuse are dropped when the file is read")
    func refusedTermsDroppedOnRead() {
        let name = "UserTermsStoreTests.sanitizeOnRead"
        let defaults = makeEmptyDefaults(name)
        let fileURL = makeScratchFileURL("user-terms.v1.json")
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        FileJSONBlob<UserTermsBlob>(
            fileURL: fileURL, schemaVersion: UserTermsStore.schemaVersion, fallback: .empty
        ).save(UserTermsBlob(
            alwaysFlag: [UserTerm(pattern: "kept-term", isRegex: false), UserTerm(pattern: "e", isRegex: false)],
            neverFlag: []
        ))
        let store = UserTermsStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.blob.alwaysFlag.map(\.pattern) == ["kept-term"])
    }

    @Test("The custom-terms store reads its file inside its initialiser")
    func readsFileInsideInitialiser() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/ResectaApp/State/UserTermsStore.swift"), encoding: .utf8)
        #expect(!source.contains("Task {"))
        #expect(!source.contains("Task.detached"))
        let sources = root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var swiftFiles = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            swiftFiles += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("asyncHydrate"), "\(url.lastPathComponent) still names the delayed read")
        }
        #expect(swiftFiles > 0)
    }

    @Test("SavedRegexStore: hydration is synchronous — an early save persists and reloads intact")
    func testHydrateDoesNotClobberEarlySavedRegex() async {
        let name = "SavedRegexStoreTests.clobber"
        let defaults = makeEmptyDefaults(name)
        let fileURL = makeScratchFileURL("saved-regexes.v1.json")
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        // The async-hydrate window (and its clobber class) is gone:
        // `SavedRegexStore` hydrates synchronously at init, so there is
        // no tick in which a mutation can persist over an unloaded
        // library. The reload asserts the persisted bytes carry the
        // early save.
        let store = SavedRegexStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.add(label: "Early", pattern: "[0-9]{3}"))

        let reloaded = SavedRegexStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(reloaded.userSavedRegexes.contains(where: { $0.label == "Early" }),
                "the early save must be on disk and visible from init")
    }
}

@Suite("Custom term floor and copy")
@MainActor
struct UserTermFloorTests {

    @Test("A one-character literal is refused; two characters are kept")
    func literalFloor() {
        #expect(UserTermsStore.isValidUserTerm(UserTerm(pattern: "e", isRegex: false)) == false)
        #expect(UserTermsStore.isValidUserTerm(UserTerm(pattern: "\u{00E9}", isRegex: false)) == false)
        #expect(UserTermsStore.isValidUserTerm(UserTerm(pattern: "ab", isRegex: false)) == true)
        let blob = UserTermsStore.sanitize(UserTermsBlob(
            alwaysFlag: [UserTerm(pattern: "e", isRegex: false), UserTerm(pattern: "Ann", isRegex: false)],
            neverFlag: [UserTerm(pattern: "x", isRegex: false)]
        ))
        #expect(blob.alwaysFlag.map(\.pattern) == ["Ann"])
        #expect(blob.neverFlag.isEmpty)
    }

    @Test("The refusal and the Always Flag footer state the literal rules")
    func copy() {
        #expect(CustomTermsView.termTooShortMessage == "Term too short (min 2 characters).")
        #expect(CustomTermsView.alwaysFlagFooter.hasSuffix(
            " Literal terms match anywhere inside a word, in any case."))
    }
}
