import SwiftUI
import UIKit
import PDFKit
import RedactionEngine

// The search run, out of the view: a value the sheet builds from its own
// objects and the searcher it owns (`makeRun()`), so a test can build the
// same value from plain objects and drive a run with no view. The bodies
// moved from SearchAndRedactSheet+Trigger.swift and
// SearchAndRedactSheet+DegradeBanner.swift unchanged; the sheet's statics
// they call are named on the sheet. The searcher's lifetime is the sheet's.

@MainActor struct SearchRun {
    let searchState: SearchState
    let redactionState: RedactionState
    let documentState: DocumentState
    let toastManager: ToastQueueManager
    let settingsState: SettingsState
    let userTermsStore: UserTermsStore
    /// The sheet's own instance, passed in: its lifetime does not change.
    let searcher: DocumentSearcher
    /// The message layer of the sheet that runs the search: the run's
    /// warnings belong to it.
    let messageLayerID: UUID?

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

    func trigger() {
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
                    trigger()
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
                await installEngineSinks(run: prepared.run)
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
                                    argument: "Scanning page \(current) of \(total)"
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
                // may have already installed sinks and set `isSearching` —
                // and when the run stopped at the result limit, which ends
                // as a cancelled run (`SearchState.runEndsCancelled`).
                await finishSearchRun(prepared, cancelled: Task.isCancelled)
            }
        }
    }

    /// The one failure path of `prepareSearchRun()`'s two guards (no
    /// document to copy; the private copy did not build): the in-flight
    /// flag drops, a mechanism toast names the failure — a silent exit
    /// reads as "never ran" once the sheet re-renders — and a Scan-
    /// interface run leaves a durable failed record, since a notice that
    /// only ever lived in a transient toast is no record at all (the
    /// banner persists it).
    private func failSearchPreparation() {
        searchState.isSearching = false
        toastManager.post(.searchPreparationFailed, runLayer: messageLayerID)
        if searchState.searchModeType == .piiScan {
            searchState.scanStartFailed = true
            redactionState.recordDetectionRun(
                .failed,
                scanSummary: .init(foundCount: 0, pageCount: 0))
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
        // A run this one replaces keeps no account: its pages are read again here.
        searchState.closeAccount(.dropped)
        await searchState.cancelSearch()
        // Snapshot the just-completed scan's
        // results (if any) into `priorScanFingerprints` BEFORE
        // `clearResults()` wipes the array. The snapshot survives
        // `clearResults` by design — see `SearchState.priorScanFingerprints`
        // docstring for the asymmetric clear-paths carve-out.
        // `diffSinceLastScan()` reads this snapshot once the new scan's
        // results land, surfacing the Coverage Report diff line.
        searchState.captureFingerprintsBeforeScan()
        let cleared = SearchAndRedactSheet.rerunClearedCount(in: searchState)
        searchState.skipNextRerunNotice = false  // one shot (a recall)
        searchState.clearResults()
        let interface = searchState.searchModeType.interface
        if SearchAndRedactSheet.rerunClearedMessage(selectedCount: cleared, interface: interface) != nil {
            toastManager.post(.searchRerunCleared(count: cleared, interface: interface))
        }
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
                searchState.regexError = SearchAndRedactSheet.regexErrorDisplayMessage(
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
            failSearchPreparation()
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
        guard let searchDoc = await Task.detached(priority: .utility, operation: { [holder = documentState.documentPassword] in
            SearchCopy.make(of: liveDocBox, unlockingWith: holder)
        }).value else {
            failSearchPreparation()
            return nil
        }

        let mode = buildSearchMode()
        searchState.lastRunShape = searchState.currentRunShape  // read in the same stretch as the query above
        searchState.totalPages = liveDoc.pageCount
        searchState.accountClosedSink = { [weak redactionState] token, account in
            redactionState?.recordSearchAccount(account, token: token)
        }
        searchState.beginAccount(run: run, pageCount: liveDoc.pageCount)

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
        let textLayerStatus: [Int: TextLayerStatus] = documentState.searchTextLayerStatus

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
        searchState.lastRunOCRPageCount = SearchEmptyStateCopy.ocrReadPageCount(  // the no-match copy's page count
            textLayerStatus, includeOCR: searchState.options.includeOCR, isScan: isPIIScan)
        // The configuration this Scan runs with, kept on the session so the
        // applied record reproduces the run (the blob, not the compiled
        // index — the record is a value). Nil for a typed run.
        searchState.lastRunScanConfiguration = isPIIScan
            ? ScanRunConfiguration(
                thresholdVector: thresholdVector,
                alwaysFlag: userTerms.alwaysFlag, neverFlag: userTerms.neverFlag)
            : nil

        // Degrade surface for the LIVE scan path. The
        // legacy detection pipeline surfaced its loader diagnostics via
        // `PipelineCoordinator.surfaceGazetteerLoadDiagnostics`, but the
        // Scan interface runs through `DocumentSearcher`, whose shared
        // detector degraded silently (an NER-absent OS build dropped
        // every name match with zero signal). Surface the shared
        // detector's load diagnostics at scan kickoff (on iOS 27 with the
        // live name canary's answer, `scanKickoffDiagnostics`): first qualifying
        // failure posts the one-time toast and raises the persistent
        // Scan-interface banner (same flag, same gate semantics as the
        // legacy path).
        if isPIIScan {
            let diagnostics = await DocumentSearcher.scanKickoffDiagnostics()
            if redactionState.noteScanKickoffDiagnostics(diagnostics) != nil {
                toastManager.post(.detectionDegraded(failedGazetteers: diagnostics.failedGazetteers),
                                  runLayer: messageLayerID)
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
        #if DEBUG
        if let page = ResectaApp.uitestOCRSkipPage(for: CommandLine.arguments) { searchState.recordOCRSkip(page: page) }
        #endif

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
    private func installEngineSinks(run: Int) async {
        // The pattern a regex timeout is for: the run's own query, as it was typed.
        let pattern = searchState.queryText
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
                searchState?.recordPatternTimedOut(page: page, text: pattern, run: run)
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
                searchState.recordRegexRejection(SearchAndRedactSheet.regexErrorDisplayMessage(
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
        // reports a term the page's time budget did not let it check
        // in full. The message names neither the term nor the page, and
        // a latch on this scan shows it once however many pages run out:
        // the queue's own coalescing lasts only while the first toast is
        // on screen or queued, so a page that ran out later showed it
        // again (the OCR-off sink below takes the message's shape).
        let timeoutToast = SearchAndRedactSheet.ScanOnceLatch()
        // The sinks' warnings belong to this sheet's layer, read now: a
        // sheet over Search (the saved list as a recall starts the run)
        // does not take them.
        let runLayer = messageLayerID
        await searcher.setUserTermsTimeoutSink({ [weak toastManager, weak searchState] page, term in
            Task { @MainActor in
                searchState?.recordPatternTimedOut(page: page, text: term, run: run)
                guard timeoutToast.fire() else { return }
                toastManager?.post(.customTermTimeout, runLayer: runLayer)
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
        await searcher.setScannedRegionNotAnalyzedSink({ [weak toastManager, weak searchState] page in
            Task { @MainActor in
                searchState?.recordRecognitionOff(page: page, run: run)
                toastManager?.post(.scannedRegionsNotAnalyzed, runLayer: runLayer)
            }
        })
        // Install the page-coverage sink: each page's report goes into this
        // run's account (`SearchState+Account.swift`).
        await searcher.setPageCoverageSink({ [weak searchState] coverage in
            Task { @MainActor in
                searchState?.recordCoverage(coverage, run: run)
            }
        })
    }

    /// The first-page doctype classification for a Scan run: cheap
    /// (<5 ms) and gives the footer its top-3 probabilities. The page
    /// text comes off a detached task (`firstPageText`).
    private func classifyDoctypeIfNeeded(_ prepared: PreparedRun) async {
        if prepared.isPIIScan,
           let firstPageText = await SearchAndRedactSheet.firstPageText(of: prepared.searchDoc) {
            let classifier = DocumentTypeClassifier()
            let explanation = await classifier.explain(pageText: firstPageText)
            await MainActor.run {
                searchState.setDoctypeExplanation(explanation)
            }
        }

    }

    /// The run's cleanup tail: the state half (`endRunState`: the last
    /// flush, the run-state flips, the Scan coverage report and run
    /// record), the sink teardown and the VoiceOver completion line.
    /// Skipped when the run ends as a cancelled one — a successor task
    /// may have already installed sinks and set `isSearching`.
    private func finishSearchRun(_ prepared: PreparedRun, cancelled: Bool) async {
        let scan = prepared.isPIIScan
            ? SearchAndRedactSheet.ScanRunFacts(enabled: prepared.enabledCategories, startedAt: prepared.scanStartedAt) : nil
        guard SearchAndRedactSheet.endRunState(
            run: prepared.run, taskCancelled: cancelled, scan: scan,
            searchState: searchState, redactionState: redactionState
        ) else { return }

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
        await searcher.setPageCoverageSink(nil)

    }

    /// The query this run searches for, built from the session alone (`SearchQuery`).
    func buildSearchMode() -> SearchMode { SearchQuery(searchState: searchState).buildSearchMode() }
}
