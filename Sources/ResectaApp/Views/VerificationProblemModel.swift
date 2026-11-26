import RedactionEngine

// What a run found, by problem: one pure function over the report, the
// source annotations that cover text no box covers, and the original's
// filled form values. The rule it keeps: for a report that has checks, it
// returns at least one problem exactly when Share would ask before sending,
// judged with nothing acknowledged. It composes no sentence; whoever draws a
// problem owns its words. Every kind is decided from structured fields
// (status, the check's identity, pages, terms, the fragment flag, query
// lines, the could-not-verify flag), never from an engine sentence. A
// failed or needs-review check that also could not read part of its input
// has two entries, both with its position: one under its own kind, and that
// part under the checks that could not run in full or could not finish.

/// One problem of a run, with the checks behind it.
// nonisolated: a pure value, built and read off the main actor by tests.
nonisolated struct VerificationProblem: Equatable, Identifiable {

    /// Declared in the order `derive` returns them.
    enum Kind: CaseIterable, Comparable {
        /// A failed check: one problem per result.
        case failedCheck
        /// Boxed text a word check still reads: every such result in one problem.
        case boxedTextReadable
        /// Source annotations over text no box covers: no check behind it.
        case coveredTextInOriginal
        /// Part of a boxed word left beside its box, or a failed Search
        /// Re-check that names pages: one problem.
        case partOfBoxedText
        /// Searches that still match on the output: one problem.
        case searchesStillMatch
        /// Any other check that needs review: one problem per result.
        case otherNeedsReview
        /// The Detection Sweep's possible items: one problem per result.
        case possibleItems
        /// The original's filled form values, not carried: no check behind it.
        case formValuesNotCarried
        /// Checks that could not run in full on named pages, with the part a
        /// failed or needs-review check could not read on named pages: one
        /// problem.
        case couldNotRunOnPages
        /// A check that could not finish, with no pages, or the part a failed
        /// or needs-review check could not read, with no pages: one problem
        /// per check.
        case couldNotFinish
        /// Skipped checks: one problem.
        case skippedChecks
    }

    enum Mark: Equatable { case failed, needsReview, possibleItems, couldNotVerify }

    /// One check behind a problem.
    struct Check: Equatable {
        /// Its position in `report.layers`.
        let layerIndex: Int
        let outcome: VerificationOutcome
        /// 0-based, sorted, without duplicates: its own.
        let pages: [Int]
        /// Its own words, normalised; empty unless it is one of the three
        /// checks that look for the person's words.
        let words: [String]
        /// The engine's short sentence for it, as the engine wrote it.
        let sentence: String
    }

    let kind: Kind
    let mark: Mark
    /// The matching lines for searches that still match; the values for form
    /// values not carried; the checks for the two kinds that gather checks.
    /// Nil for every other kind.
    let count: Int?
    /// Normalised, without duplicates; empty except for the two kinds about
    /// boxed text.
    let words: [String]
    /// 0-based, sorted, without duplicates, all of them.
    let pages: [Int]
    /// In the report's order; empty for the two kinds with no check behind them.
    let checks: [Check]
    /// Unique within one result of `derive`: the kind's name, and for the
    /// kinds with one problem per result or per check, the check's position.
    let id: String
}

nonisolated enum VerificationProblemModel {

    /// The run's problems, in `VerificationProblem.Kind` order; within the kinds that
    /// have one problem per result or per check, in the report's order.
    /// `coveredPages` are 0-based (`ConcealingAnnotations.pages`);
    /// `formValueCount` is the original's filled form values
    /// (`DocumentState.sourceFilledFormFieldCount`). A report with no checks
    /// yields only the two kinds with no check behind them.
    static func derive(report: VerificationReport, coveredPages: [Int], formValueCount: Int) -> [VerificationProblem] {
        var failed: [VerificationProblem.Check] = []
        var readable: [VerificationProblem.Check] = []
        var partOfBoxed: [VerificationProblem.Check] = []
        var partOfBoxedFailed = false
        var matching: [VerificationProblem.Check] = []
        var matchingLines = 0
        var otherReview: [VerificationProblem.Check] = []
        var items: [VerificationProblem.Check] = []
        var onPages: [VerificationProblem.Check] = []
        var unfinished: [VerificationProblem.Check] = []
        var skipped: [VerificationProblem.Check] = []

        for (index, layer) in report.layers.enumerated() {
            let wordCheck = VerificationRowModel.quotesReviewTerms(layer.layer)
            let check = VerificationProblem.Check(
                layerIndex: index,
                outcome: VerificationRowModel.outcome(for: layer, perPageModes: report.perPageModes),
                pages: sortedPages(layer.pageReferences ?? []),
                words: wordCheck ? VerificationRowModel.normalizedTerms(layer.reviewTermTexts ?? []) : [],
                sentence: layer.shortDescription)
            if layer.status.isFail {
                // A failed Search Re-check that names pages missed coverage;
                // one with no pages failed in another way (every check can
                // fail with an unexpected error and no pages).
                if layer.layer == .searchRecheck, !check.pages.isEmpty {
                    partOfBoxed.append(check)
                    partOfBoxedFailed = true
                } else {
                    failed.append(check)
                }
            } else if layer.status.isAttention {
                let lines = VerificationRowModel.matchingQueryLines(layer)
                if wordCheck, layer.reviewIsFragment {
                    partOfBoxed.append(check)
                } else if wordCheck {
                    readable.append(check)
                } else if layer.layer == .searchRecheck, !lines.isEmpty {
                    matching.append(check)
                    matchingLines += lines.count
                } else {
                    otherReview.append(check)
                }
            } else if VerificationRowModel.hasItemsRemaining(layer) {
                items.append(check)
            } else if layer.status.isSkipped {
                skipped.append(check)
            } else if check.outcome == .couldNotVerify {
                if check.pages.isEmpty { unfinished.append(check) } else { onPages.append(check) }
            }
            // The one second entry: the part a failed or needs-review check
            // could not read, with that part's pages and sentence and no words.
            if layer.status.isFail || layer.status.isAttention, let part = layer.couldNotVerifyPart {
                let unread = VerificationProblem.Check(
                    layerIndex: index, outcome: .couldNotVerify, pages: sortedPages(layer.couldNotVerifyPartPages ?? []),
                    words: [], sentence: part)
                if unread.pages.isEmpty { unfinished.append(unread) } else { onPages.append(unread) }
            }
        }

        var problems: [VerificationProblem] = []
        problems += failed.map { one(.failedCheck, .failed, $0) }
        if !readable.isEmpty { problems.append(gathered(.boxedTextReadable, .needsReview, readable, words: true)) }
        if !coveredPages.isEmpty {
            problems.append(VerificationProblem(kind: .coveredTextInOriginal, mark: .needsReview, count: nil, words: [],
                                    pages: sortedPages(coveredPages), checks: [],
                                    id: name(.coveredTextInOriginal)))
        }
        if !partOfBoxed.isEmpty {
            problems.append(gathered(.partOfBoxedText, partOfBoxedFailed ? .failed : .needsReview, partOfBoxed,
                                     words: true))
        }
        if !matching.isEmpty {
            problems.append(gathered(.searchesStillMatch, .needsReview, matching, count: matchingLines))
        }
        problems += otherReview.map { one(.otherNeedsReview, .needsReview, $0) }
        problems += items.map { one(.possibleItems, .possibleItems, $0) }
        if formValueCount > 0 {
            problems.append(VerificationProblem(kind: .formValuesNotCarried, mark: .possibleItems, count: formValueCount,
                                    words: [], pages: [], checks: [], id: name(.formValuesNotCarried)))
        }
        if !onPages.isEmpty {
            problems.append(gathered(.couldNotRunOnPages, .couldNotVerify, onPages, count: onPages.count))
        }
        problems += unfinished.map { one(.couldNotFinish, .couldNotVerify, $0) }
        if !skipped.isEmpty {
            problems.append(gathered(.skippedChecks, .couldNotVerify, skipped, count: skipped.count))
        }
        return problems
    }

    /// A problem with one check behind it; its id carries the check's position.
    private static func one(_ kind: VerificationProblem.Kind, _ mark: VerificationProblem.Mark, _ check: VerificationProblem.Check) -> VerificationProblem {
        VerificationProblem(kind: kind, mark: mark, count: nil, words: [], pages: check.pages, checks: [check],
                id: "\(name(kind))-\(check.layerIndex)")
    }

    /// A problem that gathers checks: their pages united, and their words
    /// when the kind is about boxed text.
    private static func gathered(_ kind: VerificationProblem.Kind, _ mark: VerificationProblem.Mark, _ checks: [VerificationProblem.Check],
                                 count: Int? = nil, words: Bool = false) -> VerificationProblem {
        VerificationProblem(kind: kind, mark: mark, count: count,
                words: words ? VerificationRowModel.normalizedTerms(checks.flatMap(\.words)) : [],
                pages: sortedPages(checks.flatMap(\.pages)), checks: checks, id: name(kind))
    }

    private static func sortedPages(_ pages: [Int]) -> [Int] { Array(Set(pages)).sorted() }

    private static func name(_ kind: VerificationProblem.Kind) -> String { String(describing: kind) }
}
