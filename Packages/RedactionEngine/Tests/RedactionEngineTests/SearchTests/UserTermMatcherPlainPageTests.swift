import Testing
import Foundation
@testable import RedactionEngine

// The always-flag literal path on a page whose text is plain ASCII: the
// per-character normalization map is not built there (the search-normalized
// form of such a page is the page itself), so the plain case-insensitive
// search runs — and its needle must be the term's search-normalized literal,
// so a term typed with a ligature or a compatibility character reads its
// plain spelling on the page.

@Suite("Custom terms: literal terms on a plain-ASCII page", .tags(.search))
struct UserTermMatcherPlainPageTests {

    private static func matcher(_ terms: [String]) -> UserTermMatcher {
        UserTermMatcher.compile(
            alwaysFlag: terms.map { UserTerm(pattern: $0, isRegex: false) }, neverFlag: [])
    }

    private static let page = "he said hello to the ACME office on Monday"

    @Test("A literal typed with a ligature or a compatibility character matches its plain spelling",
          arguments: ["oﬃce", "ＡＣＭＥ"])
    func ligatureAndCompatibilityTermsReadTheirPlainSpelling(_ term: String) throws {
        #expect(Self.page.utf8.count == Self.page.unicodeScalars.count, "the fixture page is plain ASCII")
        let hits = Self.matcher([term]).alwaysFlagHits(in: Self.page).hits
        #expect(hits.count == 1, "\(term): one hit on its plain spelling; got \(hits.count)")
        let hit = try #require(hits.first)
        #expect(hit.pattern == term, "the hit reports the term as typed")
        let read = (Self.page as NSString).substring(with: hit.range)
        #expect(TextNormalizer.normalizeForSearch(read, caseSensitive: false)
                == TextNormalizer.normalizeForSearch(term, caseSensitive: false),
                "\(term) read \(read)")
    }

    @Test("A plain literal still reads each case-insensitive occurrence once, in page order")
    func plainLiteralReadsEveryOccurrenceOnce() {
        let hits = Self.matcher(["acme"]).alwaysFlagHits(in: "Acme acme ACME").hits
        #expect(hits.map(\.range.location) == [0, 5, 10])
        #expect(hits.allSatisfy { $0.range.length == 4 && $0.pattern == "acme" })
    }
}
