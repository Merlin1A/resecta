import Foundation
import RedactionEngine

// The stop's groups and its button. Within a reason, pages are grouped by
// the set of units they are unread for; a group that holds for every unit
// the runs hold carries no name. "Search These Pages" is offered only for
// recognition off, and re-runs at once every typed text of the group that
// can share one run.

extension RedactStop {

    struct Group: Hashable, Sendable {
        let reason: Reason
        /// The units the group holds for; nil when it holds for every unit, and so carries no name.
        let units: Set<RedactStopUnit>?
        let pages: [Int]
        /// For "not reached" only: how the runs of its units ended.
        var notReachedEnding: NotReachedEnding? = nil
    }

    /// How the units of a "not reached" group ended. A line names the cause
    /// only when every unit of the group ended the same way.
    enum NotReachedEnding: Hashable, Sendable {
        case stopped, atResultLimit
        /// The units ended in different ways; the line names no cause.
        case differs
    }

    /// The ending of a "not reached" group: each unit's own account's ending.
    static func notReachedEnding(of units: Set<RedactStopUnit>, runs: [Run]) -> NotReachedEnding? {
        var seen = Set<NotReachedEnding>()
        for unit in units {
            switch account(for: unit, in: runs)?.ending {
            case .stopped: seen.insert(.stopped)
            case .stoppedAtResultLimit: seen.insert(.atResultLimit)
            case .completed, nil: continue
            }
        }
        if seen.count > 1 { return .differs }
        return seen.first
    }

    /// A group's units in the order their runs first held them, for its name line.
    static func names(of group: Group, runs: [Run]) -> [RedactStopUnit] {
        units(of: runs).filter { group.units?.contains($0) ?? true }
    }

    /// The reasons in the order the stop shows them: the Search sheet's
    /// order, with "searched in part" before "not reached".
    static let reasonOrder: [Reason] = SearchAccount.LineReason.order.flatMap { reason -> [Reason] in
        reason == .notReached ? [.searchedInPart, .line(.notReached)] : [.line(reason)]
    }

    /// The groups to show, by reason in order; within a reason, the group
    /// with no name first, then by first page.
    static func groups(runs: [Run], answered: Set<Page>) -> [Group] {
        let named = pagesToName(runs: runs, answered: answered)
        let all = Set(units(of: runs))
        var groups: [Group] = []
        for reason in reasonOrder {
            var unitsByPage: [Int: Set<RedactStopUnit>] = [:]
            for (unit, pages) in named {
                for page in pages where page.reason == reason { unitsByPage[page.page, default: []].insert(unit) }
            }
            var pagesBySet: [Set<RedactStopUnit>: [Int]] = [:]
            for (page, units) in unitsByPage { pagesBySet[units, default: []].append(page) }
            let made = pagesBySet.map { units, pages in
                Group(reason: reason, units: units == all ? nil : units, pages: pages.sorted(),
                      notReachedEnding: reason == .line(.notReached) ? notReachedEnding(of: units, runs: runs) : nil)
            }
            groups += made.sorted { a, b in
                if (a.units == nil) != (b.units == nil) { return a.units == nil }
                return a.pages[0] < b.pages[0]
            }
        }
        return groups
    }

    /// A searched text by its kind: a typed text and a pattern with the same
    /// characters are two names.
    struct NamedText: Hashable, Sendable {
        let kind: RedactStopUnit.Kind
        let text: String
    }

    /// The texts whose names also say the options that differ: those with two
    /// units that stand in different groups. Units of one text that are
    /// always in the same groups need no options to tell them apart.
    static func textsNamedWithOptions(_ groups: [Group]) -> Set<NamedText> {
        var groupsByUnit: [RedactStopUnit: Set<Int>] = [:]
        for (index, group) in groups.enumerated() {
            for unit in group.units ?? [] { groupsByUnit[unit, default: []].insert(index) }
        }
        var placesByText: [NamedText: Set<Set<Int>>] = [:]
        for (unit, places) in groupsByUnit {
            placesByText[NamedText(kind: unit.kind, text: unit.text), default: []].insert(places)
        }
        return Set(placesByText.filter { $0.value.count > 1 }.keys)
    }

    /// The one run "Search These Pages" starts for a group, or nil when it
    /// offers none: only recognition off has a button. The largest set of
    /// typed texts that share options runs first, as one search where any
    /// term may match, with recognition on, whatever the user's all-terms
    /// setting; for each text, the unit that covers the group's others of
    /// that text. A Pattern or a Scan runs alone, after them.
    static func reRun(for group: Group, runs: [Run]) -> AppliedSearchQuery? {
        guard group.reason == .line(.recognitionOff) else { return nil }
        let held = group.units ?? Set(units(of: runs))
        let order = units(of: runs).filter { held.contains($0) }
        // For each text, the unit that covers the group's others of that text.
        var chosen: [RedactStopUnit] = []
        for unit in order where !chosen.contains(where: { $0.kind == unit.kind && $0.text == unit.text }) {
            let same = order.filter { $0.kind == unit.kind && $0.text == unit.text }
            chosen.append(same.first { candidate in same.allSatisfy { candidate.covers($0) } } ?? unit)
        }
        let texts = chosen.filter { $0.kind == .text }
        var sets: [[RedactStopUnit]] = []
        for unit in texts {
            if let index = sets.firstIndex(where: { $0[0].sameOptions(as: unit) }) { sets[index].append(unit) } else { sets.append([unit]) }
        }
        if let largest = sets.max(by: { $0.count < $1.count }) {
            let options = largest[0].searchOptions(base: latestQuery(of: largest[0], in: runs)?.options)
            let words = largest.map(\.text)
            return AppliedSearchQuery(kind: words.count == 1 ? .text(words[0]) : .multiTerm(words), options: options)
        }
        guard let alone = chosen.first, let latest = latestQuery(of: alone, in: runs) else { return nil }
        let options = alone.searchOptions(base: latest.options)
        switch alone.kind {
        case .pattern: return AppliedSearchQuery(kind: .regex(alone.text), options: options)
        case .scan: return AppliedSearchQuery(kind: latest.kind, options: options)
        case .text: return nil
        }
    }

    /// The latest run's query that holds the unit.
    static func latestQuery(of unit: RedactStopUnit, in runs: [Run]) -> AppliedSearchQuery? {
        runs.last { RedactStopUnit.units(of: $0.query).contains(unit) }?.query
    }
}

extension RedactStopUnit {

    func sameOptions(as other: RedactStopUnit) -> Bool {
        caseSensitive == other.caseSensitive && wholeWord == other.wholeWord && accents == other.accents
            && digitSeparators == other.digitSeparators && quotesAndDashes == other.quotesAndDashes
    }

    /// The options a re-run takes: this unit's five, recognition on, any term
    /// may match; the rest as the latest run had them.
    func searchOptions(base: SearchOptions?) -> SearchOptions {
        var options = base ?? SearchOptions()
        options.caseSensitive = caseSensitive
        options.wholeWord = wholeWord
        options.foldDiacritics = accents
        options.stripDigitSeparators = digitSeparators
        options.normalizeSmartPunctuation = quotesAndDashes
        options.includeOCR = true
        options.multiTermConjunction = false
        return options
    }
}
