import Testing
import Foundation
@testable import ResectaApp

// The DEBUG launch hooks that take a UI test to a screen: the failure
// screen from any pipeline error, one of the app's own toasts, and the
// fixtures behind the password sheet and the import notice. Their parsers
// are pure functions of the argument list, read here; an unknown name
// stops the app, so each of those is pinned as a stop. The last test reads
// the sources: every read of one of these hook names sits inside
// `#if DEBUG`, so a Release build compiles none of them.

@Suite("DEBUG launch hooks")
struct DebugLaunchHookTests {

    // MARK: - Failures

    nonisolated static let failureNames = [
        "importError.corrupt", "importError.passwordProtected", "importError.tooLarge",
        "importError.unsupportedFormat", "importError.invalidPageDimensions",
        "importError.activeContent",
        "detectionError.ocrUnavailable", "detectionError.timeout", "detectionError.visionError",
        "detectionError.detectionCorpusInvalid",
        "redactionError.insufficientMemory", "redactionError.unsupportedPageGeometry",
        "redactionError.boxCannotShowLength",
        "redactionError.bitmapCreationFailed", "redactionError.fillVerificationFailed",
        "redactionError.boxPlaceUnconfirmed",
        "redactionError.renderTimeout", "redactionError.pageTooLarge",
        "redactionError.reconstructionFailed", "redactionError.pageSidesNotAsRecorded",
        "verificationError.engineCrash",
        "exportError.diskFull", "exportError.writeFailed", "exportError.filePurged",
    ]

    @Test("Each of the 24 failure names parses to its own case, failing from the editor by default",
          arguments: failureNames)
    func failureNameParses(name: String) {
        #expect(ResectaApp.seedFailureErrors.count == 24)
        guard case .seed(let error, let phase, let report) =
                ResectaApp.seedFailureHook(for: ["--seedFailure=\(name)"]) else {
            Issue.record("\(name) did not parse to a failure")
            return
        }
        #expect(ResectaApp.seedFailureName(error) == name)
        #expect(phase == .editing)
        #expect(report == nil)
    }

    @Test("Each of the three phases parses; the verified phase takes the report named beside it",
          arguments: ["empty", "editing", "verified"])
    func phaseParses(phase: String) {
        var arguments = ["--seedFailure=redactionError.renderTimeout:\(phase)"]
        if phase == "verified" { arguments.append("--seedVerifiedReport=secureAllPass") }
        guard case .seed(_, let parsed, let report) = ResectaApp.seedFailureHook(for: arguments) else {
            Issue.record("phase \(phase) did not parse")
            return
        }
        #expect(parsed.rawValue == phase)
        #expect((report != nil) == (phase == "verified"))
    }

    @Test("The verified phase without a known report stops the app rather than pick one",
          arguments: [[String](), ["--seedVerifiedReport=noSuchReport"]])
    func verifiedPhaseNeedsAKnownReport(beside: [String]) {
        let hook = ResectaApp.seedFailureHook(
            for: ["--seedFailure=exportError.diskFull:verified"] + beside)
        guard case .stop = hook else {
            Issue.record("the verified phase seeded a failure without a known report")
            return
        }
    }

    // MARK: - Toasts

    // Each message name's parse is pinned with the message table
    // (`MessageCatalogTests`).

    @Test("The bare --showToast keeps today's toast")
    func bareShowToast() {
        #expect(ResectaApp.toastHook(for: ["--uitesting", "--showToast"]) == .bare)
        #expect(ResectaApp.toastHook(for: ["--uitesting"]) == .absent)
    }

    // MARK: - Unknown names stop

    @Test("An unknown failure name, an unknown phase and an unknown toast id each stop the app",
          arguments: [
              "--seedFailure=redactionError.renderTimeOut",
              "--seedFailure=redactionError.renderTimeout:results",
              "--showToast=selectionCap",
          ])
    func unknownNameStops(argument: String) {
        if argument.hasPrefix("--showToast=") {
            guard case .stop = ResectaApp.toastHook(for: [argument]) else {
                Issue.record("\(argument) did not stop")
                return
            }
        } else {
            guard case .stop = ResectaApp.seedFailureHook(for: [argument]) else {
                Issue.record("\(argument) did not stop")
                return
            }
        }
    }

    // MARK: - Every read inside #if DEBUG

    nonisolated static let hookNames = [
        "--showToast", "--seedFailure", "--forceDetectionDegrade", "--uitestOCRSkipPage",
        "--forceSnapshotOverlay", "--lockedDoc", "--annotatedFormDoc", "--turnedDoc", "--annotatedDoc",
        "--clearPageDoc", "--clearPageTurnedDoc",
        "--canvasReadOut", "--canvasReadOutProbe=",
    ]

    @Test("Every read of one of these hook names in the app's sources sits inside #if DEBUG")
    func everyHookReadIsInsideDebug() throws {
        let sources = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
        let files = try #require(FileManager.default.enumerator(atPath: sources.path))
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        #expect(files.count > 100)
        var found: [String: Int] = [:]
        var outside: [String] = []
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            // One frame per open `#if`: whether its branch now in force is DEBUG's.
            var frames: [(isDebug: Bool, inElse: Bool)] = []
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("#if ") {
                    frames.append((code == "#if DEBUG", false))
                } else if code.hasPrefix("#elseif"), !frames.isEmpty {
                    frames[frames.count - 1] = (false, true)
                } else if code.hasPrefix("#else"), !frames.isEmpty {
                    frames[frames.count - 1].inElse = true
                } else if code.hasPrefix("#endif"), !frames.isEmpty {
                    frames.removeLast()
                }
                let insideDebug = frames.contains { $0.isDebug && !$0.inElse }
                for name in Self.hookNames where line.contains("\"\(name)") {
                    found[name, default: 0] += 1
                    if !insideDebug { outside.append("\(file):\(index + 1) \(name)") }
                }
            }
        }
        #expect(Set(found.keys) == Set(Self.hookNames), "a hook name was never read: \(found)")
        #expect(outside.isEmpty, "hook reads outside #if DEBUG: \(outside)")
    }
}
