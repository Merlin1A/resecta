import Foundation

// How one check's row says what it found, what it could not read, and what
// it noted, in one place. A check hands over, when it returns: its issue (if
// any), every could-not-verify condition it established (each with its own
// existing sentence and its own pages, in the check's fixed order), and its
// warnings. The row is then:
//
// - an issue and no condition: the issue alone, as before;
// - an issue and conditions: the issue, with its status and pages unchanged,
//   and beside it a display-only part — every condition's sentence, then
//   every warning, joined — with the conditions' pages;
// - no issue and conditions: every condition's sentence, then every warning,
//   joined, as a could-not-verify warning whose pages are every condition's
//   pages and no page that was read;
// - only warnings: the first warning alone, with its own pages, mark clear,
//   as before.
//
// Parts are joined by "; ", and a part in front of "; " loses a final full
// stop, so no ".;" can arise. No sentence is new: each part is a sentence
// its check already has.

/// One could-not-verify condition: its sentence and its own 0-based pages
/// (empty when the condition names no page).
struct UnverifiedCondition: Sendable, Equatable {
    let sentence: String
    let pages: [Int]
}

/// One warning a check established: its sentence and its own pages.
struct CheckWarning: Sendable, Equatable {
    let sentence: String
    let pages: [Int]?
}

/// A check's row as composed: the status, its pages, the could-not-verify
/// mark, and — only beside an issue that also has a could-not-verify part —
/// the part's sentence and pages, for display.
struct CheckRow: Sendable, Equatable {
    var status: VerificationStatus
    var pages: [Int]?
    var couldNotVerify: Bool
    var partSentence: String? = nil
    var partPages: [Int]? = nil
    /// Where the check stopped at an issue before reading everything; nil
    /// when it read everything.
    var stopped: CheckStop? = nil

    /// The same row, marked as stopped at `stop`.
    func stopped(at stop: CheckStop) -> CheckRow {
        var row = self
        row.stopped = stop
        return row
    }

    static let passed = CheckRow(status: .pass, pages: nil, couldNotVerify: false)
}

enum CheckRowComposition {

    /// The parts joined by "; ", each part in front of a separator without
    /// a final full stop; the last part as it is.
    static func join(_ parts: [String]) -> String {
        var out: [String] = []
        for (index, part) in parts.enumerated() {
            if index < parts.count - 1, part.hasSuffix(".") {
                out.append(String(part.dropLast()))
            } else {
                out.append(part)
            }
        }
        return out.joined(separator: "; ")
    }

    /// The row from what the check established. `issue` keeps its status
    /// and pages; nil when there was none. Nil when the check established
    /// nothing at all (the caller's PASS or its own clean outcome).
    static func compose(
        issue: (status: VerificationStatus, pages: [Int]?)?,
        conditions: [UnverifiedCondition],
        warnings: [CheckWarning]
    ) -> CheckRow? {
        let conditionPages = Array(Set(conditions.flatMap(\.pages))).sorted()
        let joined = join(conditions.map(\.sentence) + warnings.map(\.sentence))
        if let issue {
            guard !conditions.isEmpty else {
                return CheckRow(status: issue.status, pages: issue.pages, couldNotVerify: false)
            }
            return CheckRow(status: issue.status, pages: issue.pages, couldNotVerify: false,
                            partSentence: joined, partPages: conditionPages)
        }
        if !conditions.isEmpty {
            return CheckRow(status: .warn(joined), pages: conditionPages.isEmpty ? nil : conditionPages,
                            couldNotVerify: true)
        }
        if let first = warnings.first {
            return CheckRow(status: .warn(first.sentence), pages: first.pages, couldNotVerify: false)
        }
        return nil
    }
}
