import Foundation
import Testing
@testable import RedactionEngine
@testable import ResectaApp

// The stop's groups, their names and its button. Pages are zero-based; the
// paper's pages 3, 5 and 9 are 2, 4 and 8 here.

@Suite("Redact stop: groups, names and Search These Pages")
struct RedactStopGroupsTests {

    typealias Facts = AccountOfWhatWasRead.Facts

    static let scanned: Set<Int> = [2, 4, 8]

    static func account(_ pages: [Facts], _ ending: SearchAccount.Ending = .completed, off: Set<Int> = []) -> SearchAccount {
        var account = SearchAccount(pageCount: pages.count)
        for (page, facts) in pages.enumerated() { account.record(facts, forPage: page) }
        for page in off { account.recordRecognitionOff(page: page) }
        account.end(ending)
        return account
    }

    /// Ten pages; the scanned ones not read, recognition off.
    static var unread: SearchAccount { account((0..<10).map { scanned.contains($0) ? [] : [.ownText] }, off: scanned) }
    /// Ten pages, all read: the scanned ones by recognition.
    static var read: SearchAccount { account((0..<10).map { scanned.contains($0) ? [.recognised] : [.ownText] }) }

    static func text(_ text: String, _ options: SearchOptions = SearchOptions()) -> AppliedSearchQuery {
        AppliedSearchQuery(kind: .text(text), options: options)
    }

    static func unit(_ kind: RedactStopUnit.Kind, _ text: String, _ options: SearchOptions = SearchOptions()) -> RedactStopUnit {
        RedactStopUnit(kind: kind, text: text, options: options)
    }

    @Test("K7-20: two Text searches with default options, recognition off on pages 3, 5 and 9: one group, no name; the button runs one terms search holding both, recognition on")
    func k720() throws {
        let runs: [RedactStop.Run] = [(Self.text("Delia"), Self.unread), (Self.text("Rourke"), Self.unread)]
        let groups = RedactStop.groups(runs: runs, answered: [])
        #expect(groups == [RedactStop.Group(reason: .line(.recognitionOff), units: nil, pages: [2, 4, 8])])
        let rerun = try #require(RedactStop.reRun(for: groups[0], runs: runs))
        #expect(rerun.kind == .multiTerm(["Delia", "Rourke"]))
        #expect(rerun.options.includeOCR && !rerun.options.multiTermConjunction)
        // With its matches applied, the next tap runs.
        #expect(!RedactStop.opens(runs: runs + [(rerun, Self.read)], answered: []))
    }

    @Test("K7-21 and K7-22: a Text search and a Pattern: the button re-runs the Text search; the next showing names the pattern by its text, and the button re-runs it")
    func k721() throws {
        let pattern = AppliedSearchQuery(kind: .regex("[0-9]{3}-[0-9]{4}"), options: SearchOptions())
        let runs: [RedactStop.Run] = [(Self.text("Delia"), Self.unread), (pattern, Self.unread)]
        let first = RedactStop.groups(runs: runs, answered: [])
        #expect(first.count == 1 && first[0].units == nil)
        let rerun = try #require(RedactStop.reRun(for: first[0], runs: runs))
        #expect(rerun.kind == .text("Delia"))
        let after = runs + [(rerun, Self.read)]
        let second = RedactStop.groups(runs: after, answered: [])
        #expect(second == [RedactStop.Group(reason: .line(.recognitionOff), units: [Self.unit(.pattern, "[0-9]{3}-[0-9]{4}")], pages: [2, 4, 8])])
        #expect(RedactStop.reRun(for: second[0], runs: after)?.kind == .regex("[0-9]{3}-[0-9]{4}"))
    }

    @Test("K7-23: two Text searches, one case-sensitive: the button re-runs one; the second showing names the one left")
    func k723() throws {
        let strict = SearchOptions(caseSensitive: true)
        let runs: [RedactStop.Run] = [(Self.text("Delia"), Self.unread), (Self.text("Rourke", strict), Self.unread)]
        let first = RedactStop.groups(runs: runs, answered: [])
        let rerun = try #require(RedactStop.reRun(for: first[0], runs: runs))
        #expect(rerun.kind == .text("Delia"))
        let second = RedactStop.groups(runs: runs + [(rerun, Self.read)], answered: [])
        #expect(second.map(\.units) == [[Self.unit(.text, "Rourke", strict)]])
    }

    @Test("K7-24: one text unread on pages 3, 5 and 9, another on page 5 only: page 5 with no name; pages 3 and 9 naming the first")
    func k724() {
        let onlyFive = Self.account((0..<10).map { $0 == 4 ? [] : [.ownText] }, off: [4])
        let runs: [RedactStop.Run] = [(Self.text("Delia"), Self.unread), (Self.text("Rourke"), onlyFive)]
        #expect(RedactStop.groups(runs: runs, answered: []) == [
            RedactStop.Group(reason: .line(.recognitionOff), units: nil, pages: [4]),
            RedactStop.Group(reason: .line(.recognitionOff), units: [Self.unit(.text, "Delia")], pages: [2, 8]),
        ])
    }

    @Test("K7-25 and K7-34: a name is returned whole; a pattern that reached the limit names its group by its text, the other two patterns unnamed")
    func namesWhole() {
        let long = String(repeating: "[A-Z]", count: 12)
        #expect(long.count == 60)
        let complete = Self.account([Facts](repeating: [.ownText], count: 6))
        let limited = Self.account([[.ownText], [.ownText], [], [], [], []], .stoppedAtResultLimit(page: 1))
        let runs: [RedactStop.Run] = [(AppliedSearchQuery(kind: .regex("a+"), options: SearchOptions()), complete),
                                      (AppliedSearchQuery(kind: .regex(long), options: SearchOptions()), limited),
                                      (AppliedSearchQuery(kind: .regex("b+"), options: SearchOptions()), complete)]
        let groups = RedactStop.groups(runs: runs, answered: [])
        #expect(groups.allSatisfy { $0.units == [Self.unit(.pattern, long)] })
        #expect(groups.map(\.reason) == [.searchedInPart, .line(.notReached)])
        #expect(groups.allSatisfy { RedactStop.reRun(for: $0, runs: runs) == nil }, "no button at the limit")
    }

    @Test("K7-27 and K7-35: the shared re-run reaches the limit on page 5: page 5 in part, the scanned pages after it not reached as a list, no button")
    func k727() {
        let pages = 12, scanned: Set<Int> = [2, 4, 8, 11]
        let first = Self.account((0..<pages).map { scanned.contains($0) ? [] : [.ownText] }, off: scanned)
        let rerun = Self.account((0..<pages).map { $0 > 4 ? [] : scanned.contains($0) ? [.recognised] : [.ownText] },
                                 .stoppedAtResultLimit(page: 4))
        let shared = AppliedSearchQuery(kind: .multiTerm(["Delia", "Rourke"]), options: SearchOptions())
        let runs: [RedactStop.Run] = [(Self.text("Delia"), first), (Self.text("Rourke"), first), (shared, rerun)]
        let groups = RedactStop.groups(runs: runs, answered: [])
        #expect(groups == [RedactStop.Group(reason: .searchedInPart, units: nil, pages: [4]),
                           RedactStop.Group(reason: .line(.notReached), units: nil, pages: [8, 11])])
        #expect(groups.allSatisfy { RedactStop.reRun(for: $0, runs: runs) == nil })
    }

    @Test("K7-28: the same text with Whole Word off and on: one group, no name; the button re-runs the Whole Word off unit")
    func k728() throws {
        let loose = SearchOptions(wholeWord: false), strict = SearchOptions(wholeWord: true)
        let runs: [RedactStop.Run] = [(Self.text("Hartwell", strict), Self.unread), (Self.text("Hartwell", loose), Self.unread)]
        let groups = RedactStop.groups(runs: runs, answered: [])
        #expect(groups.count == 1 && groups[0].units == nil)
        let rerun = try #require(RedactStop.reRun(for: groups[0], runs: runs))
        #expect(rerun.kind == .text("Hartwell") && rerun.options.wholeWord == false)
    }

    @Test("K7-29: the same text where neither covers the other: the button re-runs one; the next showing names the text with the options that differ")
    func k729() throws {
        let one = SearchOptions(caseSensitive: true, foldDiacritics: true)
        let two = SearchOptions(caseSensitive: false, foldDiacritics: false)
        let runs: [RedactStop.Run] = [(Self.text("Hartwell", one), Self.unread), (Self.text("Hartwell", two), Self.unread)]
        let first = RedactStop.groups(runs: runs, answered: [])
        let rerun = try #require(RedactStop.reRun(for: first[0], runs: runs))
        let second = RedactStop.groups(runs: runs + [(rerun, Self.read)], answered: [])
        #expect(second.count == 1 && second[0].units?.count == 1)
        // Named once a different unit of the same text stands in another group.
        let split = [RedactStop.Group(reason: .line(.recognitionOff), units: [Self.unit(.text, "Hartwell", one)], pages: [2]),
                     RedactStop.Group(reason: .line(.tooLarge), units: [Self.unit(.text, "Hartwell", two)], pages: [4])]
        #expect(RedactStop.textsNamedWithOptions(split) == ["Hartwell"])
        #expect(RedactStop.textsNamedWithOptions(second).isEmpty)
    }

    @Test("K7-32: the user's all-terms option on: the button's run is any term, and the user's setting is left as it was")
    func k732() throws {
        let allTerms = SearchOptions(multiTermConjunction: true)
        let runs: [RedactStop.Run] = [(Self.text("Delia", allTerms), Self.unread), (Self.text("Rourke", allTerms), Self.unread)]
        let groups = RedactStop.groups(runs: runs, answered: [])
        let rerun = try #require(RedactStop.reRun(for: groups[0], runs: runs))
        #expect(!rerun.options.multiTermConjunction)
        #expect(runs[0].query.options.multiTermConjunction)
    }
}
