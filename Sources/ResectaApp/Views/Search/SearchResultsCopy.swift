import SwiftUI
import RedactionEngine

// The results list's copy catalogs: the saturation banner's action
// labels and the per-mode empty-state copy (headline, description,
// symbol and chip rows), each a pure table a test can pin without
// instantiating the view. Mechanism-description discipline throughout —
// every line describes what the engine did, never a verdict on the
// document.

// MARK: - Saturation Banner Strings
//
// Mechanism-description action labels — describe the affordance the
// user invokes, not an outcome promise.
// Kept off `Legal.xcstrings` because they are
// operational copy, not legal/marketing copy. Pinned by
// `SaturationBannerTests`.

enum SaturationBannerCopy {
    static let headline = "\u{2265} 10,000 matches \u{2014} refine query"
    static let addWholeWord = "Add whole-word filter"
    static let toggleCaseSensitive = "Toggle case-sensitive"
    static let scopeToCurrentPage = "Scope to current page"
}

// MARK: - Empty State Strings
//
// Mode-specific actionable copy. Mechanism-description
// discipline. Outcome promises (e.g., "no PII found", "all clear",
// "your document is clean", "nothing to redact") are forbidden.
// Every branch describes the engine's
// mechanism, not a verdict on the document. Pinned by
// `EmptyStateTests`.

enum SearchEmptyStateCopy {

    /// Discriminator for the per-mode empty-state branches. Drives
    /// headline / description / chip-row visibility from a single
    /// pure function so tests can pin the per-context copy without
    /// instantiating the SwiftUI view.
    enum EmptyContext: Equatable {
        case textPreSearch
        case textNotRun
        case textNoMatch
        case regexPreSearch
        case regexNotRun
        case regexNoMatch
        case multiTermPreSearchNoRecents
        case multiTermPreSearchWithRecents
        case multiTermNotRun
        case multiTermNoMatch
        case multiTermNoMatchConjunction
        case piiScanPreScan
        case piiScanStartFailed
        case piiScanPostScanZero(detectorCount: Int)
        case piiScanCancelled(pagesScanned: Int, pageCount: Int)
    }

    /// Pure-function context discriminator. Tested directly by
    /// `EmptyStateTests`; the view-side helper just forwards.
    static func context(
        mode: SearchModeType,
        queryText: String,
        multiTermTerms: [String],
        recentMultiTermSets: [[String]],
        multiTermConjunction: Bool,
        currentSearchPage: Int,
        totalPages: Int,
        totalCount: Int,
        enabledPIICategoryCount: Int,
        hasCompletedRun: Bool,
        scanStartFailed: Bool
    ) -> EmptyContext {
        switch mode {
        case .text:
            if queryText.isEmpty { return .textPreSearch }
            // A carried query the mode switch deliberately did not
            // re-run must not read as a no-match verdict.
            return hasCompletedRun ? .textNoMatch : .textNotRun
        case .regex:
            if queryText.isEmpty { return .regexPreSearch }
            return hasCompletedRun ? .regexNoMatch : .regexNotRun
        case .multiTerm:
            if multiTermTerms.isEmpty {
                return recentMultiTermSets.isEmpty
                    ? .multiTermPreSearchNoRecents
                    : .multiTermPreSearchWithRecents
            }
            if !hasCompletedRun { return .multiTermNotRun }
            // Under conjunction, per-term occurrences may exist even
            // when no page satisfies every term — the copy must not
            // claim "no occurrences … for any of the terms".
            return multiTermConjunction
                ? .multiTermNoMatchConjunction
                : .multiTermNoMatch
        case .piiScan:
            // A failed start outranks the pre-scan default: the toast
            // that announced it expires, and "Not scanned yet" would
            // erase the failure from the surface.
            if scanStartFailed && totalCount == 0 {
                return .piiScanStartFailed
            }
            // Post-scan zero-result requires `currentSearchPage > 0`
            // (the scan ran), `totalCount == 0` (no matches), AND
            // `hasCompletedRun` (the run finished). A cancelled run
            // leaves `currentSearchPage` at the cancelled position with
            // `hasCompletedRun` false — that state must never render
            // the "Scan complete" clean bill on a partially-scanned
            // document: it gets its own cancelled render.
            if currentSearchPage > 0 && totalCount == 0 {
                return hasCompletedRun
                    ? .piiScanPostScanZero(detectorCount: enabledPIICategoryCount)
                    : .piiScanCancelled(
                        pagesScanned: currentSearchPage, pageCount: totalPages)
            }
            return .piiScanPreScan
        }
    }

    /// Headline per branch.
    static func headline(for context: EmptyContext) -> String {
        switch context {
        case .textPreSearch:
            return "Text search"
        case .textNotRun, .regexNotRun, .multiTermNotRun:
            return "Not run yet"
        case .textNoMatch:
            return "No matches"
        case .regexPreSearch:
            return "Regex search"
        case .regexNoMatch:
            return "No matches"
        case .multiTermPreSearchNoRecents:
            return "Multi-term search"
        case .multiTermPreSearchWithRecents:
            return "Multi-term search"
        case .multiTermNoMatch, .multiTermNoMatchConjunction:
            return "No matches"
        case .piiScanStartFailed:
            return "Scan didn't start"
        case .piiScanPreScan:
            // Pre-scan headline must not read as a verdict.
            // "Not scanned yet" states the actual condition; the
            // description below carries the role sentence.
            return "Not scanned yet"
        case .piiScanPostScanZero:
            // Names what the run produced, not an
            // affirmation: matches the canvas banner's own voice
            // ("…flagged no items"). A checkmark-style "Scan complete"
            // read as a clean bill; this names the produced count
            // instead (zero, stated plainly).
            return "No items flagged"
        case .piiScanCancelled:
            return "Scan cancelled"
        }
    }

    static func headlineSymbol(for context: EmptyContext) -> String {
        switch context {
        case .textPreSearch, .multiTermPreSearchNoRecents,
             .multiTermPreSearchWithRecents, .regexPreSearch,
             .textNotRun, .regexNotRun, .multiTermNotRun:
            return "magnifyingglass"
        // The post-scan-zero branch shares the neutral
        // no-match glyph with its Search-side siblings: a checkmark
        // read as an affirmative clean bill, which this state must
        // never imply.
        case .textNoMatch, .regexNoMatch, .multiTermNoMatch,
             .multiTermNoMatchConjunction, .piiScanPostScanZero:
            return "doc.text.magnifyingglass"
        // The Scan side dropped the shield family: `doc.viewfinder`
        // matches the toolbar Scan entry's own glyph, and the outcome
        // states use the plain severity symbols. (The verification
        // surfaces keep their shields — different vocabulary.)
        case .piiScanPreScan:
            return "doc.viewfinder"
        case .piiScanStartFailed:
            return "exclamationmark.triangle"
        case .piiScanCancelled:
            return "stop.circle"
        }
    }

    /// Description per branch. Mechanism-description copy — describes
    /// the engine path or the affordance, not a verdict.
    static func description(for context: EmptyContext) -> String {
        switch context {
        case .textPreSearch:
            return "Type a word, phrase, or pattern to match against the document text."
        case .textNotRun:
            return "This query hasn't been run in this mode yet. Press Return to run it, or edit it to search as you type."
        case .textNoMatch:
            return "No occurrences in the document for the active query. Try a broader term or change the search options."
        case .regexPreSearch:
            return "Enter a regular expression to match against the document text. Example: \\d{3}-\\d{2}-\\d{4} for SSN-style sequences."
        case .regexNotRun:
            return "This pattern hasn't been run in this mode yet. Press Return to run it, or edit it to search as you type."
        case .regexNoMatch:
            return "The active pattern produced no matches. Adjust the pattern or the search options."
        case .multiTermPreSearchNoRecents:
            return "Type a term above and press Return to add it. Each term searches the document independently."
        case .multiTermPreSearchWithRecents:
            return "Type a term above and press Return to add it, or recall a recent term set below."
        case .multiTermNotRun:
            return "These terms haven't been run in this mode yet. Press Return in the term field to run them."
        case .multiTermNoMatch:
            return "No occurrences in the document for any of the active terms."
        case .multiTermNoMatchConjunction:
            return "No page contains all of the active terms together. Individual terms may still occur on their own — turn off \"All terms must match\" to see per-term occurrences."
        case .piiScanStartFailed:
            // Names no control: the retry is the state's own inline
            // "Scan Again" action, rendered beside this copy.
            return "The last scan couldn't start because the document wasn't ready."
        case .piiScanPreScan:
            // The vestigial pre-scan state (entry auto-run makes it
            // unreachable in practice; the case stays for
            // discriminator completeness) keeps the role sentence as
            // residue — if a failure edge ever surfaces it, the copy
            // stays true and names no retired control.
            return piiScanRoleSentence
        case .piiScanPostScanZero(let detectorCount):
            // The threshold-count sentence stays first,
            // verbatim, then the calibration line and the recourse
            // pointer (both pinned builders below) so a zero result
            // never reads as an unqualified clean bill.
            let suffix = detectorCount == 1 ? "" : "s"
            let base = "\(detectorCount) detector\(suffix) matched 0 candidates above threshold."
            return "\(base)\n\n\(piiScanZeroCalibrationLine)\n\n\(piiScanZeroRecourseLine)"
        case .piiScanCancelled(let pagesScanned, let pageCount):
            // Mechanism description, no verdict: a partial run must
            // never read as a clean bill. Names the unscanned remainder
            // explicitly; the chips-row ↻ is the re-run affordance.
            let suffix = pageCount == 1 ? "" : "s"
            return "Detection stopped after \(pagesScanned) of \(pageCount) page\(suffix) — the remaining pages weren't scanned."
        }
    }

    // MARK: Post-scan-zero recourse
    //
    // Fence-safe: copy + pointers to controls that already ship.
    // No near-threshold candidate display, no new detection surface,
    // no new setting. Composed into `description(for:
    // .piiScanPostScanZero)` above; pinned separately by
    // `EmptyStateTests` so the wording stays testable without
    // decoding the composed string.

    /// Calibration line: a zero result is a threshold
    /// outcome, not a verdict on document content. Mechanism
    /// description only — no outcome promise about what the document
    /// does or doesn't contain.
    static let piiScanZeroCalibrationLine =
        "A zero result means nothing on the scanned pages cleared the current threshold for those detectors \u{2014} it is not a statement about what the document contains."

    /// Pointer line naming the three existing recourse
    /// controls by their shipped labels/glyphs: the chips-row re-run
    /// affordance (\u{21bb}, accessibility label "Scan document for
    /// PII", `SearchToolbarSection.rescanButton`), the Search
    /// interface's literal-match modes (`SearchInterface.search`
    /// displayName "Search"), and the Settings "Detection Sensitivity"
    /// preset picker (`SettingsView`). Names no control beyond what
    /// already ships.
    static let piiScanZeroRecourseLine =
        "To look further: re-run with different detectors (\u{21bb}), search for specific terms in Search, or change the Detection Sensitivity preset in Settings."

    // MARK: Search-interface role line

    /// One-line role sentence for the Search interface, rendered above
    /// the per-mode caption on the pre-search empty states (the Scan
    /// interface's counterpart is folded into the `piiScanPreScan`
    /// description above). States the literal-match contract: matches
    /// follow the query and its options; nothing is inferred beyond
    /// them. Pinned by `EmptyStateTests`.
    static let searchRoleSubtitle =
        "Matches exactly what you ask for \u{2014} nothing more, nothing inferred."

    /// True for the Search-side pre-search contexts that mount the
    /// role line. Pure predicate consumed by the empty state and
    /// pinned by `EmptyStateTests`. No-match branches stay
    /// role-line-free (they carry result feedback), and the Scan-side
    /// branches have their own role copy.
    static func showsSearchRoleSubtitle(for context: EmptyContext) -> Bool {
        switch context {
        case .textPreSearch, .regexPreSearch,
             .multiTermPreSearchNoRecents, .multiTermPreSearchWithRecents:
            return true
        case .textNoMatch, .regexNoMatch, .multiTermNoMatch,
             .multiTermNoMatchConjunction,
             .textNotRun, .regexNotRun, .multiTermNotRun,
             .piiScanPreScan, .piiScanStartFailed, .piiScanPostScanZero,
             .piiScanCancelled:
            return false
        }
    }

    // MARK: Scan role sentence + in-flight state

    /// The Scan interface's role sentence. Primary home: the
    /// in-flight state's description, read exactly while the user
    /// waits on an auto-run; the vestigial `piiScanPreScan`
    /// description returns the same constant as residue. States the
    /// mechanism on its own terms: text detectors, on-device,
    /// whole-document default, text content only — plus the
    /// rationale-visibility half of the role. Wording constraints
    /// pinned by `PIIScanRoleCopyTests`.
    /// (The former "Detectors active: N." secondary line retired with
    /// the run button: the selected chips already show the active set,
    /// and the zero-result copy carries the count.)
    static let piiScanRoleSentence =
        "Runs the on-device PII text detectors across the whole document \u{2014} text content only. Results show why each item was flagged."

    /// Headline for the Scan-run in-flight surface.
    static let scanInFlightHeadline = "Scanning…"

    // MARK: Multi-term recall chips

    static let recentSearchesHeader = "Recent searches"

    /// Chip label joins terms with `\u{00A0}+\u{00A0}` (non-breaking
    /// spaces around the plus sign) so the chip width doesn't break
    /// awkwardly mid-set at smaller widths.
    static func recallChipLabel(terms: [String]) -> String {
        terms.joined(separator: "\u{00A0}+\u{00A0}")
    }

    /// Spelled-out accessibility label for the recall chip; uses
    /// "and" between terms for VoiceOver pacing.
    static func recallChipAccessibilityLabel(terms: [String]) -> String {
        let joined = terms.joined(separator: " and ")
        return "Recall recent search: \(joined)"
    }

    // MARK: Filtered-out state

    static let filteredOutHeadline = "No results match current filters"
    static let filteredOutDescription = "Your active filters hide all candidates. Adjust source, confidence, or category filters to see results."
}

// `SearchState+WalkSummary.swift` reads the empty-state discriminator
// under the catalog's former name (`emptyStateContext`); the alias keeps
// that caller compiling until its own file is next touched.
typealias WU20Strings = SearchEmptyStateCopy
