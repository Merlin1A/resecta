import Testing
import Foundation
@testable import ResectaApp

// The debug launch arguments that seed one state of the results screen
// each: every argument alone, all of them together, each malformed form,
// and an empty list. A malformed value seeds nothing and leaves the rest
// of the launch as it is.

@Suite("Debug seed launch arguments")
@MainActor
struct DebugSeedOptionsTests {

    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let arguments: [String]
        let expected: DebugSeedOptions
        var testDescription: String { name }
    }

    nonisolated private static func options(_ build: (inout DebugSeedOptions) -> Void) -> DebugSeedOptions {
        var options = DebugSeedOptions()
        build(&options)
        return options
    }

    nonisolated private static let report = "--seedVerifiedReport=secureAllPass"

    /// `nonisolated` for `@Test(arguments:)`, which the macro hoists into a
    /// nonisolated peer.
    nonisolated static let cases: [Case] = [
        Case(name: "an empty list seeds nothing", arguments: [], expected: DebugSeedOptions()),
        Case(name: "the report alone seeds nothing", arguments: ["--uitesting", report], expected: DebugSeedOptions()),
        Case(name: "hand boxes", arguments: [report, "--seedHandBoxes=3"],
             expected: options { $0.handBoxes = 3 }),
        Case(name: "form values", arguments: [report, "--seedFormValues=2"],
             expected: options { $0.formValues = 2 }),
        Case(name: "covered text", arguments: [report, "--seedCoveredText"],
             expected: options { $0.coveredText = true }),
        Case(name: "items left", arguments: [report, "--seedLeft=2/5"],
             expected: options { $0.left = .init(left: 2, total: 5) }),
        Case(name: "a typed search applied", arguments: [report, "--seedAppliedSearch=typed"],
             expected: options { $0.appliedSearch = .typed }),
        Case(name: "a scan applied", arguments: [report, "--seedAppliedSearch=scan"],
             expected: options { $0.appliedSearch = .scan }),
        Case(name: "boxes changed", arguments: [report, "--seedOutput", "--seedBoxesChanged"],
             expected: options { $0.boxesChanged = true }),
        Case(name: "verifying with none finished", arguments: [report, "--seedVerifying=0"],
             expected: options { $0.verifyingFinished = 0 }),
        Case(name: "verifying with two finished", arguments: [report, "--seedVerifying=2"],
             expected: options { $0.verifyingFinished = 2 }),
        Case(name: "burned boxes", arguments: [report, "--seedBurnedBoxes=19"],
             expected: options { $0.burnedBoxes = 19 }),
        Case(name: "the output's size", arguments: [report, "--seedOutput", "--seedOutputBytes=38200000"],
             expected: options { $0.outputBytes = 38_200_000 }),
        Case(name: "Secure pages", arguments: [report, "--seedSecurePages=140"],
             expected: options { $0.securePages = 140 }),
        Case(name: "unread pages, both counts", arguments: [report, "--seedUnread=12/38"],
             expected: options { $0.unread = .init(notInFull: 12, smallPictures: 38) }),
        Case(name: "unread pages, small pictures only", arguments: [report, "--seedUnread=0/1"],
             expected: options { $0.unread = .init(notInFull: 0, smallPictures: 1) }),
        Case(name: "all seven together",
             arguments: [report, "--seedOutput", "--seedHandBoxes=1", "--seedFormValues=4", "--seedCoveredText",
                         "--seedLeft=1/1", "--seedAppliedSearch=scan", "--seedBoxesChanged", "--seedVerifying=3"],
             expected: options {
                 $0.handBoxes = 1; $0.formValues = 4; $0.coveredText = true; $0.left = .init(left: 1, total: 1)
                 $0.appliedSearch = .scan; $0.boxesChanged = true; $0.verifyingFinished = 3
             }),
        Case(name: "hand boxes not a number", arguments: [report, "--seedHandBoxes=x"], expected: DebugSeedOptions()),
        Case(name: "hand boxes zero", arguments: [report, "--seedHandBoxes=0"], expected: DebugSeedOptions()),
        Case(name: "hand boxes negative", arguments: [report, "--seedHandBoxes=-1"], expected: DebugSeedOptions()),
        Case(name: "hand boxes empty", arguments: [report, "--seedHandBoxes="], expected: DebugSeedOptions()),
        Case(name: "form values not a number", arguments: [report, "--seedFormValues=two"], expected: DebugSeedOptions()),
        Case(name: "left without a total", arguments: [report, "--seedLeft=5"], expected: DebugSeedOptions()),
        Case(name: "left more than the total", arguments: [report, "--seedLeft=6/5"], expected: DebugSeedOptions()),
        Case(name: "left zero", arguments: [report, "--seedLeft=0/5"], expected: DebugSeedOptions()),
        Case(name: "left with three parts", arguments: [report, "--seedLeft=1/2/3"], expected: DebugSeedOptions()),
        Case(name: "an applied search of no known kind", arguments: [report, "--seedAppliedSearch=regex"],
             expected: DebugSeedOptions()),
        Case(name: "verifying not a number", arguments: [report, "--seedVerifying=x"], expected: DebugSeedOptions()),
        Case(name: "verifying negative", arguments: [report, "--seedVerifying=-1"], expected: DebugSeedOptions()),
        Case(name: "burned boxes zero", arguments: [report, "--seedBurnedBoxes=0"], expected: DebugSeedOptions()),
        Case(name: "the output's size not a number", arguments: [report, "--seedOutputBytes=big"],
             expected: DebugSeedOptions()),
        Case(name: "Secure pages zero", arguments: [report, "--seedSecurePages=0"], expected: DebugSeedOptions()),
        Case(name: "unread pages both zero", arguments: [report, "--seedUnread=0/0"], expected: DebugSeedOptions()),
        Case(name: "unread pages without a second count", arguments: [report, "--seedUnread=3"],
             expected: DebugSeedOptions()),
        Case(name: "a malformed seed leaves the others",
             arguments: [report, "--seedHandBoxes=x", "--seedFormValues=2", "--seedLeft=5", "--seedCoveredText"],
             expected: options { $0.formValues = 2; $0.coveredText = true }),
    ]

    @Test("The table's length is pinned")
    func tableLength() { #expect(Self.cases.count == 35) }

    @Test("Each argument seeds its one option; a malformed value seeds nothing", arguments: cases)
    func parsesEachSeedAndIgnoresMalformedOnes(_ c: Case) {
        #expect(DebugSeedOptions.parse(arguments: c.arguments) == c.expected)
    }

    // MARK: - The run stopped at its checks

    @Test("A run seeded part-way through its checks: the first rows finished, the next one running")
    func verifyingProgressPartWay() throws {
        let report = try #require(VerificationDebugFixtures.all["secureAllPass"])
        let progress = try #require(VerificationDebugFixtures.progress(for: "secureAllPass", finished: 2))
        #expect(progress.currentLayer == 3)
        #expect(progress.totalLayers == report.layers.count)
        #expect(progress.layerName == report.layers[2].name)
        #expect(progress.completedLayers.map(\.name) == report.layers.prefix(2).map(\.name))
    }

    @Test("A verifying seed that leaves no row running seeds no progress, and its stop names the count and the rows")
    func verifyingPastTheRowsStopsLoudly() throws {
        let rows = try #require(VerificationDebugFixtures.all["secureAllPass"]).layers.count
        #expect(VerificationDebugFixtures.progress(for: "secureAllPass", finished: rows - 1) != nil)
        #expect(VerificationDebugFixtures.progress(for: "secureAllPass", finished: rows) == nil)
        #expect(VerificationDebugFixtures.progress(for: "secureAllPass", finished: rows + 5) == nil)
        #expect(VerificationDebugFixtures.verifyingSeedFault(for: "secureAllPass", finished: rows)
                == "--seedVerifying=\(rows): the fixture secureAllPass has \(rows) rows, so no row is left running.")
    }

    // MARK: - Debug builds only

    /// The seeds' own names: the options type and its eleven arguments.
    /// (`--seedVerifiedReport` and `--seedOutput` are the hook's older
    /// arguments and are not pinned here.)
    nonisolated static let seedNames = [
        "DebugSeedOptions", "--seedHandBoxes", "--seedFormValues", "--seedCoveredText", "--seedLeft",
        "--seedAppliedSearch", "--seedBoxesChanged", "--seedVerifying", "--seedBurnedBoxes", "--seedOutputBytes",
        "--seedSecurePages", "--seedUnread",
    ]

    /// Every code line of the app's sources that names a seed lies inside
    /// `#if DEBUG`, so a release build carries none of them. Comment lines
    /// are skipped; a seed named in code outside `#if DEBUG` is red.
    @Test("The debug seeds are read only inside #if DEBUG")
    func seedsAreReadOnlyInsideDebug() throws {
        let sources = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
        let files = try #require(FileManager.default.enumerator(atPath: sources.path))
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
        #expect(files.count > 100, "the source tree was not found")
        var inside: Set<String> = []
        var outside: [String] = []
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            // One entry per open `#if`: whether its condition is DEBUG, !DEBUG
            // or another, and whether the line is past its `#else`.
            var open: [(condition: String, pastElse: Bool)] = []
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("#if ") {
                    open.append((String(code.dropFirst(4)).trimmingCharacters(in: .whitespaces), false))
                    continue
                }
                if code.hasPrefix("#elseif"), !open.isEmpty {
                    open[open.count - 1] = ("other", true)
                    continue
                }
                if code == "#else", !open.isEmpty {
                    open[open.count - 1].pastElse = true
                    continue
                }
                if code.hasPrefix("#endif"), !open.isEmpty {
                    open.removeLast()
                    continue
                }
                if code.hasPrefix("//") { continue }
                let debug = open.contains {
                    ($0.condition == "DEBUG" && !$0.pastElse) || ($0.condition == "!DEBUG" && $0.pastElse)
                }
                for name in Self.seedNames where code.contains(name) {
                    if debug { inside.insert(name) } else { outside.append("\(file):\(number + 1) \(name)") }
                }
            }
        }
        #expect(outside.isEmpty, "seeds named outside #if DEBUG: \(outside)")
        #expect(inside == Set(Self.seedNames), "seeds never read inside #if DEBUG: \(Set(Self.seedNames).subtracting(inside).sorted())")
    }
}
