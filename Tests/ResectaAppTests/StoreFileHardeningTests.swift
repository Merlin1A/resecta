import Testing
import Foundation
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// UserTermsStore + SavedRegexStore persist as protected, backup-excluded
// JSON files under Application Support — the `SavedSearchStore` posture,
// applied uniformly to every store that persists user-typed content.
// These pins run on the iOS Simulator destination (the app test target's
// only destination): file-protection attributes read back faithfully
// there, unlike a macOS host `swift test` run.
//
// Also pinned here: the one-shot legacy migration each store runs at
// init (pre-file installs carry their UserDefaults blob into the file
// exactly once, then the key is removed) and the destructive clear
// methods behind the two delete-all rows.

@Suite("Store file hardening + legacy migration")
@MainActor
struct StoreFileHardeningTests {

    private static func makeSuite(_ function: String = #function) -> UserDefaults {
        let name = "app.resecta.tests.StoreHardening.\(function).\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    private static func makeScratchFileURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreHardeningTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func removeScratch(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// Shared assertion: the stored file exists, is excluded from
    /// backups, and reports at-least-`.complete` file protection.
    /// Protection semantics mirror the engine's `FileProtectionTests`
    /// host-tolerance posture: a nil readback means the filesystem does
    /// not report protection classes (macOS tooling hosts), and the iOS
    /// Simulator coalesces `.complete` to
    /// `.completeUntilFirstUserAuthentication` because its host
    /// filesystem cannot enforce the lock-screen gate — both are
    /// acceptable readbacks for a `.complete` request. The
    /// backup-exclusion flag is asserted strictly on every host.
    private static func assertHardened(_ fileURL: URL) throws {
        #expect(FileManager.default.fileExists(atPath: fileURL.path),
                "a save must materialize the store file")
        let values = try fileURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
        #expect(values.isExcludedFromBackup == true,
                "isExcludedFromBackup must be true on the store file")
        if let protection = values.fileProtection {
            #expect([.complete, .completeUntilFirstUserAuthentication].contains(protection),
                    "the store file must report at least the coalesced complete class")
        }
    }

    // MARK: - Hardening on save

    @Test("UserTermsStore file is protected and backup-excluded after a save")
    func userTermsFileIsHardened() throws {
        let fileURL = Self.makeScratchFileURL("user-terms.v1.json")
        defer { Self.removeScratch(fileURL) }

        let store = UserTermsStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(store.addAlwaysFlag(UserTerm(pattern: "hardening-probe", isRegex: false)) == .saved)

        try Self.assertHardened(fileURL)
    }

    @Test("SavedRegexStore file is protected and backup-excluded after a save")
    func savedRegexFileIsHardened() throws {
        let fileURL = Self.makeScratchFileURL("saved-regexes.v1.json")
        defer { Self.removeScratch(fileURL) }

        let store = SavedRegexStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(store.add(label: "Hardening probe", pattern: "\\d{2}") == .saved)

        try Self.assertHardened(fileURL)
    }

    @Test("Fresh install touches no file until the first save")
    func freshInitWritesNothing() {
        let fileURL = Self.makeScratchFileURL("user-terms.v1.json")
        defer { Self.removeScratch(fileURL) }

        _ = UserTermsStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(!FileManager.default.fileExists(atPath: fileURL.path),
                "no legacy key and no mutation → nothing on disk")
    }

    // MARK: - One-shot legacy migration

    @Test("UserTermsStore migrates the legacy UserDefaults blob into the file once")
    func userTermsLegacyMigration() throws {
        let defaults = Self.makeSuite()
        let fileURL = Self.makeScratchFileURL("user-terms.v1.json")
        defer { Self.removeScratch(fileURL) }

        // Seed the pre-file location through the legacy envelope type so
        // the bytes match what an upgraded install would hold.
        let legacy = UserDefaultsJSONBlob<UserTermsBlob>(
            key: UserTermsStore.storageKey,
            schemaVersion: UserTermsStore.schemaVersion,
            defaults: defaults,
            fallback: .empty
        )
        legacy.save(UserTermsBlob(
            alwaysFlag: [UserTerm(pattern: "carried-term", isRegex: false)],
            neverFlag: [UserTerm(pattern: "carried-never", isRegex: false)]
        ))

        let store = UserTermsStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.blob.alwaysFlag.map(\.pattern) == ["carried-term"],
                "the legacy blob must hydrate through the file on first init")
        #expect(store.blob.neverFlag.map(\.pattern) == ["carried-never"])
        #expect(defaults.data(forKey: UserTermsStore.storageKey) == nil,
                "the legacy key is removed once the file is on disk")
        try Self.assertHardened(fileURL)

        // Second init reads the file — content stable, still no key.
        let reloaded = UserTermsStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(reloaded.blob.alwaysFlag.map(\.pattern) == ["carried-term"])
        #expect(defaults.data(forKey: UserTermsStore.storageKey) == nil)
    }

    @Test("UserTermsStore publishes the migrated blob from its first moment")
    func userTermsLegacyMigrationVisibleFromInit() {
        let defaults = Self.makeSuite()
        let fileURL = Self.makeScratchFileURL("user-terms.v1.json")
        defer { Self.removeScratch(fileURL) }

        let legacy = UserDefaultsJSONBlob<UserTermsBlob>(
            key: UserTermsStore.storageKey,
            schemaVersion: UserTermsStore.schemaVersion,
            defaults: defaults,
            fallback: .empty
        )
        legacy.save(UserTermsBlob(
            alwaysFlag: [UserTerm(pattern: "async-carried", isRegex: false)],
            neverFlag: []
        ))

        // The migration runs inside init, before the file is read.
        let store = UserTermsStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(defaults.data(forKey: UserTermsStore.storageKey) == nil,
                "migration completes before init returns")
        #expect(store.blob.alwaysFlag.map(\.pattern) == ["async-carried"],
                "the migrated blob is in the store from its first moment")
    }

    @Test("SavedRegexStore migrates the legacy UserDefaults envelope into the file once")
    func savedRegexLegacyMigration() throws {
        let defaults = Self.makeSuite()
        let fileURL = Self.makeScratchFileURL("saved-regexes.v1.json")
        defer { Self.removeScratch(fileURL) }

        let legacy = UserDefaultsJSONBlob<SavedRegexEnvelope>(
            key: SavedRegexStore.storageKey,
            schemaVersion: SavedRegexStore.schemaVersion,
            defaults: defaults,
            fallback: SavedRegexEnvelope(schemaVersion: 1, userSavedRegexes: [])
        )
        legacy.save(SavedRegexEnvelope(
            schemaVersion: 1,
            userSavedRegexes: [SavedRegex(label: "Carried", pattern: "\\d{3}")]
        ))

        let store = SavedRegexStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(store.userSavedRegexes.map(\.label) == ["Carried"],
                "the legacy envelope must hydrate through the file on first init")
        #expect(defaults.data(forKey: SavedRegexStore.storageKey) == nil,
                "the legacy key is removed once the file is on disk")
        try Self.assertHardened(fileURL)

        let reloaded = SavedRegexStore(fileURL: fileURL, legacyDefaults: defaults)
        #expect(reloaded.userSavedRegexes.map(\.label) == ["Carried"])
    }

    // MARK: - Destructive clear

    @Test("clearAllTerms drops both lists and persists the empty pair")
    func clearAllTermsDropsBothLists() {
        let fileURL = Self.makeScratchFileURL("user-terms.v1.json")
        defer { Self.removeScratch(fileURL) }

        let store = UserTermsStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(store.addAlwaysFlag(UserTerm(pattern: "term-a", isRegex: false)) == .saved)
        #expect(store.addNeverFlag(UserTerm(pattern: "term-b", isRegex: false)) == .saved)

        store.clearAllTerms()

        #expect(store.blob == .empty)
        let reloaded = UserTermsStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(reloaded.blob == .empty,
                "the cleared state must be the persisted state")
    }

    @Test("clearAllUserSaved drops the user library; built-ins stay")
    func clearAllUserSavedDropsLibrary() {
        let fileURL = Self.makeScratchFileURL("saved-regexes.v1.json")
        defer { Self.removeScratch(fileURL) }

        let store = SavedRegexStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(store.add(label: "Mine", pattern: "\\d{4}") == .saved)

        store.clearAllUserSaved()

        #expect(store.userSavedRegexes.isEmpty)
        #expect(store.regexes.count == SavedRegexStore.builtIns.count,
                "built-ins are compile-time constants and stay")
        let reloaded = SavedRegexStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(reloaded.userSavedRegexes.isEmpty,
                "the cleared state must be the persisted state")
    }

    // MARK: - A file that is there and cannot be read

    enum TermsChange: CaseIterable, Sendable {
        case addAlways, addNever, removeAlways, removeNever, clearAll
    }

    enum RegexChange: CaseIterable, Sendable {
        case add, delete, clearAll
    }

    private static func apply(_ change: TermsChange, to store: UserTermsStore) -> ListChange {
        switch change {
        case .addAlways: store.addAlwaysFlag(UserTerm(pattern: "new-term", isRegex: false))
        case .addNever: store.addNeverFlag(UserTerm(pattern: "new-term", isRegex: false))
        case .removeAlways: store.removeAlwaysFlag(at: IndexSet())
        case .removeNever: store.removeNeverFlag(at: IndexSet())
        case .clearAll: store.clearAllTerms()
        }
    }

    private static func apply(_ change: RegexChange, to store: SavedRegexStore) -> ListChange {
        switch change {
        case .add: store.add(label: "New", pattern: "[0-9]{6}")
        case .delete: store.deleteUserSaved(at: IndexSet())
        case .clearAll: store.clearAllUserSaved()
        }
    }

    /// A Custom Terms file holding one term on each list, and its bytes.
    private static func seedTerms(_ fileURL: URL) throws -> Data {
        let seed = UserTermsStore(fileURL: fileURL, legacyDefaults: makeSuite())
        #expect(seed.addAlwaysFlag(UserTerm(pattern: "stored-always", isRegex: false)) == .saved)
        #expect(seed.addNeverFlag(UserTerm(pattern: "stored-never", isRegex: false)) == .saved)
        return try Data(contentsOf: fileURL)
    }

    /// A Saved Regexes file holding one pattern, and its bytes.
    private static func seedRegexes(_ fileURL: URL) throws -> Data {
        let seed = SavedRegexStore(fileURL: fileURL, legacyDefaults: makeSuite())
        #expect(seed.add(label: "Stored", pattern: "[0-9]{4}") == .saved)
        return try Data(contentsOf: fileURL)
    }

    @Test("Each list's changes are counted")
    func changeCounts() {
        #expect(TermsChange.allCases.count == 5)
        #expect(RegexChange.allCases.count == 3)
    }

    @Test("Custom Terms: while the stored file cannot be read, every change answers held and the file is left as it is",
          arguments: TermsChange.allCases)
    func termsHeld(_ change: TermsChange) throws {
        let fileURL = Self.makeScratchFileURL("user-terms.v1.json")
        defer { Self.removeScratch(fileURL) }
        let seeded = try Self.seedTerms(fileURL)
        try UnreadableFile.take(fileURL)
        defer { UnreadableFile.restore(fileURL) }

        let store = UserTermsStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(store.blob == .empty)
        #expect(Self.apply(change, to: store) == .held)
        #expect(store.blob == .empty)

        UnreadableFile.restore(fileURL)
        #expect(try Data(contentsOf: fileURL) == seeded)
    }

    @Test("Saved Regexes: while the stored file cannot be read, every change answers held and the file is left as it is",
          arguments: RegexChange.allCases)
    func regexesHeld(_ change: RegexChange) throws {
        let fileURL = Self.makeScratchFileURL("saved-regexes.v1.json")
        defer { Self.removeScratch(fileURL) }
        let seeded = try Self.seedRegexes(fileURL)
        try UnreadableFile.take(fileURL)
        defer { UnreadableFile.restore(fileURL) }

        let store = SavedRegexStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(store.userSavedRegexes.isEmpty)
        #expect(Self.apply(change, to: store) == .held)
        #expect(store.userSavedRegexes.isEmpty)

        UnreadableFile.restore(fileURL)
        #expect(try Data(contentsOf: fileURL) == seeded)
    }

    @Test("Custom Terms and Saved Regexes: an old settings record does not move over a file that cannot be read")
    func legacyRecordHeld() throws {
        let termsURL = Self.makeScratchFileURL("user-terms.v1.json")
        let regexURL = Self.makeScratchFileURL("saved-regexes.v1.json")
        defer { Self.removeScratch(termsURL); Self.removeScratch(regexURL) }
        let termsSeed = try Self.seedTerms(termsURL)
        let regexSeed = try Self.seedRegexes(regexURL)
        let termsDefaults = Self.makeSuite()
        let regexDefaults = Self.makeSuite()
        UserDefaultsJSONBlob<UserTermsBlob>(
            key: UserTermsStore.storageKey, schemaVersion: UserTermsStore.schemaVersion,
            defaults: termsDefaults, fallback: .empty
        ).save(UserTermsBlob(alwaysFlag: [UserTerm(pattern: "old-term", isRegex: false)], neverFlag: []))
        UserDefaultsJSONBlob<SavedRegexEnvelope>(
            key: SavedRegexStore.storageKey, schemaVersion: SavedRegexStore.schemaVersion,
            defaults: regexDefaults, fallback: SavedRegexEnvelope(schemaVersion: 1, userSavedRegexes: [])
        ).save(SavedRegexEnvelope(schemaVersion: 1, userSavedRegexes: [SavedRegex(label: "Old", pattern: "[0-9]{2}")]))
        try UnreadableFile.take(termsURL)
        try UnreadableFile.take(regexURL)
        defer { UnreadableFile.restore(termsURL); UnreadableFile.restore(regexURL) }

        let terms = UserTermsStore(fileURL: termsURL, legacyDefaults: termsDefaults)
        let regexes = SavedRegexStore(fileURL: regexURL, legacyDefaults: regexDefaults)
        #expect(terms.clearAllTerms() == .held)
        #expect(regexes.clearAllUserSaved() == .held)

        UnreadableFile.restore(termsURL)
        UnreadableFile.restore(regexURL)
        #expect(try Data(contentsOf: termsURL) == termsSeed)
        #expect(try Data(contentsOf: regexURL) == regexSeed)
        #expect(termsDefaults.data(forKey: UserTermsStore.storageKey) != nil)
        #expect(regexDefaults.data(forKey: SavedRegexStore.storageKey) != nil)
    }

    @Test("Custom Terms and Saved Regexes: once the file can be read, the stored entries load before the change is applied")
    func heldThenReadable() throws {
        let termsURL = Self.makeScratchFileURL("user-terms.v1.json")
        let regexURL = Self.makeScratchFileURL("saved-regexes.v1.json")
        defer { Self.removeScratch(termsURL); Self.removeScratch(regexURL) }
        _ = try Self.seedTerms(termsURL)
        _ = try Self.seedRegexes(regexURL)
        try UnreadableFile.take(termsURL)
        try UnreadableFile.take(regexURL)
        let terms = UserTermsStore(fileURL: termsURL, legacyDefaults: Self.makeSuite())
        let regexes = SavedRegexStore(fileURL: regexURL, legacyDefaults: Self.makeSuite())
        UnreadableFile.restore(termsURL)
        UnreadableFile.restore(regexURL)

        #expect(terms.addAlwaysFlag(UserTerm(pattern: "new-term", isRegex: false)) == .saved)
        #expect(regexes.add(label: "New", pattern: "[0-9]{6}") == .saved)

        let alwaysExpected = ["stored-always", "new-term"]
        #expect(terms.blob.alwaysFlag.map(\.pattern) == alwaysExpected)
        #expect(terms.blob.neverFlag.map(\.pattern) == ["stored-never"])
        #expect(regexes.userSavedRegexes.map(\.label) == ["Stored", "New"])
        let termsAgain = UserTermsStore(fileURL: termsURL, legacyDefaults: Self.makeSuite())
        let regexesAgain = SavedRegexStore(fileURL: regexURL, legacyDefaults: Self.makeSuite())
        #expect(termsAgain.blob.alwaysFlag.map(\.pattern) == alwaysExpected)
        #expect(termsAgain.blob.neverFlag.map(\.pattern) == ["stored-never"])
        #expect(regexesAgain.userSavedRegexes.map(\.label) == ["Stored", "New"])
    }

    enum ReadAgainNotice: CaseIterable, Sendable {
        case cameToTheFront, protectedFilesAvailable
        var name: Notification.Name {
            switch self {
            case .cameToTheFront: UIApplication.didBecomeActiveNotification
            case .protectedFilesAvailable: UIApplication.protectedDataDidBecomeAvailableNotification
            }
        }
    }

    @Test("Custom Terms and Saved Regexes: the stored entries load when the app comes to the front, and when protected files become available",
          arguments: ReadAgainNotice.allCases)
    func heldReadsAgainOnNotice(_ notice: ReadAgainNotice) throws {
        #expect(ReadAgainNotice.allCases.count == 2)
        let termsURL = Self.makeScratchFileURL("user-terms.v1.json")
        let regexURL = Self.makeScratchFileURL("saved-regexes.v1.json")
        defer { Self.removeScratch(termsURL); Self.removeScratch(regexURL) }
        _ = try Self.seedTerms(termsURL)
        _ = try Self.seedRegexes(regexURL)
        try UnreadableFile.take(termsURL)
        try UnreadableFile.take(regexURL)
        let terms = UserTermsStore(fileURL: termsURL, legacyDefaults: Self.makeSuite())
        let regexes = SavedRegexStore(fileURL: regexURL, legacyDefaults: Self.makeSuite())
        UnreadableFile.restore(termsURL)
        UnreadableFile.restore(regexURL)
        #expect(terms.blob == .empty)

        NotificationCenter.default.post(name: notice.name, object: nil)

        #expect(terms.blob.alwaysFlag.map(\.pattern) == ["stored-always"])
        #expect(regexes.userSavedRegexes.map(\.label) == ["Stored"])
    }

    enum TermsRefusal: CaseIterable, Sendable {
        case empty, oneCharacter, badRegex, overLong, atCap, duplicate, ordinary
    }

    @Test("Custom Terms has seven refusal and save cases")
    func termsRefusalCount() { #expect(TermsRefusal.allCases.count == 7) }

    @Test("Custom Terms: each refusal names its reason, and an ordinary change is saved",
          arguments: TermsRefusal.allCases)
    func termsRefusals(_ row: TermsRefusal) {
        let fileURL = Self.makeScratchFileURL("user-terms.v1.json")
        defer { Self.removeScratch(fileURL) }
        let store = UserTermsStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        let term: UserTerm
        let expected: ListChange
        switch row {
        case .empty: term = UserTerm(pattern: "", isRegex: false); expected = .refused(.invalid)
        case .oneCharacter: term = UserTerm(pattern: "a", isRegex: false); expected = .refused(.invalid)
        case .badRegex: term = UserTerm(pattern: "([a-z", isRegex: true); expected = .refused(.invalid)
        case .overLong:
            term = UserTerm(pattern: String(repeating: "a", count: UserTermsStore.patternLengthCap + 1), isRegex: false)
            expected = .refused(.invalid)
        case .atCap:
            for i in 0..<UserTermsStore.perListCap {
                #expect(store.addAlwaysFlag(UserTerm(pattern: "cap-\(i)", isRegex: false)) == .saved)
            }
            term = UserTerm(pattern: "one-more", isRegex: false); expected = .refused(.full)
        case .duplicate:
            #expect(store.addAlwaysFlag(UserTerm(pattern: "twice", isRegex: false)) == .saved)
            term = UserTerm(pattern: "twice", isRegex: false); expected = .refused(.duplicate)
        case .ordinary: term = UserTerm(pattern: "ordinary", isRegex: false); expected = .saved
        }
        #expect(store.addAlwaysFlag(term) == expected)
        #expect(store.addNeverFlag(term) == (row == .atCap || row == .duplicate ? .saved : expected))
    }

    enum RegexRefusal: CaseIterable, Sendable {
        case emptyLabel, emptyPattern, overLong, atCap, badRegex, builtInLabel, savedLabel, ordinary
    }

    @Test("Saved Regexes has eight refusal and save cases")
    func regexRefusalCount() { #expect(RegexRefusal.allCases.count == 8) }

    @Test("Saved Regexes: each refusal names its reason, and an ordinary change is saved",
          arguments: RegexRefusal.allCases)
    func regexRefusals(_ row: RegexRefusal) throws {
        let fileURL = Self.makeScratchFileURL("saved-regexes.v1.json")
        defer { Self.removeScratch(fileURL) }
        let store = SavedRegexStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        let answer: ListChange
        switch row {
        case .emptyLabel: answer = store.add(label: " ", pattern: "[0-9]{2}")
        case .emptyPattern: answer = store.add(label: "Label", pattern: " ")
        case .overLong:
            answer = store.add(label: "Label", pattern: String(repeating: "a", count: SavedRegexStore.patternLengthCap + 1))
        case .atCap:
            for i in 0..<SavedRegexStore.userSavedCap {
                #expect(store.add(label: "cap-\(i)", pattern: "p\(i)\\d") == .saved)
            }
            answer = store.add(label: "one-more", pattern: "[0-9]{2}")
        case .badRegex: answer = store.add(label: "Label", pattern: "([a-z")
        case .builtInLabel:
            let builtIn = try #require(SavedRegexStore.builtIns.first)
            answer = store.add(label: builtIn.label, pattern: "[0-9]{2}")
        case .savedLabel:
            #expect(store.add(label: "Twice", pattern: "[0-9]{2}") == .saved)
            answer = store.add(label: "Twice", pattern: "[0-9]{3}")
        case .ordinary: answer = store.add(label: "Ordinary", pattern: "[0-9]{2}")
        }
        let expected: ListChange = switch row {
        case .emptyLabel, .emptyPattern, .overLong, .badRegex: .refused(.invalid)
        case .atCap: .refused(.full)
        case .builtInLabel, .savedLabel: .refused(.duplicate)
        case .ordinary: .saved
        }
        #expect(answer == expected)
    }
}
