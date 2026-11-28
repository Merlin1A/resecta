import SwiftUI
import RedactionEngine

// The verification results page, grouped: the system grouped background
// inside the results view's own NavigationStack (the nav bar stays the
// editor's), the masthead said once (the count ring, the row-word title,
// one sentence), the actions (Share as a capsule, the action rows, the
// undo footnote), the check sections with their counts, the headerless run
// section, the passed checks, the completion line and the legal text as
// the last section's footer, the trust line. A page link pushes the Preview
// at that page on this same stack. Action-bar and export dialogs are still
// mounted by DocumentEditorView.

struct VerificationResultsView: View {
    let report: VerificationReport
    /// Defense-in-depth gate, computed once on `DocumentEditorView`
    /// (Phase 3) and threaded into both the bar and this card so they share
    /// one source of truth.
    let canExport: Bool
    /// The two facts behind `canExport`, threaded separately so a disabled
    /// Share card can say WHY (`shareDisabledReason`). `canExport` itself
    /// stays a single boolean — its derivation is pinned on
    /// `DocumentEditorView.canExport(report:)`.
    let outputExists: Bool
    let isVerificationStale: Bool
    /// Preview is offered whenever a redacted output exists on disk, independent
    /// of pass/warn/info/fail and of userOverrodeFailure (decoupled from the
    /// former isFailPreOverride gate). Computed once on DocumentEditorView and
    /// threaded in like `canExport`, since this view does not inject RedactionState.
    let previewAvailable: Bool
    /// Tap handler for the Share capsule. Mirrors the bar's
    /// `onExport` so ⌘E reaches `handleExportTap(report:)` from either
    /// surface.
    var onExport: () -> Void
    /// Tap handler for the Run Verification card shown on skipped reports.
    /// The routing decision — verify-only against the
    /// existing output vs. a full re-run — lives on `DocumentEditorView`
    /// (`handleRunVerificationTap`), which owns the coordinator and
    /// `RedactionState`; this view stays decoupled like `onExport`.
    var onRunVerification: () -> Void
    /// Deselection facts captured at run entry
    /// (`RedactionState.LastRunInputs.deselection`), threaded in like
    /// `previewAvailable`: a fact recorded with the output, never read live
    /// from the RedactionState this view also holds. Nil (also the default, so fixture call sites stay source-compatible)
    /// or zero deselections renders no row.
    var deselectionSnapshot: RedactionState.DeselectionSnapshot? = nil
    /// Pre-derived run facts for the run-facts strip, recorded with the
    /// output (mirrors `deselectionSnapshot`/`previewAvailable`), never read
    /// live from RedactionState; `DocumentEditorView` builds this via the
    /// pure `RunFacts.derive(...)` static func.
    /// Defaults to the empty/false value, so the strip renders nothing
    /// when unthreaded (keeps any future fixture call site
    /// source-compatible).
    var runFacts: RunFacts = RunFacts()

    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Environment(ToastQueueManager.self) private var toastManager

    @State private var previewPage: PreviewPage?
    /// What Boxes Can Show, while the boxes line's link row has opened it.
    @State private var presentedPage: LegalDocument?
    /// The findings the checks cannot see (`ResultsFindings`), derived when
    /// the screen appears and again when the boxes change.
    @State private var findings: [ResultsFinding] = []

    /// A page the Preview opens at (0-based), pushed on this view's stack.
    struct PreviewPage: Hashable, Identifiable {
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        VerificationMasthead(report: report, outputExists: outputExists,
                                             isStale: isVerificationStale,
                                             mode: runFacts.runMode,
                                             findingRows: Self.findingRowCount(report: report, findings: findings),
                                             handDrawnBoxes: Self.handDrawnBoxCount(in: findings))
                        VerificationResultsActions(
                            report: report, canExport: canExport, outputExists: outputExists,
                            isVerificationStale: isVerificationStale, previewAvailable: previewAvailable,
                            onExport: onExport, onRunVerification: onRunVerification,
                            concealedPages: VerificationResultsActions.concealedPages(in: findings))
                            .padding(.top, ResectaTokens.Results.blockGap)
                        // The blocks under the buttons in `ResultsBlock.order`:
                        // the hand-drawn row first; the small print here, or
                        // inside the section directly after its Findings group.
                        let afterFindings = ResultsBlock.smallPrintFollowsFindings(
                            ResultsBlock.order(present: Self.blocksPresent(report: report, findings: findings,
                                                                           smallPrint: smallPrint),
                                               checksPassed: Self.isChecksPassed(report)))
                        // Covered text and form values are Findings rows below;
                        // this section keeps what Share does not ask about.
                        ResultsFindingsSection(
                            findings: Self.findingsOutsideTheGroup(findings), pagesOnChips: previewAvailable,
                            onOpenPage: openPreview(at:))
                        if !afterFindings {
                            ResultsScopeNote(report: report, sentences: smallPrint)
                        }
                        VerificationDetailsSection(
                            report: report, deselectionSnapshot: deselectionSnapshot,
                            runFactsLines: runFactsLines,
                            runFactsDoorLine: RunFactsStrip.doorLine(for: runFacts),
                            previewAvailable: previewAvailable,
                            onOpenPage: openPreview(at:),
                            coveredPages: VerificationResultsActions.concealedPages(in: findings),
                            formValueCount: Self.formValueCount(in: findings),
                            smallPrintAfterFindings: afterFindings ? smallPrint : nil,
                            onReviewInScan: {
                                Self.reviewInScan(documentState: documentState, redactionState: redactionState)
                            },
                            onOpenDoor: { _ in presentedPage = .whatBoxesCanShow })
                        footerBlock
                        trustStrip
                            .padding(.top, ResectaTokens.Spacing.xl)
                    }
                    .padding(.horizontal, ResectaTokens.Spacing.md)
                    .padding(.top, ResectaTokens.Spacing.lg)
                    .padding(.bottom, dynamicTypeSize.isAccessibilitySize
                        ? ResectaTokens.Spacing.lg : ResectaTokens.Spacing.xxl)
                    .frame(maxWidth: columnMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("verificationResults")
            }
            .navigationDestination(item: $previewPage) { page in
                RedactedPreviewView(verdict: report.overallStatus, page: page.index)
            }
        }
        .task(id: redactionState.regionVersion) {
            findings = ResultsFindings.derive(documentState: documentState, redactionState: redactionState)
        }
        .sheet(item: $presentedPage) { page in
            LegalDocumentView(document: page)
                .messageLayer(toastManager, role: .holdsOnly)
        }
        // VerificationActionBar is placed by the phase router in
        // DocumentEditorView as .safeAreaInset, not embedded here. Export
        // dialogs are also mounted on DocumentEditorView.
    }

    /// The small print about what Checks Passed means, while this PDF is
    /// on disk.
    private var smallPrint: [String] {
        ResultsScopeNote.checksPassedSentences(outputExists: outputExists)
    }

    /// Whether the run is titled Checks Passed.
    static func isChecksPassed(_ report: VerificationReport) -> Bool {
        mastheadTitle(report: report) == VerificationStatus.pass.title
    }

    /// The rows of the Findings group, from the same two values the group is given.
    static func findingRowCount(report: VerificationReport, findings: [ResultsFinding]) -> Int {
        VerificationDetailsSection.findingRows(
            report: report, coveredPages: VerificationResultsActions.concealedPages(in: findings),
            formValueCount: formValueCount(in: findings)).count
    }

    /// The hand-drawn boxes on pages with no text, one per box (two on one
    /// page are two), as the row's own sentence counts them.
    static func handDrawnBoxCount(in findings: [ResultsFinding]) -> Int {
        for entry in findings {
            if case .handRegionsOnPagesWithoutText(let regionPages) = entry { return regionPages.count }
        }
        return 0
    }

    /// The blocks under the buttons that have something to draw.
    static func blocksPresent(report: VerificationReport, findings: [ResultsFinding],
                              smallPrint: [String]) -> Set<ResultsBlock> {
        let partition = VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
        var present: Set<ResultsBlock> = [.facts]
        if !findingsOutsideTheGroup(findings).isEmpty { present.insert(.handDrawnBoxes) }
        if findingRowCount(report: report, findings: findings) > 0 { present.insert(.findings) }
        if ResultsScopeNote.shows(report: report, sentences: smallPrint) { present.insert(.smallPrint) }
        if !VerificationDetailsSection.groups(partition).isEmpty { present.insert(.warnings) }
        if !VerificationDetailsSection.listRowMembers(partition).isEmpty { present.insert(.checksList) }
        return present
    }

    /// The items the shipped section above the checks still draws: only the
    /// hand-drawn regions on pages with no text, which Share does not ask
    /// about. Covered text and form values are rows of the Findings group.
    static func findingsOutsideTheGroup(_ findings: [ResultsFinding]) -> [ResultsFinding] {
        findings.filter { if case .handRegionsOnPagesWithoutText = $0 { true } else { false } }
    }

    /// The original's filled form values, as the findings count them; 0 when
    /// none is listed.
    static func formValueCount(in findings: [ResultsFinding]) -> Int {
        for entry in findings {
            if case .filledFormValuesNotCarried(let count) = entry { return count }
        }
        return 0
    }

    /// A page link: push the Preview at that page. A page past the
    /// document's end (a seeded report's pages on a short sample) is
    /// dropped; no phase changes.
    private func openPreview(at page: Int) {
        guard previewAvailable, Self.isPageInDocument(page, pageCount: documentState.pageCount) else { return }
        previewPage = PreviewPage(index: page)
    }

    /// Review in Scan: Keep Editing's transition, then the editor's Scan
    /// session (`SearchState.scanSession()`), which the editor's sheet slot
    /// presents and runs over the document.
    static func reviewInScan(documentState: DocumentState, redactionState: RedactionState) {
        documentState.transition(to: .editing)
        redactionState.activeSearch = SearchState.scanSession()
    }

    /// Whether a 0-based page exists in a document of `pageCount` pages; an
    /// unknown count (0) admits every page.
    static func isPageInDocument(_ page: Int, pageCount: Int) -> Bool {
        page >= 0 && (pageCount == 0 || page < pageCount)
    }

    // MARK: - Layout helpers

    /// Mirrors `HomeView.columnMaxWidth` (HomeView.swift:77-81).
    private var columnMaxWidth: CGFloat {
        horizontalSizeClass == .regular
            ? ResectaTokens.BrandedSurface.panelMaxWidthRegular
            : ResectaTokens.BrandedSurface.panelMaxWidthCompact
    }

    /// The page's run breakdown — the check sections and the completion
    /// line — describes a run's layer results. On the skipped sentinel
    /// (`layers.isEmpty`) there is no run to describe. One gate for both.
    /// Static so it's unit-testable without a SwiftUI host.
    static func shouldShowRunBreakdown(report: VerificationReport) -> Bool {
        !report.layers.isEmpty
    }

    // MARK: - Run facts strip
    //
    // Conditional lines stating what this run did not cover and what its
    // output is, the first rows of the headerless run section, on every
    // verdict; each needs its own fact, so a run with nothing to state renders
    // none. Every line is a pinned static builder so the rendered text is
    // unit-testable without a SwiftUI host. Whether the detectors ran on the
    // output is not stated here in prose: the verification ledger measures it.

    /// Pure facts input for the strip. `derive` is the single production
    /// source (called from `DocumentEditorView`); the plain-value
    /// default keeps every field off.
    struct RunFacts: Equatable {
        /// 0-indexed pages whose raster exceeded the OCR pixel
        /// caps during the run behind this output.
        var ocrSkippedPages: Set<Int> = []
        /// The degrade-failure list at the run behind this output's
        /// entry; nil when that run was not degraded.
        var degradeFailures: [String]? = nil
        /// The run's mode, for the SKIPPED sentences.
        var runMode: RunMode = .searchableOrUnknown
        /// The output's pages: one per page the run made.
        var pageCount: Int = 0
        /// The boxes the run burned, as burned (refused boxes are not among them).
        var burnedBoxes: Int = 0
        /// The output's size in bytes, read when the run finished.
        var outputBytes: Int64? = nil
        /// The pages the stop at Redact named, answered or not, at run entry.
        var pagesNotSearchedInFull: Set<Int> = []
        /// The pages whose only gap is small pictures, at run entry.
        var smallPicturePages: Set<Int> = []

        /// Pure derivation from the run's own retained inputs — every fact
        /// is read at run entry or when the run finished, and recorded with
        /// the output, so a later scan, box or search not followed by another
        /// Redact cannot move what this strip says about the on-screen report.
        /// With no inputs every fact is off.
        static func derive(inputs: RedactionState.LastRunInputs?) -> RunFacts {
            RunFacts(
                ocrSkippedPages: inputs?.ocrSkippedPages ?? [],
                degradeFailures: inputs?.degradeFailures,
                runMode: RunMode.of(perPageModes: inputs?.perPageModes ?? [],
                                    fallbackReasons: inputs?.perPageFallbackReasons ?? []),
                pageCount: inputs?.perPageModes.count ?? 0,
                burnedBoxes: inputs?.burnedRegions?.values.reduce(0) { $0 + $1.count } ?? 0,
                outputBytes: inputs?.outputBytes,
                pagesNotSearchedInFull: inputs?.pagesNotSearchedInFull ?? [],
                smallPicturePages: inputs?.smallPicturePages ?? []
            )
        }
    }

    /// Pinned line builders + line-order assembly.
    enum RunFactsStrip {
        /// 0-indexed input; 1-based page
        /// numbers via `SearchResultsSection.formatPageList`.
        static func ocrSkipLine(pages: [Int]) -> String {
            let oneBased = pages.sorted().map { $0 + 1 }
            let list = SearchResultsSection.formatPageList(oneBased)
            if oneBased.count == 1 {
                return "Page \(list) was too large to scan for text, so its image content was not examined by detection. Review that page manually before sharing."
            }
            return "Pages \(list) were too large to scan for text, so image content there was not examined by detection. Review those pages manually before sharing."
        }

        /// Reuses `DetectionDegradeCopy.banner` verbatim; no new
        /// degrade string.
        static func degradeLine(failedGazetteers: [String]) -> String {
            DetectionDegradeCopy.banner(failedGazetteers: failedGazetteers)
        }

        /// Ordered lines for the given facts: the OCR-skip line, the degrade
        /// line, the boxes, then the output's size and the long image-only
        /// line while the output is on disk, then the lines about what was
        /// not read before Redact (`unreadLines`), whose last reads the
        /// report shown. With no report and no output only the run's own
        /// facts speak.
        static func lines(for facts: RunFacts, report: VerificationReport? = nil,
                          outputExists: Bool = false) -> [String] {
            var result: [String] = []
            if !facts.ocrSkippedPages.isEmpty {
                result.append(ocrSkipLine(pages: Array(facts.ocrSkippedPages)))
            }
            if let degradeFailures = facts.degradeFailures {
                result.append(degradeLine(failedGazetteers: degradeFailures))
            }
            if facts.burnedBoxes > 0 {
                result.append(boxesLine(count: facts.burnedBoxes))
            }
            if outputExists, let bytes = facts.outputBytes {
                result.append(sizeLine(bytes: bytes))
            }
            if outputExists, facts.runMode == .secure, facts.pageCount > longImageOnlyPageCount {
                result.append(longImageOnlyLine(pages: facts.pageCount))
            }
            return result + unreadLines(for: facts, report: report)
        }
    }

    private var runFactsLines: [String] {
        RunFactsStrip.lines(for: runFacts, report: report, outputExists: outputExists)
    }

    // MARK: - The actions' rules and words (the view is VerificationResultsActions)

    /// Card visibility — skipped reports only. Static so the mount condition
    /// is unit-testable without a SwiftUI host (mirrors `shouldShowRunBreakdown`).
    static func shouldShowRunVerificationCard(report: VerificationReport) -> Bool {
        report.overallStatus.isSkipped
    }

    /// Body copy for the Run Verification card — one body for every skip
    /// reason; the masthead sentence carries the reason.
    static let runVerificationCardBodyText =
        "Run the checks on the redacted PDF before you share it."

    /// VoiceOver label for the Share card. Promoted to a `static` constant
    /// so the rebuild can't silently alter the spoken string and so it's
    /// unit-testable without rendering (mirrors the accessibility label
    /// contract in `AccessibilityLabelTests`).
    static let shareCardAccessibilityLabel =
        "Share Document. Save the redacted PDF or share it from this device."

    /// VoiceOver label for the Preview card.
    static let previewCardAccessibilityLabel =
        "Preview Redacted Document. \(previewCardBodyText)"

    /// Body copy for the Preview card.
    static let previewCardBodyText = "Open the redacted PDF in a read-only viewer."

    /// Defense-in-depth gate for the Share card: Share is enabled
    /// exactly when a fresh, valid output exists (`canExport`). Lifted to a
    /// `static` helper so the gate is a single source of truth and is
    /// unit-testable without a SwiftUI host (mirrors `shouldShowRunBreakdown`).
    /// Simplified to a single `canExport` input — the WARN confirmation and
    /// FAIL override gates were removed. Do not invert or inline.
    static func shareDisabled(canExport: Bool) -> Bool { !canExport }

    /// Explanation for a disabled Share card — nil exactly when Share is
    /// enabled. Takes the same two facts `DocumentEditorView.canExport(report:)`
    /// derives its boolean from, so the caption and the gate cannot disagree.
    /// A missing output file wins over staleness: the stale copy presumes an
    /// output exists to be stale against. Static so the (exists, stale) →
    /// copy mapping is unit-testable without a SwiftUI host.
    static func shareDisabledReason(outputExists: Bool, isStale: Bool) -> String? {
        // The second sentence holds together, so a line breaks between
        // the two sentences.
        let step = "Run\u{00A0}Redact\u{00A0}again\u{00A0}to\u{00A0}share."
        if !outputExists {
            return "The redacted PDF is no longer available. \(step)"
        }
        if isStale {
            return "Regions changed after this PDF was made. \(step)"
        }
        return nil
    }

    /// The undo footnote under the actions, on every run.
    static let undoFootnote = "Redact cleared undo; use Delete\u{00A0}Region instead."

    /// The Share-card caption for a source that was encrypted. Static so the
    /// copy is pinned without a SwiftUI host.
    static func notProtectedCaption(hadRestrictions: Bool) -> String {
        hadRestrictions
            ? "The redacted copy is not password-protected. It carries none of the original's usage restrictions."
            : "The redacted copy is not password-protected."
    }

    /// Keep Editing's spoken label: the action, then the undo boundary.
    static let keepEditingAccessibilityLabel =
        "Keep Editing. Return to the editor to adjust regions, then run Redact again. "
        + "Redact cleared undo; use Delete Region instead."

    // MARK: - Trust strip
    //
    // The shared trust line Home and the running screen draw, centred as
    // the page's last line: standing facts about the app, status-independent;
    // the run's outcome lives in the masthead. The running screen cross-fades
    // into this one in one frame, so both draw the same view at one weight.
    // No identifier: the running screen's own `verificationTrustLine` stays
    // the only one.

    private var trustStrip: some View {
        TrustLine()
            .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    /// The completion line, then the legal text as the last section's
    /// footer: 18 pt under the completion line; on SKIPPED, with no run to
    /// describe, 32 pt under the undo footnote.
    private var footerBlock: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Results.completionToLegal) {
            if Self.shouldShowRunBreakdown(report: report) {
                Text(Self.completionLineText(report: report))
                    .font(.footnote)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
            }
            if Self.shouldShowHonestyDisclaimer(overallStatus: report.overallStatus) {
                honestyDisclaimer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.top, Self.shouldShowRunBreakdown(report: report)
            ? ResectaTokens.Spacing.xs + ResectaTokens.Spacing.xxs
            : ResectaTokens.Results.undoToLegalSkipped)
    }

    /// The completion line: the duration (the ring states the count), the
    /// minutes form from 60 s; the page-count gate's report, where no check
    /// completed, says where it stopped.
    static func completionLineText(report: VerificationReport) -> String {
        if isPageCountGateRun(report) { return "Stopped at the Page Count check." }
        guard report.durationSeconds > 0 else {
            return report.layers.count == 1 ? "1 check." : "\(report.layers.count) checks."
        }
        return "Completed in \(durationText(report.durationSeconds))."
    }

    /// "under 0.1 seconds" · "4.1 seconds" · "5 min 12 s" (whole seconds,
    /// never "60 s").
    static func durationText(_ seconds: Double) -> String {
        if seconds < 0.1 { return "under 0.1 seconds" }
        if seconds < 60 { return String(format: "%.1f seconds", seconds) }
        return minutesText(seconds)
    }

    /// "5 min 12 s", from 60 s up; rounded to whole seconds.
    static func minutesText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return "\(total / 60) min \(total % 60) s"
    }

    // MARK: - Honesty disclaimer
    //
    // The legally reviewed scope-limitation copy (`HonestyDisclaimer`,
    // `.redacted` profile) mounts at ONE site on every verdict: the last
    // section's footer, under the completion line. The component supplies
    // its text and accessibility label; the call site owns the placement.

    /// Disclaimer mount gate. Deliberately true for EVERY verdict state —
    /// the exhaustive switch (no `default`) forces a decision here if a new
    /// status is ever added. Static so the all-statuses rule is
    /// unit-testable without a SwiftUI host (mirrors `shouldShowRunBreakdown`).
    static func shouldShowHonestyDisclaimer(
        overallStatus: VerificationStatus
    ) -> Bool {
        switch overallStatus {
        case .pass, .warn, .info, .attention, .fail, .skipped, .notApplicable: true
        }
    }

    private var honestyDisclaimer: some View {
        // The disclaimer's copy is markCount-independent (its switch binds
        // no value), so 0 stands in rather than threading a count the
        // component never reads.
        HonestyDisclaimer(profile: .redacted(markCount: 0), style: .sectionFooter)
            .accessibilityIdentifier("honestyDisclaimer")
    }
}

/// The blocks under the results screen's buttons, in one order both the
/// results view and the details section read.
nonisolated enum ResultsBlock: Equatable, Hashable, CaseIterable {
    /// The row about hand-drawn boxes on pages with no text.
    case handDrawnBoxes
    case findings
    /// The small print about what Checks Passed means (`ResultsScopeNote`).
    case smallPrint
    case warnings
    /// The card of facts about the PDF.
    case facts
    /// The row that opens the list of checks.
    case checksList

    /// On a run titled Checks Passed, the Findings group comes before the
    /// small print.
    static let findingsBeforeTheSmallPrint = true

    /// Top to bottom, the blocks present: the hand-drawn row; on a run
    /// titled Checks Passed the Findings group (when it comes first) and the
    /// small print; the Findings group otherwise; the warnings; the facts;
    /// the list of checks. Under any other title there is no small print.
    static func order(present: Set<ResultsBlock>, checksPassed: Bool,
                      findingsFirst: Bool = findingsBeforeTheSmallPrint) -> [ResultsBlock] {
        let early = checksPassed && findingsFirst
        var blocks: [ResultsBlock] = [.handDrawnBoxes]
        if early { blocks.append(.findings) }
        if checksPassed { blocks.append(.smallPrint) }
        if !early { blocks.append(.findings) }
        blocks += [.warnings, .facts, .checksList]
        return blocks.filter(present.contains)
    }

    /// Whether the small print is drawn directly after the Findings group,
    /// inside the details section.
    static func smallPrintFollowsFindings(_ order: [ResultsBlock]) -> Bool {
        guard let findings = order.firstIndex(of: .findings), let small = order.firstIndex(of: .smallPrint)
        else { return false }
        return small == findings + 1
    }
}
