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
        // Short terms require explicit trigger. The floor
        // counts TRIMMED characters (mirroring multi-term's validator
        // trim), so whitespace-only input never auto-runs a real
        // engine pass under a visually-empty field.
        guard Self.queryQualifiesForAutoRun(query) else { return }

        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            triggerSearch()
        }
    }

    /// What `prepareSearchRun()` hands the run task: the run token, the
    /// private document copy, the engine mode, the kickoff snapshots
    /// (the preset's threshold vector, the per-page text-layer
    /// classification, the compiled user terms) and the Scan facts the
    /// coverage report reads at the tail.
    private struct PreparedRun {
        let run: Int
        let searchDoc: SendablePDFDocument
        let mode: SearchMode
        let thresholdVector: PresetThresholdVector?
        let textLayerStatus: [Int: TextLayerStatus]
        let userTermsIndex: UserTermsIndex?
        let isPIIScan: Bool
        let enabledCategories: Set<PIICategory>
        let scanStartedAt: Date
    }

    func triggerSearch() {
        // Belt: no run may start while staged detections await
        // review — the review owns the Scan surface until resolved
        // (Apply / Dismiss). Every trigger site is already parked
        // during a review (run button hidden, recall disabled, auto-run
        // unarmed); this guard is defense-in-depth for future callers.
        guard redactionState.pendingTriage == nil else { return }
        // Single-flight: setup below spans real suspension points
        // (cancel-await, detached document copy) before
        // `activeSearchTask` is assigned. Overlapping callers — rapid
        // multi-term Returns, double-tapped run affordances — coalesce
        // into one deferred re-trigger instead of racing a second
        // orchestration past the nil task handle, which orphaned the
        // loser's scan and double-wrote the run record.
        guard searchState.beginTriggerSetup() else { return }
        // Orchestration runs inside a Task so the prior task's cleanup
        // tail completes (via `await searchState.cancelSearch()`, the
        // first thing `prepareSearchRun()` does) before the new scan
        // installs sinks and flips `isSearching`.
        Task { @MainActor in
            defer {
                // Window closes on every exit path; a coalesced caller
                // re-runs once so the final scan reflects the latest
                // query shape.
                if searchState.endTriggerSetup() {
                    triggerSearch()
                }
            }
            guard let prepared = await prepareSearchRun() else { return }
            let run = prepared.run

            searchState.activeSearchTask = Task {
                await searcher.setThresholdVector(prepared.thresholdVector)
                await searcher.setUserTerms(prepared.userTermsIndex)
                // Install the per-page text-layer classification
                // so the engine routes `.sparse`/`.none` pages to OCR.
                await searcher.setTextLayerStatus(prepared.textLayerStatus)
                await installEngineSinks()
                await classifyDoctypeIfNeeded(prepared)

                let stream = searcher.search(
                    prepared.searchDoc,
                    mode: prepared.mode,
                    progress: { current, total in
                        Task { @MainActor in
                            // A superseded run's page hops must not move
                            // this run's counters.
                            guard searchState.runToken == run else { return }
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
                    searchState.appendResult(result, run: run)
                }

                // Skip the cleanup tail when cancelled — a successor task
                // may have already installed sinks and set `isSearching`.
                await finishSearchRun(prepared, cancelled: Task.isCancelled)
            }
        }
    }

    /// The run's setup — everything between the prior task's
    /// cancel-await and the run task: the fingerprint snapshot and the
    /// clear, the run token, the regex pre-validation, the multi-term
    /// recall, the private document copy, the kickoff snapshots, the
    /// Scan degrade surface and the four tally resets. Nil when the run
    /// cannot start (an invalid pattern, or no document to copy) — each
    /// such exit has already surfaced its notice and, for a Scan, its
    /// failed run record.
    private func prepareSearchRun() async -> PreparedRun? {
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
        // The token this run's results and progress hops carry: a
        // cancelled predecessor still draining its stream is told
        // apart by it and dropped, so its late batch can never land
        // in this run's list.
        let run = searchState.beginRun()

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
                // Lead with a human hint for the common
                // failure shapes; the engine's original error text
                // stays available after it. No hint matched → the
                // original text alone, as before.
                searchState.regexError = Self.regexErrorDisplayMessage(
                    pattern: searchState.queryText,
                    engineDescription: error.localizedDescription
                )
                return nil
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

        searchState.isSearching = true

        guard let liveDoc = documentState.sourceDocument else {
            searchState.isSearching = false
            // Same feedback contract as the copy-failure guard
            // below — a silent exit reads as "never ran" once the
            // sheet re-renders.
            toastManager.enqueue(
                "Could not prepare the document for search. Try again.",
                severity: .warning
            )
            if searchState.searchModeType == .piiScan {
                searchState.scanStartFailed = true
                redactionState.recordDetectionRun(
                    .failed,
                    scanSummary: .init(foundCount: 0, pageCount: 0))
            }
            return nil
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
            // Scan-interface runs leave a durable failed record —
            // a failure notice that only ever lived in a transient
            // toast is no record at all (the banner persists it).
            if searchState.searchModeType == .piiScan {
                searchState.scanStartFailed = true
                redactionState.recordDetectionRun(
                    .failed,
                    scanSummary: .init(foundCount: 0, pageCount: 0))
            }
            return nil
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
        // The EFFECTIVE set (empty selection = everything) is what
        // the engine query requests, so the report describes the
        // run that actually happened.
        let isPIIScan = searchState.searchModeType == .piiScan
        let enabledCategories = searchState.effectiveScanCategories
        let scanStartedAt = Date()

        // Freeze the executed detector count for the
        // zero-state completion copy, beside the engine query's own
        // category snapshot above.
        if isPIIScan {
            searchState.lastRunDetectorCount = enabledCategories.count
        }

        // Degrade surface for the LIVE scan path. The
        // legacy detection pipeline surfaced its loader diagnostics via
        // `PipelineCoordinator.surfaceGazetteerLoadDiagnostics`, but the
        // Scan interface runs through `DocumentSearcher`, whose shared
        // detector degraded silently (an NER-absent OS build dropped
        // every name match with zero signal). Surface the shared
        // detector's load diagnostics at scan kickoff: first qualifying
        // failure posts the one-time toast and raises the persistent
        // Scan-interface banner (same flag, same gate semantics as the
        // legacy path).
        if isPIIScan {
            let diagnostics = DocumentSearcher.sharedLoadDiagnostics
            if diagnostics.didDegrade,
               !redactionState.autoDetectionDegraded {
                redactionState.autoDetectionDegraded = true
                redactionState.autoDetectionDegradeFailures =
                    diagnostics.failedGazetteers
                toastManager.enqueue(
                    DetectionDegradeCopy.toast(
                        failedGazetteers: diagnostics.failedGazetteers),
                    severity: .warning
                )
            }
        }

        // Reset the overlap-suppressed tally before kickoff so the
        // CoverageReport only reflects this scan's counts.
        searchState.resetOverlapSuppression()
        // Reset the below-threshold tally for the same reason.
        searchState.resetBelowThresholdSuppression()
        // Reset the regex-timeout page set before kickoff so
        // the banner only reflects pages affected by THIS scan.
        searchState.resetRegexTimeoutPages()
        // Reset the OCR-skip page set for the same reason.
        searchState.resetOCRSkippedPages()

        return PreparedRun(
            run: run,
            searchDoc: searchDoc,
            mode: mode,
            thresholdVector: thresholdVector,
            textLayerStatus: textLayerStatus,
            userTermsIndex: userTermsIndex,
            isPIIScan: isPIIScan,
            enabledCategories: enabledCategories,
            scanStartedAt: scanStartedAt)
    }

    /// The seven engine sinks, installed on the run task before the
    /// stream opens. `tearDownEngineSinks()` nils six of them at the
    /// tail (the OCR-skip sink has never been nilled there).
    private func installEngineSinks() async {
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
        // Install the regex-rejection sink beside the timeout
        // sink. `DocumentSearcher` fires it once when the safety
        // gate refuses the pattern at search start (the stream then
        // finishes empty); the same hint + engine copy the
        // pre-validation composes reaches the callout, so a
        // rejected pattern never reads as "0 results".
        await searcher.setRegexRejectionSink({ [weak searchState] reason in
            Task { @MainActor in
                guard let searchState else { return }
                searchState.recordRegexRejection(Self.regexErrorDisplayMessage(
                    pattern: searchState.queryText, engineDescription: reason))
            }
        })
        // Install the oversized-OCR-skip sink mirroring
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

    }

    /// The first-page doctype classification for a Scan run: cheap
    /// (<5 ms) and gives the footer its top-3 probabilities. The page
    /// text comes off a detached task (`firstPageText`).
    private func classifyDoctypeIfNeeded(_ prepared: PreparedRun) async {
        if prepared.isPIIScan,
           let firstPageText = await Self.firstPageText(of: prepared.searchDoc) {
            let classifier = DocumentTypeClassifier()
            let explanation = await classifier.explain(pageText: firstPageText)
            await MainActor.run {
                searchState.setDoctypeExplanation(explanation)
            }
        }

    }

    /// The run's cleanup tail: the last flush, the run-state flips, the
    /// Scan coverage report and run record, the sink teardown and the
    /// VoiceOver completion line. Skipped when cancelled — a successor
    /// task may have already installed sinks and set `isSearching`.
    private func finishSearchRun(_ prepared: PreparedRun, cancelled: Bool) async {
        guard !cancelled else { return }
        searchState.flushPendingResults()
        // A completed (non-cancelled) run flips the
        // empty-state discriminator from "not run yet" to a
        // genuine result verdict.
        searchState.hasCompletedRunSinceClear = true
        // Magic-wand pre-select flag is single-use:
        // applies to the matches this scan emits, then resets
        // so a follow-up search from the same sheet session
        // doesn't carry magic-wand semantics forward.
        searchState.preselectIncomingResults = false
        searchState.isSearching = false

        if prepared.isPIIScan {
            let report = Self.makeCoverageReport(
                scannedPages: searchState.totalPages,
                enabled: prepared.enabledCategories,
                results: searchState.results,
                overlapSuppressed: searchState.pendingOverlapSuppressed,
                belowThresholdSuppressed: searchState.pendingBelowThresholdSuppressed,
                startedAt: prepared.scanStartedAt,
                completedAt: Date()
            )
            searchState.setCoverageReport(report)

            // Run-outcome record for the Scan interface —
            // the summary banner is the run-outcome surface
            // for both origins now. Found runs auto-dismiss
            // (the results are on screen in the sheet);
            // zero-found runs persist so "ran and found
            // nothing" stays distinguishable from "never
            // ran" after the sheet closes. Cancelled runs
            // skip this tail and leave no record.
            redactionState.recordDetectionRun(
                searchState.results.isEmpty
                    ? .nothingFound(pageCount: searchState.totalPages)
                    : .staged,
                scanSummary: .init(
                    foundCount: searchState.results.count,
                    pageCount: searchState.totalPages),
                ocrSkippedPages: searchState.ocrSkippedPages)
        }

        await tearDownEngineSinks()

        if UIAccessibility.isVoiceOverRunning {
            let count = searchState.totalCount
            UIAccessibility.post(
                notification: .announcement,
                argument: "Search complete, \(count) result\(count == 1 ? "" : "s") found"
            )
        }
    }

    /// The six sink nils of the cleanup tail.
    private func tearDownEngineSinks() async {
        await searcher.setOverlapSink(nil)
        await searcher.setBelowThresholdSink(nil)
        await searcher.setRegexTimeoutSink(nil)
        await searcher.setRegexRejectionSink(nil)
        await searcher.setUserTermsTimeoutSink(nil)
        await searcher.setScannedRegionNotAnalyzedSink(nil)

    }

    /// Debounce auto-run floor on the trimmed length. The
    /// query still runs VERBATIM (trailing spaces are meaningful to a
    /// literal search); trimming here only gates whether typing alone
    /// starts a run.
    static func queryQualifiesForAutoRun(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    // MARK: - Regex error hints

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
    /// engine's original description preserved after it, then the
    /// built-in detector the pattern's shape already spells out (when one
    /// does) — a refused email or number pattern is not a dead end when
    /// the detector that covers it is one tap away. Both refusal paths
    /// (the pre-validation here and the engine's rejection sink) compose
    /// through this one function.
    static func regexErrorDisplayMessage(
        pattern: String,
        engineDescription: String
    ) -> String {
        var message = engineDescription
        if let hint = regexErrorHint(pattern: pattern) {
            message = "\(hint) (\(engineDescription))"
        }
        if let category = SearchToolbarSection.builtInDetectorCovering(pattern: pattern) {
            message += " \(SearchToolbarSection.builtInDetectorSentence(for: category))"
        }
        return message
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

    // MARK: - Apply (search origin)

    /// The one search-origin apply: the toolbar Apply, the Return
    /// shortcut and the compact handle's per-item Apply all run through
    /// it (the review origin, `applyReviewFindings`, stays its own
    /// path). `origin` is resolved by the caller BEFORE the await — the
    /// per-item path captures the current match's id at call time; the
    /// walk or a re-flush can move `currentResult` while the apply waits
    /// its turn, and the seam refuses a stale id with zero mutations.
    /// `preflight` runs after the two gates and before the apply flag is
    /// raised (the shortcut's select-the-focused-match-if-none-selected).
    /// `navigateToFirst` moves the page to the first selected result
    /// once the seam returns; the per-item Apply stays put.
    ///
    /// The gates: `isApplying` (the sheet-wide one-apply-at-a-time flag)
    /// and `canMutateRegions` — refuse mutations while the pipeline owns
    /// `redactionState.regions`, the same gate as the buttons'
    /// `.disabled`, re-checked in the action against a pipeline that
    /// started after the last render (and again inside the path). A
    /// refused apply (the path's post-await re-check lost to a pipeline
    /// start) preserves the session for retry — dismissing here
    /// destroyed the user's results and selections over a transient
    /// refusal. Only the results that produced a region join the applied
    /// set: overlap-skipped members of the selection get no audit entry,
    /// so no "applied" badge either; the dedup-covered ids feed the
    /// Apply-graying gate. The success toast goes through the one
    /// `CommitFeedback` builder so the count stays in lockstep with the
    /// review-apply toasts (nil for a no-op apply, so a held shortcut
    /// against an all-overlap selection emits no "Marked 0" message;
    /// `toastManager.enqueue` coalesces duplicates). The
    /// conditional-dismiss tracker reset is owned by the apply path.
    /// (Lives here with `triggerSearch()` per the M-6 hub-cap
    /// decomposition — the run-orchestration family stays together;
    /// internal, not private, because the hub view's toolbar and the
    /// compact handle are callers.)
    func applySearchSelection(
        origin: RedactionState.ApplyOrigin,
        preflight: () -> Bool = { true },
        navigateToFirst: Bool
    ) {
        guard !isApplying else { return }
        guard documentState.canMutateRegions else { return }
        guard preflight() else { return }
        isApplying = true
        // Capture the selected ids before the apply clears the selection.
        let selectedIDs = navigateToFirst
            ? Set(searchState.results.filter(\.isSelected).map(\.id)) : []
        Task { @MainActor in
            defer { isApplying = false }
            guard let outcome = await redactionState.applyFindings(
                origin,
                undoManager: undoManager,
                documentState: documentState
            ) else { return }
            searchState.appliedResultIDs.formUnion(outcome.appliedResultIDs)
            searchState.coveredResultIDs.formUnion(outcome.coveredResultIDs)
            if let message = CommitFeedback.markedMessage(
                applied: outcome.applied,
                alreadyCovered: outcome.skippedOverlaps
            ) {
                toastManager.enqueue(message, severity: .success)
            }
            if navigateToFirst,
               let firstPage = searchState.results.first(where: { selectedIDs.contains($0.id) })?.pageIndex {
                documentState.currentPageIndex = firstPage
            }
        }
    }

    /// Toolbar Apply for the search origin.
    func applySelectedSearchResults() {
        applySearchSelection(origin: .selectedSearchResults, navigateToFirst: true)
    }

    // MARK: - Apply (keyboard shortcut)

    /// Return-shortcut Apply: the toolbar path, marking the focused
    /// result first when nothing is selected.
    func applyFromKeyboardShortcut() {
        applySearchSelection(
            origin: .selectedSearchResults,
            preflight: { searchState.selectCurrentMatchIfNoneSelected() },
            navigateToFirst: true)
    }

    /// Forwarded to `SearchResultsSection` so the invisible Return-shortcut
    /// Button can disable itself during an in-flight apply.
    var applyShortcutEnabled: Bool { !isApplying }

    // MARK: - Saved-Search Recall

    /// Apply a saved shape and re-run the search. The list sheet dismisses
    /// first (single-modal slot); recall then restores the shape via the
    /// testable static and triggers through the standard path — exactly
    /// one `triggerSearch()` (single-trigger discipline). If the
    /// recalled filter state hides every result, the existing
    /// "filters hide all candidates" empty state surfaces (already
    /// implemented in SearchResultsSection; no new copy).
    ///
    /// A recall that replaces a results-carrying session names the drop:
    /// the programmatic transition deliberately skips the mode-switch
    /// undo toast (the user explicitly chose a new search — a restore
    /// affordance would race the fresh run), but the trigger's own
    /// clear used to destroy unapplied matches with no signal at all.
    /// The notice closes that silence without adding any affordance.
    func recallSavedSearch(_ saved: SavedSearch) {
        activeModal = nil
        let dropped = Self.unappliedMatchCount(in: searchState)
        SavedSearchListSheet.apply(saved, to: searchState)
        triggerSearch()
        if let message = Self.recallClearedMessage(unappliedCount: dropped) {
            toastManager.enqueue(message, severity: .info)
        }
    }

    /// Notice for a recall that drops live unapplied matches. Returns
    /// nil when nothing unapplied is lost so the common recall stays
    /// toast-free. Sibling of `dismissClearedMessage` and the
    /// review-arrival notice — the family that keeps every
    /// results-dropping transition named. Pinned by
    /// `InterfaceSwitchClearTests`.
    static func recallClearedMessage(unappliedCount: Int) -> String? {
        guard unappliedCount > 0 else { return nil }
        let suffix = unappliedCount == 1 ? "" : "es"
        return "Recall cleared \(unappliedCount) unapplied match\(suffix)."
    }
}
