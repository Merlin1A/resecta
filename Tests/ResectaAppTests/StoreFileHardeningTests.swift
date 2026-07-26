import Testing
import Foundation
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
        #expect(store.addAlwaysFlag(UserTerm(pattern: "hardening-probe", isRegex: false)))

        try Self.assertHardened(fileURL)
    }

    @Test("SavedRegexStore file is protected and backup-excluded after a save")
    func savedRegexFileIsHardened() throws {
        let fileURL = Self.makeScratchFileURL("saved-regexes.v1.json")
        defer { Self.removeScratch(fileURL) }

        let store = SavedRegexStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(store.add(label: "Hardening probe", pattern: "\\d{2}"))

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

    @Test("UserTermsStore async-hydrate path publishes the migrated blob")
    func userTermsLegacyMigrationAsyncHydrate() async {
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

        // The migration itself is synchronous inside init; only the file
        // read rides the detached hydrate.
        let store = UserTermsStore(fileURL: fileURL, legacyDefaults: defaults, asyncHydrate: true)
        #expect(defaults.data(forKey: UserTermsStore.storageKey) == nil,
                "migration completes before init returns")
        await store.hydrationTask?.value
        #expect(store.blob.alwaysFlag.map(\.pattern) == ["async-carried"],
                "the migrated blob must publish through the async hydrate")
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
        #expect(store.addAlwaysFlag(UserTerm(pattern: "term-a", isRegex: false)))
        #expect(store.addNeverFlag(UserTerm(pattern: "term-b", isRegex: false)))

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
        #expect(store.add(label: "Mine", pattern: "\\d{4}"))

        store.clearAllUserSaved()

        #expect(store.userSavedRegexes.isEmpty)
        #expect(store.regexes.count == SavedRegexStore.builtIns.count,
                "built-ins are compile-time constants and stay")
        let reloaded = SavedRegexStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        #expect(reloaded.userSavedRegexes.isEmpty,
                "the cleared state must be the persisted state")
    }
}
