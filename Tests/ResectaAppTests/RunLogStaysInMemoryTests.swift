import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

/// The run log keeps every closed search's query for the session, and the
/// answered set keeps the pages the user said to redact anyway. Both hold
/// text the user typed or found, in memory only: no type of theirs can be
/// encoded, and no log line names them.
@Suite("The run log and the answered set stay in memory")
struct RunLogStaysInMemoryTests {
    @Test("None of the run log's types, or the answered set's, can be encoded")
    func notEncodable() {
        let types: [(String, Any.Type)] = [
            ("SearchRunLogEntry", RedactionState.SearchRunLogEntry.self),
            ("RedactStop.Page", RedactStop.Page.self),
            ("RedactStopUnit", RedactStopUnit.self),
            ("AppliedSearchQuery", AppliedSearchQuery.self),
            ("AppliedSearchRecord", AppliedSearchRecord.self),
            ("SearchAccount", SearchAccount.self),
        ]
        for (name, type) in types {
            #expect(!(type is any Encodable.Type), "\(name) must not be encodable")
        }
    }

    @Test("No log line in the app or the engine names the run log, the answered set or their types")
    func noLogLineNamesThem() throws {
        let root = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let names = ["searchRunLog", "closedSearchRuns", "replacedSearchTokens", "liveAccountTokens",
                     "redactStopAnswered", "SearchRunLogEntry"]
        let opens = ["logger.", "Logger(", "os_log(", "NSLog(", "print("]
        var read = 0
        for folder in ["Sources", "Packages/RedactionEngine/Sources"] {
            let found = FileManager.default.enumerator(at: root.appendingPathComponent(folder),
                                                       includingPropertiesForKeys: nil)
            let files = (found?.allObjects ?? []).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            for file in files {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                read += 1
                var i = 0
                while i < lines.count {
                    guard opens.contains(where: { lines[i].contains($0) }) else { i += 1; continue }
                    // The call with its continuation lines, until its parentheses close.
                    var call = "", depth = 0, j = i
                    repeat {
                        call += lines[j] + "\n"
                        depth += lines[j].filter { $0 == "(" }.count - lines[j].filter { $0 == ")" }.count
                        j += 1
                    } while depth > 0 && j < lines.count && j < i + 12
                    for name in names {
                        #expect(!call.contains(name), "\(file.lastPathComponent):\(i + 1) logs \(name)")
                    }
                    i = j
                }
            }
        }
        #expect(read > 400, "the app's and the engine's sources were read (\(read) files)")
    }
}
