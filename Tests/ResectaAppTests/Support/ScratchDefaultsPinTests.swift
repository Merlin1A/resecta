import Foundation
import Testing

// The app's tests build their settings and search state on a scratch
// defaults suite (`Support/ScratchDefaults.swift`): a bare `SettingsState()`
// or a `UserDefaults.standard` read in a test touches the simulator's shared
// domain and carries state from one test into the next. This suite scans
// the two app test trees for either shape, comments stripped, and lists
// every site. Until `RESECTA_PIN_SCRATCH_DEFAULTS` is `1` (plain, or with
// the `TEST_RUNNER_` prefix xcodebuild forwards) it records the sites as a
// warning-severity issue and passes; at `1` it fails on any site.

@Suite("Scratch-defaults pin")
struct ScratchDefaultsPinTests {

    private static let needles = ["SettingsState()", "UserDefaults.standard"]
    private static let trees = ["Tests/ResectaAppTests", "Tests/ResectaAppUITests"]
    private static let exempt = ["Tests/ResectaAppTests/Support/ScratchDefaults.swift"]

    @Test("app tests build their defaults on a scratch suite")
    func noSharedDefaultsInAppTests() throws {
        let root = Self.repoRoot()
        let ownPath = URL(fileURLWithPath: "\(#filePath)").standardizedFileURL.path
        var offences: [String] = []
        for tree in Self.trees {
            let treeURL = root.appendingPathComponent(tree)
            guard let walker = FileManager.default.enumerator(at: treeURL, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let path = url.standardizedFileURL.path
                let relative = String(path.dropFirst(root.path.count + 1))
                if path == ownPath || Self.exempt.contains(relative) { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let code = line.components(separatedBy: "//").first ?? ""
                    if Self.needles.contains(where: { code.contains($0) }) {
                        offences.append("\(relative):\(index + 1)")
                    }
                }
            }
        }
        let enforcing = Self.env("RESECTA_PIN_SCRATCH_DEFAULTS") == "1"
        if !enforcing && !offences.isEmpty {
            TestGate.skip("scratch-defaults pin (report-only): \(offences.count) test site(s) build on the shared defaults domain; first: \(offences.prefix(3).joined(separator: ", ")). Set RESECTA_PIN_SCRATCH_DEFAULTS=1 to fail on them.")
            return
        }
        #expect(offences.isEmpty, "test sites on the shared defaults domain: \(offences.joined(separator: ", "))")
    }

    // MARK: - Helpers

    /// The variable as the test process sees it, or as xcodebuild forwards it
    /// with the `TEST_RUNNER_` prefix.
    private static func env(_ key: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment[key], !value.isEmpty { return value }
        if let value = environment["TEST_RUNNER_" + key], !value.isEmpty { return value }
        return nil
    }

    private static func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests/Support
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }
}
