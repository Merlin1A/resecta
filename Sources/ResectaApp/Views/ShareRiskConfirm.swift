import SwiftUI
import RedactionEngine

// The share-risk confirm, moved out of `DocumentEditorView.swift` (the
// hub) along its `// MARK: - Share-risk confirm sheet` seam: the three
// pure predicates over a `VerificationReport` plus the caller's
// acknowledgement (`shareNeedsFailConfirm` · `shareNeedsSkippedConfirm` ·
// `shareNeedsIncompleteWarnConfirm`), the confirm copy, the completion
// function, the verdict value (`ShareRiskConfirmKind`), the presentation
// modifier, the sheet and the slide control. The hub keeps
// `handleExportTap` (the routing) and `beginExport` (the share sheet);
// the hub's `body` mounts `ShareRiskConfirmPresentation` as before.

extension DocumentEditorView {

    // MARK: - Share-risk predicates
    /// FAIL override / "Option B": a standing FAIL verdict (not yet
    /// user-overridden) means Share must route through a one-time "Share
    /// Anyway" confirmation before exporting — it no longer hard-blocks the
    /// Share card. Pure + `static` so the predicate is one source of truth and
    /// is unit-testable without a SwiftUI host (mirrors
    /// `VerificationResultsView.shareDisabled`).
    /// An ATTENTION verdict (un-redacted residual text) keeps the same
    /// one-time confirm: the tier re-class changes presentation, not the
    /// share-time acknowledgment. WARN and PASS stay confirm-free.
    /// `report` alone can no longer answer whether
    /// the confirm is needed — `report.userOverrodeFailure` is a write-only
    /// mirror now (see `DocumentState.failShareAcknowledged`), because a
    /// value that lived and died with the report couldn't be re-armed when
    /// the user backed out of the share sheet without sending.
    /// The predicate takes `acknowledged` as an explicit parameter instead,
    /// sourced at the call site from `DocumentState.failShareAcknowledged`
    /// — `acknowledged == true` makes the confirm a no-op for THIS send
    /// ("confirm once per attempt", not "once per report").
    static func shareNeedsFailConfirm(report: VerificationReport, acknowledged: Bool) -> Bool {
        (report.overallStatus.isFail || report.overallStatus.isAttention)
            && !acknowledged
    }

    /// Skipped-share confirm predicate: a SKIPPED report (verification never
    /// ran — any skip reason) not yet acknowledged for sharing routes the
    /// Share tap through a one-time confirm before exporting. Same shape as
    /// `shareNeedsFailConfirm(report:acknowledged:)`: pure + `static` so it
    /// is unit-testable without a SwiftUI host, and the acknowledgement
    /// conjunct makes it one-time per attempt. WARN and PASS deliberately
    /// stay confirm-free. `acknowledged` is sourced at the call site
    /// from `DocumentState.skippedShareAcknowledged` — see
    /// `shareNeedsFailConfirm(report:acknowledged:)`'s doc comment for why
    /// the report's own `userAcknowledgedSkippedShare` is a write-only
    /// mirror rather than the read source now.
    static func shareNeedsSkippedConfirm(report: VerificationReport, acknowledged: Bool) -> Bool {
        report.overallStatus.isSkipped && !acknowledged
    }

    /// Incomplete-WARN share-risk confirm predicate. Two WARN shapes take
    /// this confirm, both meaning a check did not run in full on the output:
    /// the digest-less verify-only degrade — zero real WARN layers but at
    /// least one SKIPPED layer, deliberately the exact gate of
    /// `VerificationResultsView.mastheadSubtitle`'s "Completed with N of M
    /// checks skipped — results may be incomplete." branch — and a WARN
    /// whose layers include a could-not-verify WARN
    /// (`CouldNotVerifyWarn.matches`). Either way the confirm sheet reuses
    /// the masthead's own sentence — no new string — and for the second
    /// shape lists the reporting checks under the existing list header. A
    /// WARN made only of routine notes (a structural or metadata note, a
    /// positional graze, an attestation mismatch) stays confirm-free.
    /// `report` alone can't carry the acknowledgement (`VerificationReport`
    /// lives in the fenced Packages/RedactionEngine), so unlike its two
    /// siblings this predicate takes `acknowledged` as an explicit
    /// parameter, sourced at the call site from
    /// `DocumentState.incompleteWarnShareAcknowledged`. Pure + `static` for
    /// the same testability reason as the two siblings.
    static func shareNeedsIncompleteWarnConfirm(
        report: VerificationReport, acknowledged: Bool
    ) -> Bool {
        guard report.overallStatus.isWarn, !acknowledged else { return false }
        let warnCount = report.layers.filter(\.status.isWarn).count
        let skippedCount = report.layers.filter(\.status.isSkipped).count
        if warnCount == 0 && skippedCount > 0 { return true }
        return report.layers.contains(where: CouldNotVerifyWarn.matches)
    }

    /// Title for the bespoke share-risk confirm sheet. One title
    /// across all three confirm families (FAIL/ATTENTION, SKIPPED,
    /// incomplete-WARN); only one title is approved copy, and
    /// re-scoping a second one is out of the sprint's timeline.
    static let shareRiskConfirmTitle = "Share with reported issues?"

    /// List header shown above the item list — the FAIL/ATTENTION confirm
    /// family, and the incomplete-WARN family when could-not-verify layers
    /// report (`couldNotVerifyItemLines`).
    static let shareRiskConfirmListHeader = "The verification check reported:"

    /// At-risk item lines for the FAIL/ATTENTION confirm family: every
    /// failed- or attention-flagged layer's `shortDescription` — already
    /// content-free (page numbers / key names only, never
    /// matched text). Replaces the retired `shareAnywayConfirmMessage`,
    /// which quoted only the aggregate's first failing layer; this lists
    /// every at-risk layer. Static so the derivation is unit-testable
    /// without a SwiftUI host.
    static func atRiskItemLines(report: VerificationReport) -> [String] {
        report.layers
            .filter { $0.status.isFail || $0.status.isAttention }
            .map(\.shortDescription)
    }

    /// Item lines for the incomplete-WARN confirm family: every
    /// could-not-verify WARN layer's `shortDescription`
    /// (`CouldNotVerifyWarn.matches`), content-free by the same construction
    /// as `atRiskItemLines`. Empty for the all-skipped degrade, whose
    /// masthead sentence already names the skips. Static so the derivation
    /// is unit-testable without a SwiftUI host.
    static func couldNotVerifyItemLines(report: VerificationReport) -> [String] {
        report.layers
            .filter(CouldNotVerifyWarn.matches)
            .map(\.shortDescription)
    }

    /// Skip-fact line for the SKIPPED confirm family. A new string — the
    /// former `.alert`-era `shareSkippedConfirmMessage` named both the fact
    /// and the two choices in one sentence; the sheet draws the choices as
    /// the slide control + Go back, so this line names only the fact.
    static let shareRiskConfirmSkipFactLine =
        "Verification did not run on this output."

    /// Deselected-items fact line for the confirm sheet, singular/plural.
    /// Distinct from `VerificationResultsView.deselectionRowText(deselected:
    /// total:)` — different wording ("flagged" not "detected", no "of M"
    /// total) for a different surface. Static so the copy is pinned exactly.
    static func deselectedItemsConfirmLine(count: Int) -> String {
        count == 1
            ? "1 flagged item was deselected before redaction."
            : "\(count) flagged items were deselected before redaction."
    }

    /// Engagement-control completion label (the slide track's
    /// visible + accessible text).
    static let shareRiskConfirmSlideLabel = "Slide to share anyway"

    /// Test seam: overridable in tests to assert the confirm's haptic fired
    /// without CoreHaptics/hardware (mirrors the "Test seam:" convention
    /// already used elsewhere, e.g. PipelineCoordinator's replay-order
    /// hooks). `playExportConfirmation()` is a minimal revival —
    /// see ResectaTokens.swift.
    static var shareRiskConfirmHaptic: () -> Void = {
        ResectaTokens.Haptics.playExportConfirmation()
    }

    /// Confirm-sheet completion. Records the acknowledgement for
    /// whichever family presented (routes through the same three
    /// DocumentState methods the old two `.alert`s used, plus the new
    /// third), fires the haptic seam once, then re-reads `documentState
    /// .phase` for the live report and exports it — re-reading rather than
    /// trusting `kind`'s captured report mirrors the former `.alert`
    /// actions' lifecycle (a phase change racing the presented sheet is
    /// possible in principle; the re-read is the same defense they used).
    /// A plain `static` function with explicit dependencies (no SwiftUI
    /// coupling) so a unit test can call it directly and assert on
    /// `documentState`, the haptic spy, and the `beginExport` spy.
    static func completeShareRiskConfirm(
        kind: ShareRiskConfirmKind,
        documentState: DocumentState,
        beginExport: (VerificationReport) -> Void
    ) {
        switch kind {
        case .failOrAttention:
            documentState.overrideVerificationFailure()
        case .skipped:
            documentState.acknowledgeSkippedShare()
        case .incompleteWarn:
            documentState.acknowledgeIncompleteWarnShare()
        }
        shareRiskConfirmHaptic()
        if case .verified(let report) = documentState.phase {
            beginExport(report)
        }
    }
}

// MARK: - Share-risk confirm sheet

/// The three families of confirm that route through the bespoke share-risk
/// confirm sheet, each carrying the report that triggered it (for display —
/// `completeShareRiskConfirm` re-reads `documentState.phase` for the actual
/// export, not this captured value). Mutually exclusive by construction:
/// `handleExportTap` sets at most one, gated by `overallStatus`, which can
/// never simultaneously satisfy more than one of the three predicates.
enum ShareRiskConfirmKind: Identifiable {
    /// FAIL override / "Option B", widened to ATTENTION (the residual
    /// tier — the tier re-class changes presentation, not the
    /// share-time acknowledgment).
    case failOrAttention(VerificationReport)
    /// Verification never ran (any `SkipReason`).
    case skipped(VerificationReport)
    /// WARN whose digest-dependent layers were skipped, or whose layers
    /// include a could-not-verify WARN (`CouldNotVerifyWarn`).
    case incompleteWarn(VerificationReport)

    var id: String {
        switch self {
        case .failOrAttention: "failOrAttention"
        case .skipped: "skipped"
        case .incompleteWarn: "incompleteWarn"
        }
    }

    /// The captured report, for display derivation.
    var report: VerificationReport {
        switch self {
        case .failOrAttention(let r), .skipped(let r), .incompleteWarn(let r): r
        }
    }

    /// Accessibility identifier of the element that completes the share —
    /// the hidden-but-accessible Button inside `SlideToShareControl`.
    /// `shareAnywayConfirm` / `shareSkippedConfirm` are the former
    /// `.alert` Share buttons' identifiers, kept stable across the
    /// alert→sheet restructure; `shareIncompleteWarnConfirm` is new.
    var accessibilityIdentifier: String {
        switch self {
        case .failOrAttention: "shareAnywayConfirm"
        case .skipped: "shareSkippedConfirm"
        case .incompleteWarn: "shareIncompleteWarnConfirm"
        }
    }

    /// The lines the confirm sheet lists under
    /// `DocumentEditorView.shareRiskConfirmListHeader`: the at-risk layers
    /// for FAIL/ATTENTION, the could-not-verify layers for incomplete-WARN,
    /// none for SKIPPED (its fact line stands alone). A pure derivation from
    /// the captured report so the sheet's composition is unit-testable
    /// without a SwiftUI host.
    var itemLines: [String] {
        switch self {
        case .failOrAttention(let report):
            DocumentEditorView.atRiskItemLines(report: report)
        case .incompleteWarn(let report):
            DocumentEditorView.couldNotVerifyItemLines(report: report)
        case .skipped:
            []
        }
    }
}

/// The bespoke share-risk confirm sheet, extracted from DocumentEditorView
/// .body so its modifier chain stays within the type-checker's expression
/// budget (mirrors the former two-.alert `ShareConfirmAlerts` this
/// replaces).
///
/// Replaces the former text-variant system `.alert`s for
/// FAIL/ATTENTION and SKIPPED, and adds the third incomplete-WARN family,
/// with one content-engaging step: the confirm
/// names the specific at-risk items and requires a swipe-class engagement
/// (never type-to-confirm) rather than a single default-focused alert
/// button. "Slide to share anyway" records the acknowledgement on
/// `documentState` (`completeShareRiskConfirm`), fires the restored
/// `playExportConfirmation()` haptic once, then re-reads the live report
/// and exports it — same post-share lifecycle the former `.alert` Share
/// actions used (02-FIX "Change set 2").
struct ShareRiskConfirmPresentation: ViewModifier {
    @Binding var kind: ShareRiskConfirmKind?
    let documentState: DocumentState
    let deselectionSnapshot: RedactionState.DeselectionSnapshot?
    let beginExport: (VerificationReport) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $kind) { activeKind in
                ShareRiskConfirmSheet(
                    kind: activeKind,
                    deselectionSnapshot: deselectionSnapshot,
                    onConfirm: {
                        DocumentEditorView.completeShareRiskConfirm(
                            kind: activeKind,
                            documentState: documentState,
                            beginExport: beginExport
                        )
                        kind = nil
                    },
                    onCancel: { kind = nil }
                )
                .presentationDetents([.medium])
            }
    }
}

/// Confirm-sheet content. Title is shared across all three families;
/// body content is family-specific. The deselected-items line
/// is cross-cutting — it renders whenever `shouldShowDeselectionRow` is
/// true, regardless of which family presented.
struct ShareRiskConfirmSheet: View {
    let kind: ShareRiskConfirmKind
    let deselectionSnapshot: RedactionState.DeselectionSnapshot?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var atRiskItems: [String] { kind.itemLines }

    /// The list header + one `Label` line per item — the FAIL/ATTENTION
    /// arm's list, shared with the incomplete-WARN arm when could-not-verify
    /// layers report.
    @ViewBuilder
    private var itemList: some View {
        Text(DocumentEditorView.shareRiskConfirmListHeader)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        ForEach(Array(atRiskItems.enumerated()), id: \.offset) { _, line in
            Label {
                Text(line).font(.subheadline)
            } icon: {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.lg) {
            Text(DocumentEditorView.shareRiskConfirmTitle)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            // The item list can in principle be long (many failed/attention
            // layers); the slide track below must never sit inside this (or
            // any) ScrollView — a SwiftUI DragGesture inside a ScrollView
            // kills the ScrollView's own scroll.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
                    switch kind {
                    case .failOrAttention:
                        itemList
                    case .skipped:
                        Text(DocumentEditorView.shareRiskConfirmSkipFactLine)
                            .font(.subheadline)
                    case .incompleteWarn(let report):
                        // Reuse the masthead's own WARN sentence verbatim —
                        // no new string. The helper is optional only for
                        // PASS (title-only masthead); a WARN report always
                        // carries a line. When could-not-verify layers
                        // report, the checks are listed beneath it in the
                        // FAIL/ATTENTION arm's own list shape.
                        if let line = VerificationResultsView.mastheadSubtitle(report: report) {
                            Text(line)
                                .font(.subheadline)
                        }
                        if !atRiskItems.isEmpty {
                            itemList
                        }
                    }

                    if VerificationResultsView.shouldShowDeselectionRow(
                        snapshot: deselectionSnapshot),
                       let snapshot = deselectionSnapshot {
                        Text(DocumentEditorView.deselectedItemsConfirmLine(
                            count: snapshot.deselectedCount))
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            // Footer: plain VStack, never a ScrollView — see the comment
            // above the item-list ScrollView.
            VStack(spacing: ResectaTokens.Spacing.md) {
                SlideToShareControl(
                    label: DocumentEditorView.shareRiskConfirmSlideLabel,
                    accessibilityIdentifier: kind.accessibilityIdentifier,
                    onComplete: onConfirm
                )
                Button("Go back", action: onCancel)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("shareRiskConfirmGoBack")
            }
        }
        .padding(ResectaTokens.Spacing.lg)
    }
}

/// Engagement control: a swipe-class, cheap-but-physical slide track
/// (never type-to-confirm). The visible track is the touch
/// path; a hidden-but-accessible `Button` overlaid at a single point off
/// the track's hit area carries the family's stable accessibility
/// identifier and is the VoiceOver / XCUI completion path — VoiceOver
/// activation and XCUITest's `.tap()` both reach a Button directly, where
/// neither can replay a physical drag.
struct SlideToShareControl: View {
    let label: String
    let accessibilityIdentifier: String
    let onComplete: () -> Void

    @State private var dragX: CGFloat = 0
    @State private var trackWidth: CGFloat = 0
    @State private var completed = false

    private let knobDiameter: CGFloat = 44

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.15))
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Circle()
                .fill(Color.accentColor)
                .frame(width: knobDiameter, height: knobDiameter)
                .overlay {
                    Image(systemName: "chevron.right.2")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .offset(x: dragX)
                .gesture(dragGesture)
        }
        .frame(height: knobDiameter)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { trackWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newValue in trackWidth = newValue }
            }
        )
        .accessibilityHidden(true)
        // The completion Button is sized to
        // `ResectaTokens.TouchTarget.minimum` — a real touch target, not
        // a 1×1 point — because the 1×1 target proved unreliable for a
        // coordinate-driven activation (XCUITest's `.tap()` on a
        // re-presented sheet; the same reasoning covers Switch Control
        // and a pointer click). It stays out of sight by placement, not
        // by size: anchored to this view's own bottom-leading corner and
        // pushed further down still, clear of the footer's "Go back"
        // row, so it lands beneath that row rather than inside the
        // knob's sweep band (which stays within this view's own height
        // as it drags) or the "Go back" pill itself (centered, well
        // short of the row's full width, leaving the space beside and
        // below it open). No sighted tap lands where this sits.
        .overlay(alignment: .bottomLeading) {
            Button(label, action: complete)
                .frame(
                    width: ResectaTokens.TouchTarget.minimum,
                    height: ResectaTokens.TouchTarget.minimum
                )
                .contentShape(Rectangle())
                .opacity(0.02)
                .offset(y: ResectaTokens.TouchTarget.minimum
                    + ResectaTokens.Spacing.md
                    + 34) // clears the "Go back" row
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !completed, trackWidth > knobDiameter else { return }
                let maxX = trackWidth - knobDiameter
                dragX = min(max(0, value.translation.width), maxX)
            }
            .onEnded { _ in
                guard !completed, trackWidth > knobDiameter else { return }
                let maxX = trackWidth - knobDiameter
                if dragX >= maxX * 0.9 {
                    dragX = maxX
                    complete()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        dragX = 0
                    }
                }
            }
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        onComplete()
    }
}
