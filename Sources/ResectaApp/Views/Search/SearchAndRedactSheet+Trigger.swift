import SwiftUI
import UIKit
import PDFKit
import RedactionEngine

// Search trigger + debounce + coverage helpers lifted from
// `SearchAndRedactSheet.swift` (split target
// "<500 LOC sheet"). Pure structural lift; no behavior change. The
// static helpers (`firstPageText`, `makeCoverageReport`) move with
// their sole consumer (`triggerSearch`) and stay `private static`
// since the extension file is their only call site.

extension SearchAndRedactSheet {

    // MARK: - Search Trigger

    func debounceSearch(query: String) {
        searchDebounceTask?.cancel()
        guard !query.isEmpty else {
            Task { @MainActor in
                await searchState.cancelSearch()
                searchState.clearResults()
            }
            return
        }
        // Short terms require explicit trigger
        guard query.count >= 3 else { return }

        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            triggerSearch()
        }
    }

    func triggerSearch() {
        // Orchestration runs inside a Task so the prior task's cleanup
        // tail completes (via `await searchState.cancelSearch()`) before
        // the new scan installs sinks and flips `isSearching`.
        Task { @MainActor in
            await searchState.cancelSearch()
            // Snapshot the just-completed scan's
            // results (if any) into `priorScanFingerprints` BEFORE
            // `clearResults()` wipes the array. The snapshot survives
            // `clearResults` by design — see `SearchState.priorScanFingerprints`
            // docstring for the asymmetric clear-paths carve-out.
            // `diffSinceLastScan()` reads this snapshot once the new scan's
            // results land, surfacing the Coverage Report diff line.
            searchState.captureFingerprintsBeforeScan()
            searchState.clearResults()

            // Pre-validate regex before starting search.
            // Surface the rejection reason —
            // the engine's NSError localizedDescription verbatim for
            // compile failures,
            // or the typed RegexValidationError's mechanism-description
            // copy for the safety gates. The prior hardcoded "Invalid
            // regular expression" discarded both.
            if searchState.searchModeType == .regex {
                do {
                    _ = try DocumentSearcher.validateRegexPatternWithError(searchState.queryText)
                } catch { // LegalPhrases:safe (Swift keyword)
                    // UXF-18: lead with a human hint for the common
                    // failure shapes; the engine's original error text
                    // stays available after it. No hint matched → the
                    // original text alone, as before.
                    searchState.regexError = Self.regexErrorDisplayMessage(
                        pattern: searchState.queryText,
                        engineDescription: error.localizedDescription
                    )
                    return
                }
            }

            // Record multi-term term sets into the
            // in-memory recall ring so the empty state can surface them
            // as tappable chips on the next traversal through the empty
            // state. Recording at trigger time (not at term-add time)
            // means we only capture sets the user actually committed to.
            if searchState.searchModeType == .multiTerm {
                searchState.recordMultiTermSearch(terms: searchState.searchTerms)
            }

            // Persist text/regex queries to the recents
            // ring. No-op for empty queries, piiScan, multiTerm, and when
            // the user has disabled recents via the Settings toggle.
            // Stores the QUERY string only — never matched text.
            searchState.recordRecentQuery(
                searchState.queryText,
                mode: searchState.searchModeType
            )

            searchState.isSearching = true

            guard let liveDoc = documentState.sourceDocument else {
                searchState.isSearching = false
                return
            }

            // Build a private copy off-main so the background search and
            // the first-page classifier never read the on-screen PDFDocument
            // the PDFView renders on the main thread. The cheap
            // `SendablePDFDocument` wrap happens on MainActor; the costly
            // dataRepresentation + reconstruct runs in the detached task
            // (mirrors `firstPageText`). A nil copy ⇒ no shared-instance
            // fallback — surface a mechanism toast and stop.
            let liveDocBox = SendablePDFDocument(liveDoc)
            guard let searchDoc = await Task.detached(priority: .utility, operation: {
                DocumentState.makeSearchCopy(of: liveDocBox)
            }).value else {
                searchState.isSearching = false
                toastManager.enqueue(
                    "Could not prepare the document for search. Try again.",
                    severity: .warning
                )
                return
            }

            let mode = buildSearchMode()
            searchState.totalPages = liveDoc.pageCount

            // Snapshot the user-selected preset's
            // vector before kickoff so each scan runs against a stable
            // copy. `settingsState` is the sheet's existing @Environment
            // read (internal, extension-visible).
            let thresholdVector: PresetThresholdVector? = settingsState.activeThresholdVector

            // Snapshot the per-page text-layer classification
            // computed at import time. `DocumentSearcher` consults it so a
            // `.sparse`/`.none` page (a header-only layer over a scanned body)
            // routes to OCR instead of having its body suppressed by the thin
            // layer. Snapshot here, like the threshold vector, so the scan runs
            // against a stable copy.
            let textLayerStatus: [Int: TextLayerStatus] = documentState.textLayerStatus

            // Snapshot + compile user terms once per kickoff. Compile is
            // cheap (≤100+100 patterns, most literal), same lifecycle as
            // the threshold vector. `UserTermsIndex` wraps the matcher so
            // the engine runs never-flag suppression pre-threshold. Only
            // attach when non-empty to keep the hot path unchanged for
            // users with no custom terms.
            let userTerms = userTermsStore.blob
            let userTermsIndex: UserTermsIndex? = {
                let compiled = UserTermsIndex.compile(
                    alwaysFlag: userTerms.alwaysFlag,
                    neverFlag: userTerms.neverFlag
                )
                return compiled.isEmpty ? nil : compiled
            }()

            // Capture PII scan configuration for the coverage report +
            // doctype explanation. Classifier runs on the first page only;
            // cheap (<5ms) and gives the footer its top-3 probabilities.
            let isPIIScan = searchState.searchModeType == .piiScan
            let enabledCategories = searchState.enabledPIICategories
            let scanStartedAt = Date()

            // Reset the overlap-suppressed tally before kickoff so the
            // CoverageReport only reflects this scan's counts.
            searchState.resetOverlapSuppression()
            // Reset the below-threshold tally for the same reason.
            searchState.resetBelowThresholdSuppression()
            // Reset the regex-timeout page set before kickoff so
            // the banner only reflects pages affected by THIS scan.
            searchState.resetRegexTimeoutPages()
            // ST-83 — reset the OCR-skip page set for the same reason.
            searchState.resetOCRSkippedPages()

            searchState.activeSearchTask = Task {
                await searcher.setThresholdVector(thresholdVector)
                await searcher.setUserTerms(userTermsIndex)
                // Install the per-page text-layer classification
                // so the engine routes `.sparse`/`.none` pages to OCR.
                await searcher.setTextLayerStatus(textLayerStatus)
                // Install the overlap sink. `DocumentSearcher` calls this
                // once per page where the resolver dropped at least one loser.
                await searcher.setOverlapSink({ [weak searchState] counts in
                    Task { @MainActor in
                        searchState?.accumulateOverlapSuppression(counts)
                    }
                })
                // Install the below-threshold sink. `DocumentSearcher`
                // calls this once per page where the raw threshold gate dropped at
                // least one match, mirroring the overlap sink above.
                await searcher.setBelowThresholdSink({ [weak searchState] count in
                    Task { @MainActor in
                        searchState?.accumulateBelowThresholdSuppression(count)
                    }
                })
                // Install the regex-timeout sink mirroring the overlap
                // sink. `DocumentSearcher` calls this once per page where the
                // regex enumerator bails on the per-page timeout, in both
                // the preview path and the search path.
                await searcher.setRegexTimeoutSink({ [weak searchState] page in
                    Task { @MainActor in
                        searchState?.recordRegexTimeout(page: page)
                    }
                })
                // ST-83 — install the oversized-OCR-skip sink mirroring
                // the regex-timeout sink. `DocumentSearcher` calls this
                // once per OCR attempt on a page whose render exceeds the
                // OCR pixel caps; the banner tells the user those pages'
                // image content was never text-scanned.
                await searcher.setOCRSkipSink({ [weak searchState] page in
                    Task { @MainActor in
                        searchState?.recordOCRSkip(page: page)
                    }
                })
                // Install the custom-terms always-flag timeout
                // sink. `DocumentSearcher` calls this once per (page, user-
                // authored pattern) when `UserTermMatcher.alwaysFlagHits`
                // reports a regex term whose enumeration bailed on the
                // per-page timeout. Per-term-per-page semantics: the term
                // stays active on subsequent pages within the same scan,
                // so each affected (page, pattern) emits its own toast.
                // Truncated to 24 user-facing chars so a long pasted pattern
                // can't dominate the message; trailing "…" disambiguates a
                // truncated tail.
                await searcher.setUserTermsTimeoutSink({ [weak toastManager] page, pattern in
                    Task { @MainActor in
                        let truncated: String = pattern.count > 24
                            ? "\(String(pattern.prefix(24)))…"
                            : pattern
                        let message =
                            "Custom term '\(truncated)' took too long on page \(page + 1) — skipped."
                        toastManager?.enqueue(message, severity: .warning)
                    }
                })
                // Surface the "scanned region not analyzed"
                // signal. `DocumentSearcher` fires this per page that carries a
                // `.sparse`/`.none` region while `includeOCR` is off, so the user
                // learns scanned content was not searched. The message omits the
                // page number so duplicate-coalescing (ToastQueueManager)
                // collapses a multi-page scan to a single toast.
                //
                // The user-facing string is mechanism-description
                // language; it makes no outcome promise.
                await searcher.setScannedRegionNotAnalyzedSink({ [weak toastManager] _ in
                    Task { @MainActor in
                        toastManager?.enqueue(
                            "Some pages hold scanned regions that weren't text-analyzed because OCR is off. Turn on Include OCR to search scanned content.",
                            severity: .warning
                        )
                    }
                })

                if isPIIScan,
                   let firstPageText = await Self.firstPageText(of: searchDoc) {
                    let classifier = DocumentTypeClassifier()
                    let explanation = await classifier.explain(pageText: firstPageText)
                    await MainActor.run {
                        searchState.setDoctypeExplanation(explanation)
                    }
                }

                let stream = searcher.search(
                    searchDoc,
                    mode: mode,
                    progress: { current, total in
                        Task { @MainActor in
                            searchState.currentSearchPage = current
                            searchState.totalPages = total
                            // VoiceOver progress announcement (every 10 pages)
                            if UIAccessibility.isVoiceOverRunning && current % 10 == 0 {
                                UIAccessibility.post(
                                    notification: .announcement,
                                    argument: "Searching page \(current) of \(total)"
                                )
                            }
                        }
                    }
                )

                for await result in stream {
                    if Task.isCancelled { break }
                    searchState.appendResult(result)
                }

                // Skip the cleanup tail when cancelled — a successor task
                // may have already installed sinks and set `isSearching`.
                if !Task.isCancelled {
                    searchState.flushPendingResults()
                    // Magic-wand pre-select flag is single-use:
                    // applies to the matches this scan emits, then resets
                    // so a follow-up search from the same sheet session
                    // doesn't carry magic-wand semantics forward.
                    searchState.preselectIncomingResults = false
                    searchState.isSearching = false

                    if isPIIScan {
                        let report = Self.makeCoverageReport(
                            scannedPages: searchState.totalPages,
                            enabled: enabledCategories,
                            results: searchState.results,
                            overlapSuppressed: searchState.pendingOverlapSuppressed,
                            belowThresholdSuppressed: searchState.pendingBelowThresholdSuppressed,
                            startedAt: scanStartedAt,
                            completedAt: Date()
                        )
                        searchState.setCoverageReport(report)
                    }

                    await searcher.setOverlapSink(nil)
                    await searcher.setBelowThresholdSink(nil)
                    await searcher.setRegexTimeoutSink(nil)
                    await searcher.setUserTermsTimeoutSink(nil)
                    await searcher.setScannedRegionNotAnalyzedSink(nil)

                    if UIAccessibility.isVoiceOverRunning {
                        let count = searchState.totalCount
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Search complete, \(count) result\(count == 1 ? "" : "s") found"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Regex error hints (UXF-18)

    /// Map the common NSRegularExpression failure shapes to a one-line
    /// human hint by inspecting the PATTERN (the NSError text is opaque
    /// boilerplate). A switch on shape, no parsing dependency;
    /// nil when no common shape matches. Order matters: the earlier,
    /// more specific shapes win. Pinned by `RegexErrorHintTests`.
    static func regexErrorHint(pattern: String) -> String? {
        // Walk once, tracking escapes so "\(" doesn't count as a group.
        var parenDepth = 0
        var unmatchedCloseParen = false
        var bracketOpen = false
        var escaped = false
        var previousUnescaped: Character? = nil
        var danglingQuantifier = false
        let quantifiers: Set<Character> = ["*", "+", "?"]
        for ch in pattern {
            if escaped {
                escaped = false
                // An escaped character is a valid quantifier operand
                // ("\d+"); record a neutral placeholder so the dangling
                // check above doesn't misread it as "(", "|", or nothing.
                previousUnescaped = "a"
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if bracketOpen {
                if ch == "]" { bracketOpen = false }
                continue
            }
            switch ch {
            case "[": bracketOpen = true
            case "(": parenDepth += 1
            case ")":
                parenDepth -= 1
                if parenDepth < 0 { unmatchedCloseParen = true }
            default: break
            }
            if quantifiers.contains(ch) {
                // A quantifier must follow something repeatable; after
                // nothing, "(", "|", or another dangling position it has
                // no operand. ("?" after a quantifier is lazy-match and
                // fine — previousUnescaped covers that, since the prior
                // quantifier was itself preceded by an operand.)
                switch previousUnescaped {
                case nil, "(", "|":
                    danglingQuantifier = true
                default: break
                }
            }
            previousUnescaped = ch
        }
        if escaped {
            return "The pattern ends with a lone backslash — remove it, or double it (\\\\) to match a literal backslash."
        }
        if bracketOpen {
            return "A [ character class is never closed — add the matching ]."
        }
        if parenDepth > 0 {
            return "A ( group is never closed — add the matching )."
        }
        if unmatchedCloseParen {
            return "A ) has no matching ( — remove it or add the opening (."
        }
        if danglingQuantifier {
            return "A *, +, or ? needs something before it to repeat."
        }
        return nil
    }

    /// Compose the callout text: hint first (when one matched), the
    /// engine's original description preserved after it.
    static func regexErrorDisplayMessage(
        pattern: String,
        engineDescription: String
    ) -> String {
        guard let hint = regexErrorHint(pattern: pattern) else {
            return engineDescription
        }
        return "\(hint) (\(engineDescription))"
    }

    // MARK: - Helpers

    /// Returns the text of the first page (up to `maxPages` scanned) whose
    /// PDFKit text extraction yields a non-empty string. Runs in a
    /// detached task so the per-page `page.string` (synchronous PDFKit,
    /// 10–100 ms per page on scanned-only PDFs) doesn't block MainActor
    /// at scan kickoff.
    private static func firstPageText(
        of doc: SendablePDFDocument,
        maxPages: Int = 5
    ) async -> String? {
        await Task.detached(priority: .utility) {
            let document = doc.document
            let cap = min(maxPages, document.pageCount)
            for idx in 0..<cap {
                guard let page = document.page(at: idx) else { continue }
                let text = page.string ?? ""
                if !text.isEmpty { return text }
            }
            return nil
        }.value
    }

    // `internal` (not `private`) so `SearchStateTests` can pin the
    // below-threshold tally → `belowThresholdSuppressedCount` wiring directly.
    static func makeCoverageReport(
        scannedPages: Int,
        enabled: Set<PIICategory>,
        results: [SearchResult],
        overlapSuppressed: [PIICategory: Int],
        belowThresholdSuppressed: Int,
        startedAt: Date,
        completedAt: Date
    ) -> CoverageReport {
        var counts: [PIICategory: Int] = [:]
        for result in results {
            guard let cat = result.piiCategory else { continue }
            counts[cat, default: 0] += 1
        }
        return CoverageReport(
            scannedPageCount: scannedPages,
            enabledCategories: enabled,
            candidateCountByCategory: counts,
            appliedCount: 0,
            deselectedCount: 0,
            belowThresholdSuppressedCount: belowThresholdSuppressed,
            overlapSuppressedCountByCategory: overlapSuppressed,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}
