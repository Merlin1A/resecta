import Testing
import Foundation
@testable import ResectaApp

// The apply path's turn gate and phase check live in
// `RedactionApplyEngine.applyFindings`. The two origins and the turn calls
// it wraps are module-internal (they sit in two files), so this pins that
// no other app source calls them: a direct call would skip both the turn
// gate and `canMutateRegions`.

@Suite("Apply gate callers")
struct ApplyGateCallersTests {

    static let gated = [
        "applySelectedSearchResultsOrigin(", "applySearchResultOrigin(",
        "waitForApplyTurn(", "endApplyTurn(",
    ]

    @Test("Only RedactionApplyEngine.swift calls the apply origins and the turn gate")
    func gatedMembersHaveOneCallerFile() throws {
        let sources = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
        let files = try #require(FileManager.default.enumerator(atPath: sources.path))
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
        #expect(files.count > 100, "the source tree was not found")
        var callers: [String: Set<String>] = [:]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                for name in Self.gated where code.contains(name) && !code.contains("func \(name)") {
                    callers[name, default: []].insert((file as NSString).lastPathComponent)
                }
            }
        }
        for name in Self.gated {
            #expect(callers[name] == ["RedactionApplyEngine.swift"],
                    "\(name) is called from \(callers[name].map { $0.sorted() } ?? [])")
        }
    }
}
