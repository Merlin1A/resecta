import Foundation

// A UserDefaults suite that exists for one test: a UUID-named domain the
// test owns, removed again when the test is done. A test that goes through
// here never reads or writes the app's own domain (`UserDefaults.standard`
// on the simulator); the product type takes the suite through its
// `defaults:` seam (`SettingsState(defaults:)`, `SearchState(defaults:)`,
// `UserDefaultsJSONBlob(defaults:)`, …).

/// A fresh scratch suite and its name, for `removePersistentDomain(forName:)`
/// in a `defer` when the test body is `async` or long.
func makeScratchDefaults() -> (UserDefaults, suiteName: String) {
    let name = "app.resecta.tests.scratch.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return (defaults, name)
}

/// Run `body` with a scratch suite; its domain is removed on the way out.
func withScratchDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let (defaults, suiteName) = makeScratchDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    return try body(defaults)
}
