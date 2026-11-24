import Foundation
import RedactionEngine

/// The stop at Redact: which pages to name, for which units, from every
/// search run of the document since it was opened and the pages already
/// answered. Pure. A unit's account at the stop is its runs, and every run
/// of a unit that covers it, oldest first, joined page by page; the Search
/// sheet's own lines describe one run and are never joined.
enum RedactStop {

    enum Reason: Hashable, Sendable {
        case line(SearchAccount.LineReason)
        /// The page the unit's latest run stopped on, still partly read after the join.
        case searchedInPart
    }

    /// A page and why it stops Redact. The answered set is kept in these:
    /// by page and reason, never by search.
    struct Page: Hashable, Sendable {
        let page: Int
        let reason: Reason
    }

    typealias Run = (query: AppliedSearchQuery, account: SearchAccount)

    /// Every unit the runs hold, in the order first run.
    static func units(of runs: [Run]) -> [RedactStopUnit] {
        var units: [RedactStopUnit] = []
        for run in runs {
            for unit in RedactStopUnit.units(of: run.query) where !units.contains(unit) { units.append(unit) }
        }
        return units
    }

    /// One unit's account at the stop. A text's or a pattern's is its own
    /// slice of each run; a Scan's is taken whole, since its timeouts are
    /// its terms'. Nil when no run holds the unit.
    static func account(for unit: RedactStopUnit, in runs: [Run]) -> SearchAccount? {
        let accounts = runs.compactMap { run -> SearchAccount? in
            guard RedactStopUnit.units(of: run.query).contains(where: { $0.covers(unit) }) else { return nil }
            return unit.kind == .scan ? run.account : run.account.forText(unit.text)
        }
        return SearchAccount.joined(accounts)
    }

    /// The pages of one account that stop Redact, each with every reason it is named for.
    static func unreadPages(of account: SearchAccount) -> Set<Page> {
        var pages = Set<Page>()
        for reason in SearchAccount.LineReason.order {
            for page in account.pages(for: reason) { pages.insert(Page(page: page, reason: .line(reason))) }
        }
        if let stop = account.stopPage { pages.insert(Page(page: stop, reason: .searchedInPart)) }
        return pages
    }

    /// Per unit, the pages to name: those that stop Redact and are not yet
    /// answered. A unit with none is left out; small pictures alone are never named.
    static func pagesToName(runs: [Run], answered: Set<Page>) -> [RedactStopUnit: Set<Page>] {
        var named: [RedactStopUnit: Set<Page>] = [:]
        for unit in units(of: runs) {
            guard let account = account(for: unit, in: runs) else { continue }
            let pages = unreadPages(of: account).subtracting(answered)
            if !pages.isEmpty { named[unit] = pages }
        }
        return named
    }

    /// Every page the stop names, by page and reason, across its units.
    static func namedPages(runs: [Run], answered: Set<Page>) -> Set<Page> {
        pagesToName(runs: runs, answered: answered).values.reduce(into: Set<Page>()) { $0.formUnion($1) }
    }

    /// True when the stop opens at the Redact tap.
    static func opens(runs: [Run], answered: Set<Page>) -> Bool {
        !pagesToName(runs: runs, answered: answered).isEmpty
    }
}
