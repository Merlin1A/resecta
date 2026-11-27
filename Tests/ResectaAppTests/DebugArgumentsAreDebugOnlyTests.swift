import Testing
import Foundation

// The one debug argument no list of names can pin: `--pinRunQualityCap=`
// writes the coordinator's quality cap, and a write to the cap lowers the
// quality of every page a run paints. So the writers themselves are pinned:
// under the app's sources, exactly three code lines assign the cap, the
// declaration, the memory warning's lowering and the DEBUG launch hook, and
// the hook's line lies inside `#if DEBUG`. Comment lines are skipped, as
// the seeds' pin skips them (`DebugSeedOptionsTests`).

@Suite("Debug arguments are debug only")
struct DebugArgumentsAreDebugOnlyTests {

    /// A code line that assigns the cap: `dpiCap`, an optional `: Int`, then
    /// `=` that is not the first half of `==`.
    static let capWrite = #"dpiCap\s*(:\s*Int\s*)?=(?!=)"#

    static func writesTheCap(_ code: String) -> Bool {
        code.range(of: capWrite, options: .regularExpression) != nil
    }

    struct Write: Equatable, CustomStringConvertible {
        let file: String
        let line: Int
        let code: String
        let insideDebug: Bool
        var description: String { "\(file):\(line) \(code)" }
    }

    /// Every code line under `Sources/ResectaApp` that assigns the cap, with
    /// whether it lies inside `#if DEBUG` (or past the `#else` of `#if !DEBUG`).
    static func capWrites() throws -> [Write] {
        let sources = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
        let files = try #require(FileManager.default.enumerator(atPath: sources.path))
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        #expect(files.count > 100, "the source tree was not found")
        var writes: [Write] = []
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            var open: [(condition: String, pastElse: Bool)] = []
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("#if ") {
                    open.append((String(code.dropFirst(4)).trimmingCharacters(in: .whitespaces), false))
                    continue
                }
                if code.hasPrefix("#elseif"), !open.isEmpty { open[open.count - 1] = ("other", true); continue }
                if code == "#else", !open.isEmpty { open[open.count - 1].pastElse = true; continue }
                if code.hasPrefix("#endif"), !open.isEmpty { open.removeLast(); continue }
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                guard Self.writesTheCap(code) else { continue }
                let debug = open.contains {
                    ($0.condition == "DEBUG" && !$0.pastElse) || ($0.condition == "!DEBUG" && $0.pastElse)
                }
                writes.append(Write(file: file, line: number + 1, code: code, insideDebug: debug))
            }
        }
        return writes
    }

    @Test("The pattern matches a write, and not a comparison, a label or a read")
    func thePatternReadsWritesOnly() {
        let writes = Self.writesTheCap
        #expect(writes("var dpiCap: Int = defaultDPICap"))
        #expect(writes("self?.dpiCap = 150"))
        #expect(writes("ws.coordinator.dpiCap = cap"))
        #expect(!writes("if self.dpiCap == 150 {"))
        #expect(!writes("if dpiCap <= target {"))
        #expect(!writes("rasterize(page, dpiCap: cap)"))
        #expect(!writes("let entryCap = dpiCap"))
    }

    @Test("Three code lines write the run's quality cap, and the launch hook's is inside #if DEBUG")
    func theCapHasThreeWriters() throws {
        let writes = try Self.capWrites()
        #expect(writes.count == 3, "the cap's writers: \(writes)")
        let coordinator = writes.filter { $0.file.hasSuffix("PipelineCoordinator.swift") }
        #expect(coordinator.count == 2, "the declaration and the memory warning's lowering: \(coordinator)")
        #expect(coordinator.contains { $0.code.hasPrefix("var dpiCap") }, "the declaration: \(coordinator)")
        #expect(coordinator.contains { $0.code.contains("dpiCap = 150") }, "the memory warning's lowering: \(coordinator)")
        let hook = writes.filter { $0.file.hasSuffix("ResectaApp.swift") }
        #expect(hook.count == 1, "the launch hook's write: \(hook)")
        let insideDebug = hook.allSatisfy { $0.insideDebug }
        #expect(insideDebug, "the launch hook's write lies outside #if DEBUG: \(hook)")
    }
}
