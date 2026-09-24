import Testing
import Foundation
import SwiftUI
@testable import ResectaApp

// Coverage for the Appearance
// preference: defaults to .system, persists across init via the
// `appearancePreference.v1` UserDefaults key, and is restored to
// .system by `resetToDefaults()`. Every test runs on a scratch suite
// through `SettingsState(defaults:)`; `.standard` is never touched.

@Suite("SettingsState Appearance Preference")
@MainActor
struct SettingsStateAppearanceTests {

    private static let key = "appearancePreference.v1"

    @Test("Fresh init with no stored value defaults to .system")
    func testAppearancePreferenceDefaultsToSystem() {
        withScratchDefaults { defaults in
            let state = SettingsState(defaults: defaults)
            #expect(state.appearancePreference == .system)
        }
    }

    @Test("Stored value round-trips across init",
          arguments: [AppearancePreference.system, .light, .dark])
    func testAppearancePreferencePersistsAcrossInit(_ pref: AppearancePreference) {
        withScratchDefaults { defaults in
            let first = SettingsState(defaults: defaults)
            first.appearancePreference = pref
            #expect(defaults.string(forKey: Self.key) == pref.rawValue)

            let second = SettingsState(defaults: defaults)
            #expect(second.appearancePreference == pref)
        }
    }

    @Test("Unknown stored value falls back to .system")
    func testUnknownStoredAppearanceFallsBackToSystem() {
        withScratchDefaults { defaults in
            defaults.set("rainbow", forKey: Self.key)
            let state = SettingsState(defaults: defaults)
            #expect(state.appearancePreference == .system)
        }
    }

    @Test("resetToDefaults restores .system")
    func testResetToDefaultsRestoresSystemAppearance() {
        withScratchDefaults { defaults in
            let state = SettingsState(defaults: defaults)
            state.appearancePreference = .dark
            #expect(state.appearancePreference == .dark)

            state.resetToDefaults()
            #expect(state.appearancePreference == .system)
            #expect(defaults.string(forKey: Self.key) == AppearancePreference.system.rawValue)
        }
    }

    @Test("colorScheme maps correctly")
    func testColorSchemeMapping() {
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
    }
}
