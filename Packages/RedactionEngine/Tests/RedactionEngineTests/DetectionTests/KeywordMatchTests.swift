import Testing
import Foundation
@testable import RedactionEngine

// The token-bound keyword predicate every Detection/ keyword site shares
// (KeywordMatch). The collision words are the ones the shipped keyword lists
// meet in ordinary text: a two- or three-letter keyword inside a longer word.

@Suite("KeywordMatch token boundary")
struct KeywordMatchTests {

    private func contains(_ keyword: String, _ window: String) -> Bool {
        KeywordMatch.containsToken(keyword, in: window)
    }

    @Test("a keyword inside a longer word is not a match", arguments: [
        ("lp", "help"), ("lp", "alpha"), ("lp", "scalpel"),
        ("tag", "vintage"), ("tag", "stage"), ("tag", "mortgage"), ("tag", "percentage"),
        ("plate", "template"), ("plate", "nameplate"),
        ("car", "card"), ("car", "carrier"),
        ("ein", "herein"), ("ein", "foreign"), ("ein", "reinvest"),
        ("mbi", "combined"), ("mbi", "ambiguous"),
        ("tel", "patel"), ("tel", "separately"),
        ("call", "callback"), ("call", "electronically"),
        ("ext", "next"), ("tin", "routing"), ("ach", "attached"),
        ("v.", "rev."),
    ])
    func keywordInsideLongerWordDoesNotMatch(keyword: String, host: String) {
        #expect(!contains(keyword, "before \(host) after"), "\(keyword) must not match inside \(host)")
        #expect(!contains(keyword, host))
    }

    @Test("the same keyword as a whole token matches at the window edges and between separators", arguments: [
        ("lp", "lp"), ("lp", "lp: abc123"), ("lp", "the lp abc123"), ("lp", "(lp)"), ("lp", "abc123 lp"),
        ("tag", "tag: xyz"), ("plate", "plate number"), ("car", "car"), ("ein", "ein:"), ("tel", "tel."),
        ("ext", "ext. 123"), ("v.", "smith v. jones"), ("tel", "tel\n555"),
    ])
    func wholeTokenMatches(keyword: String, window: String) {
        #expect(contains(keyword, window), "\(keyword) must match in '\(window)'")
    }

    @Test("a punctuation edge is free: ss# reads SS#123, mr# reads MR#7, n.a. and inc. and esq. keep working")
    func punctuationEdgeIsFree() {
        #expect(contains("ss#", "ss#123-45-6789"))
        #expect(contains("mr#", "mr#7788"))
        #expect(contains("n.a.", "bank n.a. account"))
        #expect(contains("inc.", "acme inc."))
        #expect(contains("esq.", "jane doe, esq."))
        #expect(contains("(b)(6)", "withheld under (b)(6) exemption"))
        #expect(contains("lot #", "lot #42"))
    }

    @Test("an alphanumeric edge next to a letter, a digit or a combining mark is not a boundary")
    func alphanumericNeighboursCloseTheToken() {
        #expect(!contains("ss#", "mass#123"))
        #expect(!contains("lp", "lp5"))
        #expect(!contains("lp", "9lp"))
        #expect(!contains("tag", "tag\u{0301}"))
        #expect(!contains("ein", "\u{10437}ein"))
        #expect(contains("ein", "\u{1F4DE}ein"))
    }

    @Test("multi-word keywords match as phrases; an inflected label is not the singular keyword")
    func phrasesMatch() {
        #expect(contains("social security number", "social security number: 123-45-6789"))
        #expect(contains("social security", "social security number"))
        #expect(!contains("social security", "antisocial security"))
        #expect(!contains("case no", "case nos. 1-3"))
    }

    @Test("an empty keyword never matches; a keyword longer than the window never matches")
    func degenerateInputs() {
        #expect(!contains("", "anything"))
        #expect(!contains("lp", ""))
        #expect(!contains("license plate", "plate"))
    }

    @Test("the range twin returns every token-bound occurrence, ascending, and none of the substring-only ones")
    func rangeTwinMatchesTheBoolean() {
        let window = "lp help lp5 (lp) alpha lp" as NSString
        let ranges = KeywordMatch.rangesOfToken("lp", in: window)
        #expect(ranges.map { $0.location } == [0, 13, 23])
        #expect(ranges.allSatisfy { $0.length == 2 })
        #expect(KeywordMatch.rangesOfToken("tag", in: "stage vintage" as NSString).isEmpty)
        for (keyword, text) in [("lp", "help"), ("tag", "stage"), ("tel", "patel"), ("tel", "tel: 555"), ("ss#", "ss#123")] {
            #expect(KeywordMatch.rangesOfToken(keyword, in: text as NSString).isEmpty
                    == !KeywordMatch.containsToken(keyword, in: text),
                    "the boolean must be exactly 'the range list is non-empty' for \(keyword) in \(text)")
        }
    }
}
