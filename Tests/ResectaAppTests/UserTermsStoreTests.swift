import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// CAT-342 (C-J2) — the async-hydrate write-back must not clobber a term/regex
// the user adds in the window between the off-MainActor snapshot and the
// MainActor write-back. Both stores set an `isHydrated` barrier on any mutation
// (via persist()); the hydrate write-back (`applyHydration`) skips once the
// barrier is set, so the user's in-memory addition survives — storage is
// already authoritative because persist() wrote it. The stored term reappears
// on the next cold launch (the snapshot is dropped, not merged, to avoid
// duplicate entries).
//
// These guards drive `applyHydration` directly with a pre-add snapshot to make
// the race deterministic (a real detached read would observe the post-add
// storage and mask the bug). The live `hydrationTask` — which calls the same
// seam — is drained at the end so no task dangles past the test.

@Suite("Store async-hydrate race guard (CAT-342)")
@MainActor
struct UserTermsStoreHydrationTests {

    private func makeEmptyDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("UserTermsStore: a stale hydrate write-back does not clobber an early add")
    func testHydrateDoesNotClobberEarlyAdd() async {
        let name = "UserTermsStoreTests.clobber.always"
        let defaults = makeEmptyDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let store = UserTermsStore(defaults: defaults, asyncHydrate: true)
        // Real race window: blob == .empty, the detached snapshot is in flight.
        let early = UserTerm(pattern: "early-term", isRegex: false)
        #expect(store.addAlwaysFlag(early))

        // The stale snapshot (taken before the add) lands late. Drive the same
        // seam the in-flight task calls, with the pre-add value.
        let stale = UserTermsBlob(
            alwaysFlag: [UserTerm(pattern: "prior-term", isRegex: false)],
            neverFlag: []
        )
        store.applyHydration(stale)

        #expect(store.blob.alwaysFlag.contains(early),
                "the early add must survive a stale hydrate write-back")
        #expect(!store.blob.alwaysFlag.contains(UserTerm(pattern: "prior-term", isRegex: false)),
                "the stale snapshot is dropped, not merged (storage is authoritative)")

        await store.hydrationTask?.value   // drain the live task (also skips)
    }

    @Test("SavedRegexStore: hydration is synchronous — an early save persists and reloads intact")
    func testHydrateDoesNotClobberEarlySavedRegex() async {
        let name = "SavedRegexStoreTests.clobber"
        let defaults = makeEmptyDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        // The async-hydrate window (and its clobber class) is gone:
        // `SavedRegexStore` hydrates synchronously at init, so there is
        // no tick in which a mutation can persist over an unloaded
        // library. The reload asserts the persisted bytes carry the
        // early save.
        let store = SavedRegexStore(defaults: defaults)
        #expect(store.add(label: "Early", pattern: "[0-9]{3}"))

        let reloaded = SavedRegexStore(defaults: defaults)
        #expect(reloaded.userSavedRegexes.contains(where: { $0.label == "Early" }),
                "the early save must be on disk and visible from init")
    }
}
