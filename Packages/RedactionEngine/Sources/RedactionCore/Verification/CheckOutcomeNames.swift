import Foundation

// The names a check reports in: what one answer is about, how the check
// ended on it, and why a unit has no answer. A check that uses them can
// list, for every unit it was given, that unit and its outcome kind. The
// evidence behind a completed unit is the check's own value, built in the
// check's own file; nothing here defines one.

/// What one answer is about.
package enum CheckUnit: Hashable, Sendable {
    case document
    /// A page, 0-based.
    case page(Int)
    /// A box: its page (0-based) and its position in the run's plan for that
    /// page.
    case box(page: Int, planIndex: Int)
    /// A region the producer painted on its own, outside its page's plan:
    /// its page (0-based) and its id.
    case region(page: Int, id: UUID)
}

/// The rule by which a check could not judge a unit. Each check declares the
/// rule names it uses as static constants on this type, in its own file.
package struct CheckRule: Hashable, Sendable {
    package let name: String

    package init(_ name: String) {
        self.name = name
    }
}

/// Why a unit has no answer.
package enum FaultName: Hashable, Sendable, CaseIterable {
    /// The run has no record at all; its unit is the document.
    case noRecord
    /// The run's plan holds a unit the check's result does not mention.
    case noResult
    /// The input could not be read for this check.
    case unreadableInput
    /// The check examined fewer or more parts of the unit than it expected.
    case evidenceShort
    /// The input read is not the one the record names.
    case wrongSubject
}

/// How a check ended on one unit.
package enum OutcomeKind: Hashable, Sendable {
    case completed
    case issue
    /// The check read the unit and could not judge it, by the named rule.
    case inconclusive(CheckRule)
    case fault(FaultName)
}

/// The class of today's result row an outcome reads as.
package enum RowClass: Hashable, Sendable, CaseIterable {
    case passed
    case needsReview
    case couldNotVerify
    case skipped
}

extension OutcomeKind {
    /// The row an outcome reads as. Every kind and every fault name has its
    /// own arm and there is no default, so a new name does not compile until
    /// it is given its row here, and no name reads Passed by omission.
    package var rowClass: RowClass {
        switch self {
        case .completed: .passed
        case .issue: .needsReview
        case .inconclusive: .couldNotVerify
        case .fault(.noRecord): .skipped
        case .fault(.noResult): .couldNotVerify
        case .fault(.unreadableInput): .couldNotVerify
        case .fault(.evidenceShort): .couldNotVerify
        case .fault(.wrongSubject): .couldNotVerify
        }
    }
}
