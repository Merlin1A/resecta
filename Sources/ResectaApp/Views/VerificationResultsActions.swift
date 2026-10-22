import SwiftUI
import RedactionEngine

// The results page's actions: Share as a 50-pt capsule (filled, or
// outlined under a filled Keep Editing when a check failed or needs
// review, or grey when it cannot share), the disabled reason under it, the
// action rows (Run Verification on a skipped report, Keep Editing, Preview)
// and the undo footnote. ONE Share `Button` in either style carries
// `onExport`, ⌘E and the disabled gate; it speaks a hint exactly when
// tapping it opens a confirm.

struct VerificationResultsActions: View {
    let report: VerificationReport
    let canExport: Bool
    let outputExists: Bool
    let isVerificationStale: Bool
    let previewAvailable: Bool
    var onExport: () -> Void
    var onRunVerification: () -> Void

    @Environment(DocumentState.self) private var documentState

    var body: some View {
        let shareDisabled = VerificationResultsView.shareDisabled(canExport: canExport)
        let swapped = Self.swapsPrimaryAction(report: report, shareDisabled: shareDisabled)
        let rows = Self.actionRows(report: report, outputExists: outputExists,
                                   previewAvailable: previewAvailable, swapped: swapped)
        VStack(spacing: 0) {
            VStack(spacing: ResectaTokens.Results.capsuleGap) {
                if swapped {
                    keepEditingCapsule
                }
                shareCapsule(swapped: swapped)
            }
            reasonAndCaption(shareDisabled: shareDisabled)
            if rows.isEmpty {
                undoFootnote
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, ResectaTokens.Spacing.md)
            } else {
                GroupedSection {
                    ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                        if index > 0 { GroupedRowDivider() }
                        actionRow(row)
                    }
                }
                .padding(.top, ResectaTokens.Results.blockGap)
                undoFootnote
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ResectaTokens.Spacing.md)
                    .padding(.top, ResectaTokens.Spacing.xs + ResectaTokens.Spacing.xxs)
            }
        }
    }

    // MARK: - The capsules

    private func shareCapsule(swapped: Bool) -> some View {
        Button(action: onExport) {
            Label("Share Document", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(ResultsCapsuleButtonStyle(kind: Self.shareCapsuleKind(report: report, swapped: swapped)))
        .disabled(VerificationResultsView.shareDisabled(canExport: canExport))
        .keyboardShortcut("e", modifiers: .command)
        .accessibilityLabel(VerificationResultsView.shareCardAccessibilityLabel)
        .accessibilityHint(shareWillConfirm ? Self.shareConfirmHint : "")
    }

    private var keepEditingCapsule: some View {
        Button { documentState.transition(to: .editing) } label: {
            Label("Keep Editing", systemImage: "pencil.and.outline")
        }
        .buttonStyle(ResultsCapsuleButtonStyle(kind: .filled(.teal)))
        .modifier(KeepEditingAccessibility())
    }

    /// The disabled reason 8 pt under Share, then the encrypted source's
    /// caption.
    @ViewBuilder
    private func reasonAndCaption(shareDisabled: Bool) -> some View {
        if shareDisabled, let reason = VerificationResultsView.shareDisabledReason(
            outputExists: outputExists, isStale: isVerificationStale) {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ResectaTokens.Spacing.md)
                .padding(.top, ResectaTokens.Results.reasonGap)
                .accessibilityIdentifier("shareDisabledReason")
        }
        // The source was encrypted: say what the redacted copy carries, at
        // the moment the user decides to share it.
        if documentState.sourceFacts.wasEncrypted {
            Text(VerificationResultsView.notProtectedCaption(
                hadRestrictions: documentState.sourceFacts.hadRestrictions))
                .font(.footnote)
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ResectaTokens.Spacing.md)
                .padding(.top, ResectaTokens.Results.reasonGap)
                .accessibilityIdentifier("shareNotProtectedCaption")
        }
    }

    private var undoFootnote: some View {
        Text(VerificationResultsView.undoFootnote)
            .font(.footnote)
            .foregroundStyle(ResectaTokens.SemanticColor.supportText)
    }

    // MARK: - The rows

    @ViewBuilder
    private func actionRow(_ row: ActionRow) -> some View {
        switch row {
        case .runVerification:
            Button(action: onRunVerification) {
                ResultsActionRow(symbol: "checkmark.shield", title: "Run Verification")
            }
            .buttonStyle(ResultsRowButtonStyle())
            .accessibilityLabel("Run Verification. \(VerificationResultsView.runVerificationCardBodyText)")
            .accessibilityIdentifier("runVerificationCard")
        case .keepEditing:
            Button { documentState.transition(to: .editing) } label: {
                ResultsActionRow(symbol: "pencil.and.outline", title: "Keep Editing")
            }
            .buttonStyle(ResultsRowButtonStyle())
            .modifier(KeepEditingAccessibility())
        case .preview:
            // The destination resolves against the results view's own
            // NavigationStack (DocumentEditorView hosts no stack).
            NavigationLink {
                RedactedPreviewView(verdict: report.overallStatus)
            } label: {
                ResultsActionRow(symbol: "eye", title: "Preview Redacted Document",
                                 subtitle: "Read-only view of the redacted PDF")
            }
            .buttonStyle(ResultsRowButtonStyle())
            .accessibilityLabel(VerificationResultsView.previewCardAccessibilityLabel)
        }
    }

    private var shareWillConfirm: Bool {
        Self.shareWillConfirm(
            report: report, canExport: canExport,
            failAcknowledged: documentState.failShareAcknowledged,
            skippedAcknowledged: documentState.skippedShareAcknowledged,
            incompleteWarnAcknowledged: documentState.incompleteWarnShareAcknowledged)
    }

    // MARK: - The rules (static, so the tests read them without a host)

    /// The rows under the capsules, in order.
    enum ActionRow: Hashable { case runVerification, keepEditing, preview }

    /// Keep Editing leads, filled, when a check failed or needs review, or
    /// when Share cannot share.
    static func swapsPrimaryAction(report: VerificationReport, shareDisabled: Bool) -> Bool {
        shareDisabled || report.overallStatus.isFail || report.overallStatus.isAttention
    }

    /// Share's capsule: filled teal; outlined red on FAIL and pink on
    /// ATTENTION under the filled Keep Editing. A disabled capsule is grey
    /// in either shape — the style reads `isEnabled`.
    static func shareCapsuleKind(report: VerificationReport, swapped: Bool) -> ResultsCapsuleButtonStyle.Kind {
        guard swapped else { return .filled(.teal) }
        if report.overallStatus.isFail { return .outlined(.red) }
        if report.overallStatus.isAttention { return .outlined(.pink) }
        return .outlined(.teal)
    }

    /// The action rows: Run Verification on a skipped report while its
    /// output exists, Keep Editing unless it leads as a capsule, Preview
    /// while the output exists. Empty rows omit the card.
    static func actionRows(report: VerificationReport, outputExists: Bool,
                           previewAvailable: Bool, swapped: Bool) -> [ActionRow] {
        var rows: [ActionRow] = []
        if report.overallStatus.isSkipped, outputExists { rows.append(.runVerification) }
        if !swapped { rows.append(.keepEditing) }
        if previewAvailable { rows.append(.preview) }
        return rows
    }

    /// The Share hint: spoken only, exactly when tapping Share opens a
    /// confirm. It reads the live confirm predicates with their
    /// acknowledgements — never the rows — so after a completed share,
    /// whose acknowledgement stays spent, no hint promises a confirm.
    static let shareConfirmHint = "Asks you to confirm before sharing."

    /// Whether Share will ask for confirmation: Share is enabled and one of
    /// the three confirm families is armed.
    static func shareWillConfirm(
        report: VerificationReport, canExport: Bool,
        failAcknowledged: Bool, skippedAcknowledged: Bool, incompleteWarnAcknowledged: Bool
    ) -> Bool {
        canExport && (
            DocumentEditorView.shareNeedsFailConfirm(report: report, acknowledged: failAcknowledged)
            || DocumentEditorView.shareNeedsSkippedConfirm(report: report, acknowledged: skippedAcknowledged)
            || DocumentEditorView.shareNeedsIncompleteWarnConfirm(
                report: report, acknowledged: incompleteWarnAcknowledged))
    }
}

/// Keep Editing, as the leading capsule or as a row (never both): the
/// spoken label carries the undo boundary.
private struct KeepEditingAccessibility: ViewModifier {
    func body(content: Content) -> some View {
        content
            .accessibilityLabel(VerificationResultsView.keepEditingAccessibilityLabel)
            .accessibilityIdentifier("keepEditingAction")
    }
}

// MARK: - The capsule and row styles

/// The 50-pt action capsule. It reads `isEnabled`: a disabled capsule is
/// the grey fill with the tertiary label in either shape, no stroke, no
/// press effect.
struct ResultsCapsuleButtonStyle: ButtonStyle {
    enum Tint: Equatable { case teal, red, pink }
    enum Kind: Equatable { case filled(Tint), outlined(Tint) }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        CapsuleBody(configuration: configuration, kind: kind)
    }

    private struct CapsuleBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: ResectaTokens.Results.capsuleHeight)
                .background(background, in: Capsule())
                .overlay {
                    if case .outlined(let tint) = kind, isEnabled {
                        Capsule().strokeBorder(Self.text(tint), lineWidth: ResectaTokens.Results.capsuleStroke)
                    }
                }
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
                .opacity(configuration.isPressed && isEnabled ? 0.85 : 1)
        }

        private var foreground: Color {
            guard isEnabled else { return Color(.tertiaryLabel) }
            switch kind {
            case .filled: return .white
            case .outlined(let tint): return Self.text(tint)
            }
        }

        private var background: Color {
            guard isEnabled else { return Color(.tertiarySystemFill) }
            switch kind {
            case .filled(let tint): return Self.fill(tint)
            case .outlined: return .clear
            }
        }

        static func fill(_ tint: Tint) -> Color {
            switch tint {
            case .teal: ResectaTokens.BrandTeal.fill
            case .red: .red
            case .pink: .pink
            }
        }

        static func text(_ tint: Tint) -> Color {
            switch tint {
            case .teal: ResectaTokens.BrandTeal.text
            case .red: ResectaTokens.SemanticColor.failText
            case .pink: ResectaTokens.SemanticColor.attentionText
            }
        }
    }
}

/// A row's press wash inside a grouped section.
struct ResultsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemFill) : .clear)
    }
}

/// A Settings-style action row: a 28-pt teal tile, the title (and an
/// optional subtitle), a chevron.
struct ResultsActionRow: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: ResectaTokens.Spacing.sm + ResectaTokens.Spacing.xs) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(ResectaTokens.BrandTeal.text)
                .frame(width: ResectaTokens.Results.actionTile, height: ResectaTokens.Results.actionTile)
                .background(
                    ResectaTokens.BrandTeal.tint.opacity(colorScheme == .dark
                        ? ResectaTokens.Opacity.tileWashDark : ResectaTokens.Opacity.tileWashLight),
                    in: RoundedRectangle(cornerRadius: ResectaTokens.Results.actionTileRadius, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: ResectaTokens.Results.chevronColumn)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Results.rowVerticalPadding)
        .frame(minHeight: ResectaTokens.Results.rowMinHeight)
        .contentShape(Rectangle())
    }
}
