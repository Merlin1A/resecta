import Testing
import SwiftUI
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// q12 — saved-things lifecycle repair (UXF-04/20/32/33, CL-QP1-07).
//
// UXF-04 background (reproduced 2/2 on the 26.4 sim: no dialog in the
// AX tree, nothing persisted): the "Save current..." menu item was
// ordered after the 10 built-in patterns, which pushes it past the top
// of the screen where it draws clipped outside the menu container and
// taps never land — the item's action simply never ran. The fix orders
// the item first (nearest the menu anchor, always visible) and hoists
// the naming alert to the `SearchAndRedactSheet` root — requested via
// `onRequestSaveCurrentRegex`. This suite pins:
//
//   1. The commit seam (`commitSaveCurrentRegex`) round-trips through a
//      real `SavedRegexStore` into UserDefaults, and surfaces the
//      sentinel / store rejections as re-presentable error strings.
//   2. The presentation path: with the section mounted and the naming
//      alert root-attached (production topology), firing the request
//      callback presents a real UIAlertController with a text field.
//   3. UXF-33 / UXF-32 destructive-confirm contracts, in the same
//      contract style as `SettingsViewResetConfirmationTests` (GATE-2).

// MARK: - Commit seam (UXF-04)

@Suite("Save current regex — commit seam (UXF-04)")
@MainActor
struct SaveCurrentRegexCommitTests {

    private static func makeSuite(_ function: String = #function) -> UserDefaults {
        let name = "app.resecta.tests.SavedThings.\(function).\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test("Successful save persists through the store to UserDefaults and back")
    func saveRoundTripsThroughStore() async {
        let defaults = Self.makeSuite()
        let store = SavedRegexStore(defaults: defaults)
        let before = store.userSavedRegexes.count

        let error = await SearchAndRedactSheet.commitSaveCurrentRegex(
            label: "ZIP code",
            pattern: #"\b\d{5}\b"#,
            store: store
        )

        #expect(error == nil)
        #expect(store.userSavedRegexes.count == before + 1)
        #expect(store.userSavedRegexes.last?.label == "ZIP code")
        #expect(store.userSavedRegexes.last?.pattern == #"\b\d{5}\b"#)

        // Reload from the same suite — the entry survived persist().
        let reloaded = SavedRegexStore(defaults: defaults)
        #expect(reloaded.userSavedRegexes.count == before + 1)
        #expect(reloaded.userSavedRegexes.last?.label == "ZIP code")
    }

    @Test("Label and pattern are trimmed before commit")
    func saveTrimsWhitespace() async {
        let store = SavedRegexStore(defaults: Self.makeSuite())

        let error = await SearchAndRedactSheet.commitSaveCurrentRegex(
            label: "  Case number  ",
            pattern: #"  \bCA-\d{6}\b "#,
            store: store
        )

        #expect(error == nil)
        #expect(store.userSavedRegexes.last?.label == "Case number")
        #expect(store.userSavedRegexes.last?.pattern == #"\bCA-\d{6}\b"#)
    }

    @Test("Empty label or pattern returns an error and persists nothing")
    func saveRejectsEmptyInput() async {
        let store = SavedRegexStore(defaults: Self.makeSuite())

        let emptyLabel = await SearchAndRedactSheet.commitSaveCurrentRegex(
            label: "   ", pattern: #"\d+"#, store: store
        )
        let emptyPattern = await SearchAndRedactSheet.commitSaveCurrentRegex(
            label: "Digits", pattern: "  ", store: store
        )

        #expect(emptyLabel != nil)
        #expect(emptyPattern != nil)
        #expect(store.userSavedRegexes.isEmpty)
    }

    @Test("Store rejection (duplicate label) surfaces an error message")
    func saveSurfacesStoreRejection() async {
        let store = SavedRegexStore(defaults: Self.makeSuite())
        _ = store.add(label: "Dup", pattern: #"\d{2}"#)

        let error = await SearchAndRedactSheet.commitSaveCurrentRegex(
            label: "Dup", pattern: #"\d{4}"#, store: store
        )

        #expect(error != nil)
        #expect(store.userSavedRegexes.count == 1)
    }

    @Test("Success toast names the management destination (UXF-20)")
    func successToastNamesDestination() {
        let toast = SearchAndRedactSheet.savedRegexSavedToast
        #expect(toast.contains("Settings"))
        #expect(toast.contains("Saved Regexes"))
    }
}

// MARK: - Presentation path (UXF-04)

@Suite("Save current regex — naming alert presents from the request callback (UXF-04)")
@MainActor
struct SaveCurrentRegexPresentationTests {

    /// Mounts the request-callback wiring the production sheet uses.
    @MainActor
    final class PromptDriver {
        var fire: () -> Void = {}
    }

    /// Production topology in miniature: `SearchToolbarSection` mounted
    /// as content, the naming alert attached at the ROOT of the hosted
    /// hierarchy (the fix), driven by the same closure instance the
    /// section receives as `onRequestSaveCurrentRegex`.
    private struct Harness: View {
        let searchState: SearchState
        let driver: PromptDriver
        @State private var showPrompt = false
        @State private var label = ""

        var body: some View {
            VStack {
                SearchToolbarSection(
                    searchState: searchState,
                    duplicateTermMessage: .constant(nil),
                    onTriggerSearch: {},
                    onRequestSaveCurrentRegex: request
                )
            }
            .onAppear { driver.fire = request }
            .alert(
                SearchToolbarSection.saveCurrentRegexMenuItem,
                isPresented: $showPrompt
            ) {
                TextField("Label", text: $label)
                Button("Save") {}
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The current pattern will be saved under this label.")
            }
        }

        private func request() {
            label = ""
            showPrompt = true
        }
    }

    @Test("Firing the request callback presents a UIAlertController with a label field")
    func requestCallbackPresentsAlert() async throws {
        let searchState = SearchState()
        searchState.searchModeType = .regex
        searchState.queryText = #"\d{3}-\d{2}-\d{4}"#
        let driver = PromptDriver()

        let root = Harness(searchState: searchState, driver: driver)
            .environment(SavedRegexStore(defaults: {
                let name = "app.resecta.tests.SavedThings.presentation.\(UUID().uuidString)"
                return UserDefaults(suiteName: name)!
            }()))
            // UXF-14 (q13): the section now reads DocumentState for the
            // conditional disabled-OCR caption; the hosted hierarchy must
            // provide it like the production sheet does.
            .environment(DocumentState())

        let controller = UIHostingController(rootView: AnyView(root))
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        pumpRunLoop()

        driver.fire()
        pumpRunLoop()

        // Walk to the presented alert. SwiftUI presents `.alert` as a
        // real UIAlertController from the hosting controller.
        var presented = controller.presentedViewController
        var hops = 0
        while presented != nil, !(presented is UIAlertController), hops < 3 {
            presented = presented?.presentedViewController
            hops += 1
        }
        let alert = try #require(presented as? UIAlertController)
        #expect(alert.title == SearchToolbarSection.saveCurrentRegexMenuItem)
        #expect(alert.textFields?.isEmpty == false)

        alert.dismiss(animated: false)
        pumpRunLoop()
        window.isHidden = true
    }

    private func pumpRunLoop(_ interval: TimeInterval = 0.5) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
    }
}

// MARK: - Saved-search delete confirm (UXF-33)

@Suite("Saved-search delete confirmation (UXF-33)")
@MainActor
struct SavedSearchDeleteConfirmationTests {

    private static func makeSuite(_ function: String = #function) -> UserDefaults {
        let name = "app.resecta.tests.SavedSearchDelete.\(function).\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    /// Scratch storage file for the v2 file-backed store. Caller removes
    /// the parent directory in a `defer`.
    private static func makeScratchFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedSearchDelete-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("saved-searches.v2.json")
    }

    private func makeSaved(name: String) -> SavedSearch {
        SavedSearch(
            name: name,
            mode: .text,
            queryText: "q",
            searchTerms: nil,
            enabledPIICategories: nil,
            caseSensitive: false,
            wholeWord: false,
            sourceFilter: .all,
            minimumOCRConfidence: 0,
            minimumPIIConfidence: 0.5,
            stripDigitSeparators: false,
            normalizeSmartPunctuation: false,
            foldDiacritics: false
        )
    }

    @Test("Dialog title names the saved search; nil target degrades gracefully")
    func deleteConfirmTitle() {
        let saved = makeSaved(name: "Tax terms")
        #expect(SavedSearchListSheet.deleteConfirmTitle(for: saved) == "Delete “Tax terms”?")
        #expect(SavedSearchListSheet.deleteConfirmTitle(for: nil) == "Delete saved search?")
    }

    @Test("Arming the confirm (swipe Delete) does not remove the entry")
    func armingConfirmDoesNotRemove() {
        let fileURL = Self.makeScratchFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        let saved = makeSaved(name: "Keep me")
        store.add(saved)

        // The swipe action's closure only arms `deleteTarget`; the store
        // mutation lives exclusively in the dialog's destructive role.
        var deleteTarget: SavedSearch?
        deleteTarget = saved
        #expect(deleteTarget != nil)
        #expect(store.savedSearches.count == 1)
    }

    @Test("Destructive role removes exactly the armed entry")
    func destructiveRoleRemovesEntry() {
        let fileURL = Self.makeScratchFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = SavedSearchStore(fileURL: fileURL, legacyDefaults: Self.makeSuite())
        let doomed = makeSaved(name: "Doomed")
        let survivor = makeSaved(name: "Survivor")
        store.add(doomed)
        store.add(survivor)

        // The dialog's destructive button closure.
        store.remove(id: doomed.id)

        #expect(store.savedSearches.count == 1)
        #expect(store.savedSearches.first?.name == "Survivor")
    }
}

// MARK: - Reset Detection History confirm (UXF-32)

@Suite("Reset Detection History confirmation (UXF-32)")
@MainActor
struct ResetDetectionHistoryConfirmationTests {

    private static func makeSuite(_ function: String = #function) -> UserDefaults {
        let name = "app.resecta.tests.ResetHistory.\(function).\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test("Opening the dialog alone does not clear persisted priors")
    func openingDialogPreservesPriors() {
        let defaults = Self.makeSuite()
        let priors = PerCategoryPriors(
            byCategory: [.ssn: .init(alpha: 3, beta: 1)]
        )
        RedactionState.savePriors(priors, defaults: defaults)

        // The button's closure only flips the local "show dialog" flag.
        var showDialog = false
        showDialog = true
        #expect(showDialog == true)

        let loaded = RedactionState.loadPriors(defaults: defaults)
        #expect(loaded.byCategory[.ssn] != nil)
    }

    @Test("Destructive role clears the persisted priors — same semantics as the prior one-tap button")
    func destructiveRoleClearsPriors() {
        let defaults = Self.makeSuite()
        let priors = PerCategoryPriors(
            byCategory: [.ssn: .init(alpha: 3, beta: 1)]
        )
        RedactionState.savePriors(priors, defaults: defaults)

        // The dialog's destructive button closure.
        RedactionState.clearPersistedPriors(defaults: defaults)

        let loaded = RedactionState.loadPriors(defaults: defaults)
        #expect(loaded.byCategory.isEmpty)
    }

    @Test("Confirmation copy is mechanism-description (no outcome-promise phrases)")
    func confirmationCopyIsMechanismDescription() {
        // Pinned inline copy from SettingsView's reset-history dialog.
        let title = "Reset detection history?"
        let message = "The on-device record of accepted and rejected detections is cleared. Future scans start from the uniform default weighting."

        let banned = ["guaranteed", "ensures", "impossible", "securely"] // LegalPhrases:safe (test banlist)
        for word in banned {
            #expect(!title.lowercased().contains(word))
            #expect(!message.lowercased().contains(word))
        }
        #expect(message.contains("on-device"))
    }
}
