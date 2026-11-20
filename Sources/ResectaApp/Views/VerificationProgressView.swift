import SwiftUI
import RedactionEngine

// While the checks run: one grey ring where the results will show theirs,
// with the number of results published so far; the title; one line with
// the system's small spinner; and the trust line in the flow below. The
// results fade in with their ring in the same place: this screen is laid
// out as the results screen is (`VerificationResultsView.body`), so the
// two rings share one frame. Stop is in the bar, not in this view.

struct VerificationProgressView: View {
    @Environment(DocumentState.self) private var documentState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AccessibilityFocusState private var blockFocused: Bool

    /// How often the line and the long-run line are read again: the line
    /// names a check half a second after it is announced.
    static let tick: TimeInterval = 0.25

    /// Reads pipelineProgress for all display data. Only pipelineProgress changes
    /// on verification layer ticks, so this view re-evaluates independently of the
    /// parent DocumentEditorView body.
    var body: some View {
        let progress = documentState.pipelineProgress
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                GeometryReader { geometry in
                    ScrollView(.vertical, showsIndicators: false) {
                        TimelineView(.periodic(from: .now, by: Self.tick)) { context in
                            let state = Self.state(progress, now: context.date)
                            let longRun = Self.showsLongRunLine(progress, now: context.date)
                            VStack(spacing: 0) {
                                block(state, longRun: longRun)
                                // The trust line follows the block in the
                                // flow, never over it: near the foot when
                                // there is room, pushed down when the text
                                // grows.
                                Spacer(minLength: ResectaTokens.Results.blockGap)
                                TrustLine()
                                    .accessibilityIdentifier("verificationTrustLine")
                            }
                            .onChange(of: Self.stillCheckingDue(progress, now: context.date)) { _, due in
                                guard due != nil else { return }
                                AccessibilityNotification.Announcement(
                                    VerificationProgressLine.stillChecking(finished: state.finished, total: state.total)
                                ).post()
                            }
                        }
                        .padding(.horizontal, ResectaTokens.Spacing.md)
                        .padding(.top, ResectaTokens.Spacing.lg)
                        .padding(.bottom, ResectaTokens.Spacing.lg)
                        .frame(maxWidth: columnMaxWidth)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    }
                }
            }
        }
        .accessibilityIdentifier("verificationProgress")
        .onAppear { blockFocused = true }
    }

    // MARK: - The block

    /// The ring, the title, the line and, on a long run, its second line:
    /// one header element for VoiceOver, its label from shipped words.
    private func block(_ state: VerificationProgressLine, longRun: Bool) -> some View {
        VStack(spacing: 0) {
            CountRing(content: .running(finished: state.finished, total: state.total))
            BalancedText(string: "Verification In Progress", font: .title.bold())
                .foregroundStyle(.primary)
                .padding(.top, ResectaTokens.Results.ringToTitle)
            HStack(alignment: .firstTextBaseline, spacing: ResectaTokens.Spacing.xs) {
                // The spinner stays on the line's first line when it wraps.
                ProgressView()
                    .controlSize(.small)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(VerificationProgressLine.text(state.line))
                    .font(.subheadline)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: ResectaTokens.Results.sentenceMaxWidth)
            .padding(.top, ResectaTokens.Results.titleToSentence)
            if longRun {
                Text(VerificationProgressLine.longRunLine)
                    .font(.footnote)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: ResectaTokens.Results.sentenceMaxWidth)
                    .padding(.top, ResectaTokens.Spacing.sm)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(state, longRun: longRun))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("verificationBanner")
        .accessibilityFocused($blockFocused)
    }

    // MARK: - The rules read from the progress

    /// The figure and the line at `now`.
    static func state(_ progress: DocumentState.PipelineProgress?, now: Date) -> VerificationProgressLine {
        let running = progress?.running
        return VerificationProgressLine.make(
            finished: progress?.completedLayers.count ?? 0, total: progress?.total ?? 0,
            running: running?.layer, runningOpensGroup: running?.opensGroup ?? false,
            secondsRunning: running.map { now.timeIntervalSince($0.since) } ?? 0,
            typedSearchApplied: progress?.typedSearchApplied ?? false)
    }

    /// The long-run line shows from `longRunDelay` after the checks began.
    static func showsLongRunLine(_ progress: DocumentState.PipelineProgress?, now: Date) -> Bool {
        guard let began = progress?.checksBegan else { return false }
        return now.timeIntervalSince(began) >= VerificationProgressLine.longRunDelay
    }

    /// The change the spoken reminder is due for: the last change, once
    /// nothing has changed for `stillCheckingDelay`; nil before.
    static func stillCheckingDue(_ progress: DocumentState.PipelineProgress?, now: Date) -> Date? {
        guard let last = progress?.lastChange,
              now.timeIntervalSince(last) >= VerificationProgressLine.stillCheckingDelay else { return nil }
        return last
    }

    /// "Verification In Progress. 5 of 14 checks completed. Checking."
    static func spokenLabel(_ state: VerificationProgressLine, longRun: Bool) -> String {
        var parts = ["Verification In Progress."]
        if state.total > 0 { parts.append("\(state.finished) of \(state.total) checks completed.") }
        parts.append(VerificationProgressLine.spoken(state.line))
        if longRun { parts.append(VerificationProgressLine.longRunLine) }
        return parts.joined(separator: " ")
    }

    // MARK: - Layout helpers

    /// Mirrors `HomeView.columnMaxWidth` (HomeView's `columnMaxWidth`) and
    /// `VerificationResultsView.columnMaxWidth`. Lifted to a static helper
    /// so the gate is testable without a SwiftUI host (mirrors
    /// `shouldAutoReturnHome` and `shouldAutoExpand`).
    private var columnMaxWidth: CGFloat {
        Self.columnMaxWidth(for: horizontalSizeClass)
    }

    static func columnMaxWidth(
        for horizontalSizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        horizontalSizeClass == .regular
            ? ResectaTokens.BrandedSurface.panelMaxWidthRegular
            : ResectaTokens.BrandedSurface.panelMaxWidthCompact
    }
}
