import Testing
import Foundation
import SwiftUI
@testable import ResectaApp

// 02-dark-mode-design.md §2, §3, §6.4 — Coverage for the Appearance
// preference: defaults to .system, persists across init via the
// `appearancePreference.v1` UserDefaults key, and is restored to
// .system by `resetToDefaults()`.

@Suite("SettingsState Appearance Preference")
@MainActor
struct SettingsStateAppearanceTests {

    private static let key = "appearancePreference.v1"

    /// Clear the key before each test so we exercise the init fallback.
    private func cleanDefaults() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test("Fresh init with no stored value defaults to .system")
    func testAppearancePreferenceDefaultsToSystem() {
        cleanDefaults()
        let state = SettingsState()
        #expect(state.appearancePreference == .system)
    }

    @Test("Stored value round-trips across init",
          arguments: [AppearancePreference.system, .light, .dark])
    func testAppearancePreferencePersistsAcrossInit(_ pref: AppearancePreference) {
        cleanDefaults()
        let first = SettingsState()
        first.appearancePreference = pref
        #expect(UserDefaults.standard.string(forKey: Self.key) == pref.rawValue)

        let second = SettingsState()
        #expect(second.appearancePreference == pref)
    }

    @Test("Unknown stored value falls back to .system")
    func testUnknownStoredAppearanceFallsBackToSystem() {
        cleanDefaults()
        UserDefaults.standard.set("rainbow", forKey: Self.key)
        let state = SettingsState()
        #expect(state.appearancePreference == .system)
    }

    @Test("resetToDefaults restores .system")
    func testResetToDefaultsRestoresSystemAppearance() {
        cleanDefaults()
        let state = SettingsState()
        state.appearancePreference = .dark
        #expect(state.appearancePreference == .dark)

        state.resetToDefaults()
        #expect(state.appearancePreference == .system)
        #expect(UserDefaults.standard.string(forKey: Self.key) == AppearancePreference.system.rawValue)
    }

    @Test("colorScheme maps correctly")
    func testColorSchemeMapping() {
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
    }
}
