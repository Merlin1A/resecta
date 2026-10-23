import Testing
import Foundation
@testable import ResectaApp

// Settings that no longer exist leave no stored value behind: loading the
// settings removes the retired keys from an upgraded install's defaults.

@Suite("Retired settings keys")
@MainActor
struct RetiredSettingsKeysTests {

    @Test("Loading the settings removes every retired key's stored value")
    func retiredKeysAreRemovedOnLoad() {
        let name = "app.resecta.tests.RetiredSettingsKeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SettingsState.retiredDefaultsKeys.count == 2)
        for key in SettingsState.retiredDefaultsKeys { defaults.set(1, forKey: key) }

        _ = SettingsState(defaults: defaults)

        for key in SettingsState.retiredDefaultsKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) must be removed")
        }
    }
}
