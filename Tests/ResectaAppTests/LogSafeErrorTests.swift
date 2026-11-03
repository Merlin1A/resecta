import Testing
import Foundation
@testable import ResectaApp

// The persistence blobs log a failed decode, encode or write in two
// halves: `LogSafeError.publicSummary` as `.public`, the full description
// as `.private`. The unified log's privacy marking cannot be observed from
// a test, so these tests pin the public half: it names the error's type
// and never carries stored content. Each test first proves the full
// description DOES carry the marker, so a passing run is not vacuous.

@Suite("LogSafeError")
struct LogSafeErrorTests {

    private let marker = "SECRET-TERM-7781"

    @Test("A decode error's public summary names the type and case, not the stored key")
    func decodingErrorSummaryOmitsStoredContent() throws {
        // A saved-terms style payload whose user-typed key holds a value
        // of the wrong type: the coding path quotes the key.
        let json = Data(#"{"\#(marker)": "not a number"}"#.utf8)
        let error = try #require(throws: DecodingError.self) {
            try JSONDecoder().decode([String: Double].self, from: json)
        }
        #expect(String(describing: error).contains(marker))

        let summary = LogSafeError.publicSummary(error)
        #expect(!summary.contains(marker))
        #expect(summary.hasPrefix("Swift.DecodingError.typeMismatch"))
    }

    @Test("An invalid-value encode error's public summary omits the value")
    func encodingErrorSummaryOmitsValue() {
        let error = EncodingError.invalidValue(
            marker,
            EncodingError.Context(codingPath: [], debugDescription: "Cannot encode the value.")
        )
        #expect(String(describing: error).contains(marker))

        let summary = LogSafeError.publicSummary(error)
        #expect(!summary.contains(marker))
        #expect(summary.hasPrefix("Swift.EncodingError.invalidValue"))
    }

    @Test("An encode error raised by JSONEncoder omits the stored key from its public summary")
    func encoderErrorSummaryOmitsStoredKey() throws {
        let error = try #require(throws: EncodingError.self) {
            try JSONEncoder().encode([marker: Double.nan])
        }
        #expect(String(describing: error).contains(marker))

        let summary = LogSafeError.publicSummary(error)
        #expect(!summary.contains(marker))
        #expect(summary.hasPrefix("Swift.EncodingError.invalidValue"))
    }

    @Test("A file write error's public summary names the type, domain and code, not the path")
    func fileErrorSummaryOmitsPath() {
        let error = CocoaError(
            .fileWriteNoPermission,
            userInfo: [NSFilePathErrorKey: "/tmp/\(marker)/blob.json"]
        )
        #expect(String(describing: error).contains(marker))

        let summary = LogSafeError.publicSummary(error)
        #expect(!summary.contains(marker))
        #expect(summary.contains("CocoaError"))
        #expect(summary.contains("NSCocoaErrorDomain"))
        #expect(summary.contains("513"))
    }

    @Test("The persistence blobs log the error description private and only the summary public")
    func blobLogLinesKeepTheDescriptionPrivate() throws {
        for path in [
            "Sources/ResectaApp/State/FileJSONBlob.swift",
            "Sources/ResectaApp/State/UserDefaultsJSONBlob.swift",
        ] {
            let text = try String(
                contentsOf: repoRoot().appendingPathComponent(path),
                encoding: .utf8
            )
            #expect(
                !text.contains("String(describing: error), privacy: .public"),
                "\(path) still logs an error description as public"
            )
            #expect(
                text.components(separatedBy: "LogSafeError.publicSummary(error), privacy: .public").count - 1 == 2,
                "\(path) should log the public summary at both of its failure sites"
            )
            #expect(
                text.components(separatedBy: "String(describing: error), privacy: .private").count - 1 == 2,
                "\(path) should log the full description as private at both of its failure sites"
            )
        }
    }

    private func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }
}
