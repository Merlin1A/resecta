import Foundation
import RedactionEngine

// The stop's own words: its name line and its "not reached" and "searched in
// part" rows. The rows for the other reasons are the Search sheet's lines,
// given by its own words; until they are wired the stop's case is not returned.

extension BeforeYouRedactWords {

    static let stop = BeforeYouRedactWords(
        nameLine: { names, withOptions, allUnits in
            let line = StopWords.nameLine(names, withOptions: withOptions, allUnits: allUnits)
            return NotSearchedListContent.NameLine(shown: line, spoken: line)
        },
        row: { group, names in StopWords.row(group, names: names) ?? "" })
}

enum StopWords {

    // MARK: - The name line

    static func nameLine(_ names: [RedactStopUnit], withOptions: Set<RedactStop.NamedText>,
                         allUnits: [RedactStopUnit]) -> String {
        var phrases: [String] = []
        for kind in [RedactStopUnit.Kind.text, .pattern] {
            let ofKind = names.filter { $0.kind == kind }
            let plain = ofKind.filter { !withOptions.contains(RedactStop.NamedText(kind: kind, text: $0.text)) }
            var seen = Set<String>()
            let texts = plain.map(\.text).filter { seen.insert($0).inserted }
            if !texts.isEmpty { phrases.append(searchPhrase(kind, texts: texts)) }
            for unit in ofKind where withOptions.contains(RedactStop.NamedText(kind: kind, text: unit.text)) {
                let others = allUnits.filter { $0.kind == kind && $0.text == unit.text }
                phrases.append(searchPhrase(kind, texts: [unit.text]) + " with " + list(differing(unit, among: others)))
            }
        }
        if names.contains(where: { $0.kind == .scan }) { phrases.append("Scan") }
        let joined = phrases.enumerated().map { index, phrase in (index == 0 ? "For your " : "for your ") + phrase }
        return list(joined) + ":"
    }

    private static func searchPhrase(_ kind: RedactStopUnit.Kind, texts: [String]) -> String {
        let quoted = list(texts.map { "\u{201C}\($0)\u{201D}" })
        switch (kind, texts.count) {
        case (.pattern, 1): return "pattern search " + quoted
        case (.pattern, _): return "pattern searches " + quoted
        case (_, 1): return "search for " + quoted
        default: return "searches for " + quoted
        }
    }

    /// The options whose value differs among a text's units, in the Search
    /// sheet's chip order, each with this unit's own value.
    private static func differing(_ unit: RedactStopUnit, among others: [RedactStopUnit]) -> [String] {
        let options: [(String, (RedactStopUnit) -> Bool)] = [
            ("Case-sensitive", { $0.caseSensitive }), ("Whole word", { $0.wholeWord }),
            ("Digit separators", { $0.digitSeparators }), ("Quotes & dashes", { $0.quotesAndDashes }),
            ("Accents", { $0.accents }),
        ]
        return options.compactMap { name, value in
            Set(others.map(value)).count > 1 ? "\(name) \(value(unit) ? "on" : "off")" : nil
        }
    }

    /// Two: "a and b"; three or more: "a, b, and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }

    // MARK: - The stop's own rows

    /// The row for "not reached" and "searched in part"; nil for the reasons
    /// whose rows are the Search sheet's lines.
    static func row(_ group: RedactStop.Group, names: [RedactStopUnit]) -> String? {
        let scans = names.contains { $0.kind == .scan }
        let searches = names.contains { $0.kind != .scan }
        let oneBased = group.pages.map { $0 + 1 }
        // The strings table's page rule: a run of three or more as "3–9".
        let pageList = list(VerificationResultsView.pageRanges(group.pages.sorted()))
        let one = oneBased.count == 1
        switch group.reason {
        case .searchedInPart:
            guard let page = oneBased.first else { return nil }
            let verb = scans && searches ? "searched and scanned" : scans ? "scanned" : "searched"
            return "Page \(page) was \(verb) in part."
        case .line(.notReached):
            let verb = scans && searches ? "searched and scanned" : scans ? "scanned" : "searched"
            let subject = scans && searches ? "the search and the Scan" : scans ? "the Scan" : "the search"
            let they = scans && searches ? "they" : "it"
            let limit = scans && searches ? "their limit" : "its limit"
            let cause: String
            switch group.notReachedEnding {
            case .stopped?: cause = "\(subject) stopped before \(they) reached"
            case .atResultLimit?: cause = "\(subject) reached \(limit) of 1,000 results before \(they) reached"
            case .differs?, nil: cause = "\(subject) ended before \(they) reached"
            }
            return one
                ? "Page \(pageList) was not \(verb), because \(cause) it."
                : "Pages \(pageList) were not \(verb), because \(cause) them."
        case .line:
            return nil
        }
    }
}
