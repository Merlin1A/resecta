import Foundation
import Testing

// The app's tests build their settings and search state on a scratch
// defaults suite (`Support/ScratchDefaults.swift`): a bare `SettingsState()`
// or a `UserDefaults.standard` read in a test touches the simulator's shared
// domain and carries state from one test into the next. This suite scans
// the two app test trees for either shape, comments stripped, and
// fails on any site it lists.

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
        #expect(offences.isEmpty, "test sites on the shared defaults domain: \(offences.joined(separator: ", "))")
    }

    // MARK: - Helpers

    private static func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests/Support
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }
}
