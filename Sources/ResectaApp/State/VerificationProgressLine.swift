import Foundation
import RedactionEngine

/// The running checks' figure and line, as one pure function of what the
/// engine has announced. The figure is the number of results published so
/// far. The line reads "Checking…" unless one check, announced on its own
/// (not as the first of the group that runs at once), has run for half a
/// second; then it names that check by its row's title. The Search
/// Re-check is named only on a run that applied a typed search: on any
/// other run it has nothing to re-run, and the long pass belongs to the
/// Detection Sweep.
nonisolated struct VerificationProgressLine: Equatable {
    enum Line: Equatable {
        case checking
        case naming(VerificationLayer)
    }

    /// Results published so far.
    let finished: Int
    /// Checks in the run; 0 before the first announcement, when the ring
    /// draws its track and no figure.
    let total: Int
    let line: Line

    /// How long a check announced on its own runs before the line names it.
    static let nameHold: TimeInterval = 0.5

    static func make(finished: Int, total: Int, running: VerificationLayer?, runningOpensGroup: Bool,
                     secondsRunning: TimeInterval, typedSearchApplied: Bool) -> VerificationProgressLine {
        guard let running, !runningOpensGroup, secondsRunning >= nameHold,
              running != .searchRecheck || typedSearchApplied else {
            return .init(finished: finished, total: total, line: .checking)
        }
        return .init(finished: finished, total: total, line: .naming(running))
    }

    /// The drawn line.
    static func text(_ line: Line) -> String {
        switch line {
        case .checking: "Checking\u{2026}"
        case .naming(let layer): "Checking \(VerificationRowModel.title(for: layer))\u{2026}"
        }
    }

    /// The line as VoiceOver reads it: the same words, ending in a period.
    static func spoken(_ line: Line) -> String {
        switch line {
        case .checking: "Checking."
        case .naming(let layer): "Checking \(VerificationRowModel.title(for: layer))."
        }
    }

    /// The second line on a long run, from this long after the checks began.
    static let longRunDelay: TimeInterval = 15
    static let longRunLine = "Long PDFs take longer. Keep Resecta open until the checks finish."

    /// The spoken reminder when nothing has changed for this long.
    static let stillCheckingDelay: TimeInterval = 30
    static func stillChecking(finished: Int, total: Int) -> String {
        "Still checking. \(finished) of \(total) checks completed."
    }
}
