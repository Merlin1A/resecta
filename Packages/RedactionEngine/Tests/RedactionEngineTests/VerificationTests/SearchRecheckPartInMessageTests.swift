import Testing
import Foundation
@testable import RedactionEngine

// A Search Re-check that needs review carries, beside its issue, the clauses
// of what it could not check (the row's part). The results screen shows the
// engine's own sentence for such a row and does not add the part again, so
// the sentence must already hold every clause the part lists. This table pins
// that rule in the engine: each mix of the four kinds of clause beside a
// match that remains, and the message holds each clause of the part.

@Suite("A Search Re-check that needs review names every could-not clause of its part in its message")
struct SearchRecheckPartInMessageTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        /// Page 2 does not open, so it could not be checked.
        let pageUnopened: Bool
        let coverageRan: Bool
        let coverageUnreadPages: [Int]
        let comparedNothing: [String]
        var testDescription: String { name }
    }

    static let scanNone = SearchRecheck.coverageNoMatchClause
    static let searchNone = SearchRecheck.coverageNoSearchMatchClause

    static let cases: [Case] = {
        let coverage: [(String, Bool, [Int], [String])] = [
            ("the coverage check ran clean", true, [], []),
            ("the coverage check did not run", false, [], []),
            ("the coverage check could not read page 2", true, [1], []),
            ("the coverage check compared nothing for the scan", true, [], [scanNone]),
            ("the coverage check compared nothing for the search", true, [], [searchNone]),
            ("the coverage check could not read page 2 and compared nothing for both", true, [1], [scanNone, searchNone]),
        ]
        var out: [Case] = []
        for unopened in [false, true] {
            for (name, ran, unread, nothing) in coverage {
                out.append(Case(name: (unopened ? "page 2 does not open; " : "every page opens; ") + name,
                                pageUnopened: unopened, coverageRan: ran, coverageUnreadPages: unread,
                                comparedNothing: nothing))
            }
        }
        return out
    }()

    @Test("The table holds twelve cases, one of them with nothing it could not check")
    func tableLength() {
        #expect(Self.cases.count == 12)
        #expect(Self.cases.filter { !$0.pageUnopened && $0.coverageRan && $0.coverageUnreadPages.isEmpty && $0.comparedNothing.isEmpty }.count == 1)
    }

    @Test("Each case", arguments: SearchRecheckPartInMessageTests.cases)
    func row(_ c: Case) throws {
        let observations = [
            RecheckObservation(pageIndex: 0, route: .textLayer, regexTimedOut: false,
                               counts: [0: UnfinishedRunTests.count(1)], textLayerRead: true),
            RecheckObservation(pageIndex: 1, route: c.pageUnopened ? .unopenable : .textLayer, regexTimedOut: false,
                               counts: c.pageUnopened ? [:] : [0: UnfinishedRunTests.count(0)],
                               textLayerRead: !c.pageUnopened),
        ]
        let o = SearchRecheck.fold(requests: [TestFixtures.textRequest("Delia")], observations: observations, pageCount: 2,
                                   coverageRan: c.coverageRan, coverageUnreadPages: c.coverageUnreadPages,
                                   coverageComparedNothingClauses: c.comparedNothing)
        guard case .attention(let message) = o.status else {
            Issue.record("\(c.name): Needs review expected, got \(o.status)")
            return
        }
        let clauses = o.partSentence.map { $0.components(separatedBy: "; ") } ?? []
        let expectsPart = c.pageUnopened || !c.coverageRan || !c.coverageUnreadPages.isEmpty || !c.comparedNothing.isEmpty
        #expect((o.partSentence != nil) == expectsPart, "\(c.name): part \(String(describing: o.partSentence))")
        for clause in clauses {
            #expect(message.contains(clause), "\(c.name): the message does not hold \"\(clause)\": \(message)")
        }
        for clause in c.comparedNothing {
            #expect(clauses.contains(clause), "\(c.name): the part does not list \"\(clause)\"")
        }
        print("RECHECKPART \(c.name) | message=\(message) | part=\(o.partSentence ?? "nil")")
    }
}
