import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The Case-sensitive option governs Regex mode. The pattern compiles
// case-insensitively when the session's option is off, so "smith" matches
// "Smith"; with it on, the pattern matches as written. A validation-only
// caller compiles with no options, as before, and the sentinel probe's
// verdict does not move with the option.

@Suite("Regex case option", .tags(.search))
struct RegexCaseOptionTests {

    private func regexHits(_ pattern: String, caseSensitive: Bool, on text: String) async throws -> [SearchResult] {
        let doc = try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: text)))
        let stream = DocumentSearcher().search(
            SendablePDFDocument(doc),
            mode: .regex(pattern, options: SearchOptions(caseSensitive: caseSensitive)),
            progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        return results
    }

    @Test("With Case-sensitive off a lowercase pattern matches a capitalised word; with it on it does not")
    func caseOptionGovernsRegex() async throws {
        let page = "Agent Smith signed; SMITH countersigned."
        let off = try await regexHits("smith", caseSensitive: false, on: page)
        #expect(off.count == 2)
        #expect(off.map(\.matchedText).sorted() == ["SMITH", "Smith"])
        let on = try await regexHits("smith", caseSensitive: true, on: page)
        #expect(on.isEmpty)
        let exact = try await regexHits("Smith", caseSensitive: true, on: page)
        #expect(exact.count == 1)
        #expect(exact.first?.matchedText == "Smith")
    }

    @Test("The compile options follow the session's option; anchors match per line in every compile")
    func compileOptionsFollowTheSession() throws {
        #expect(DocumentSearcher.regexCompileOptions(nil) == [.anchorsMatchLines])
        #expect(DocumentSearcher.regexCompileOptions(SearchOptions(caseSensitive: true)) == [.anchorsMatchLines])
        #expect(DocumentSearcher.regexCompileOptions(SearchOptions(caseSensitive: false))
                == [.anchorsMatchLines, .caseInsensitive])
        #expect(try DocumentSearcher.validateRegexPatternWithError("smith").options == [.anchorsMatchLines])
        #expect(try DocumentSearcher.validateRegexPatternWithError(
            "smith", options: SearchOptions(caseSensitive: false)).options == [.anchorsMatchLines, .caseInsensitive])
        #expect(DocumentSearcher.validateRegexPattern("smith")?.options == [.anchorsMatchLines])
    }

    @Test("The sentinel's verdict is the same under both settings")
    func sentinelVerdictDoesNotMove() async {
        let benign = "[0-9]{3}-[0-9]{2}-[0-9]{4}"
        #expect(await RegexSentinelCheck.validate(benign) == true)
        #expect(await RegexSentinelCheck.validate(benign, options: SearchOptions(caseSensitive: false)) == true)
        #expect(await RegexSentinelCheck.validate(benign, options: SearchOptions(caseSensitive: true)) == true)
        let pathological = "(a+)+b"
        #expect(await RegexSentinelCheck.validate(pathological) == false)
        #expect(await RegexSentinelCheck.validate(pathological, options: SearchOptions(caseSensitive: false)) == false)
    }
}
