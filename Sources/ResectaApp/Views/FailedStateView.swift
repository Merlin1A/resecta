import SwiftUI
import SafariServices
import RedactionEngine

// §A4h / E2: Dedicated error recovery view for .failed(error, returnPhase) phase.
// All copy uses mechanism-description language per ARCH §1.3.

struct FailedStateView: View {
    let error: PipelineError
    let returnPhase: DocumentState.ReturnPhase

    @Environment(DocumentState.self) private var documentState
    // STATE-6 (Pkg I): Start Over previously only walked the phase
    // back to .empty, leaving drawn regions and sourceDocument in
    // memory — a PII-in-memory regression. The action now mirrors
    // `VerificationActionBar` Done semantics: clear regions, drop the
    // sourceDocument reference, then transition. Pulling
    // RedactionState in here is the wiring for that.
    @Environment(RedactionState.self) private var redactionState
    // HISTORY: Start Over once skipped the SEC-1 session-close protection
    // downgrade — FailedStateView lacked coordinator access, so a failed
    // session's temp subtree stayed at `.complete`. The coordinator is
    // injected upstream at `RedactWorkspaceView` via
    // `.environment(workspace.coordinator)`; pull it and run the downgrade in
    // `performStartOver()`, mirroring `DocumentEditorView.performDoneCloseSession()`.
    @Environment(PipelineCoordinator.self) private var coordinator

    @State private var safariURL: URL?
    // STATE-6 (Pkg I): confirmation gates Start Over when drawn regions
    // are present, mirroring GATE-3 (Done in VerificationActionBar).
    // When no regions exist there is nothing to lose, so the dialog
    // would only add friction — Start Over runs directly in that case.
    @State private var showStartOverConfirmation = false

    // Start Over confirmation copy as the single
    // source of truth. Both the production `.confirmationDialog` below AND the
    // copy-pin banned-word sweep (FailedStateViewStartOverTests) reference
    // these, so a copy rename can no longer drift silently past the sweep.
    static let startOverTitle = "Start over?"
    // Parallel phrasing with the editor's Close confirm ("Drawn
    // regions and verification results will be cleared.") — the two
    // destructive-clear confirms speak one phrasing family.
    static let startOverMessage = "The document and drawn regions will be cleared."

    /// True when the session carries at least one drawn region.
    /// Mirrors the predicate in `VerificationActionBar`.
    private var hasDrawnRegions: Bool {
        redactionState.regions.values.contains { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: ResectaTokens.Spacing.lg) {
            Spacer()

            // Phase 3B: Error status card
            VStack(spacing: ResectaTokens.Spacing.md) {
                // Severity-appropriate SF Symbol
                Image(systemName: error.severitySymbol)
                    .font(.system(size: 56))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(error.severityColor)
                    .accessibilityHidden(true)

                // Headline
                Text(error.localizedTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                // Description (mechanism-description language)
                Text(error.localizedRecovery)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // Reassurance line — always shown (§A4h)
                Text("Your original file is unaffected.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            .padding(ResectaTokens.Spacing.lg)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(
                cornerRadius: ResectaTokens.CornerRadius.card, style: .continuous))
            .shadow(
                color: ResectaTokens.Shadow.subtle.color,
                radius: ResectaTokens.Shadow.subtle.radius,
                x: ResectaTokens.Shadow.subtle.x,
                y: ResectaTokens.Shadow.subtle.y
            )
            .accessibilityElement(children: .combine)

            Spacer()

            // Recovery buttons — outside the card (actions, not status)
            VStack(spacing: ResectaTokens.Spacing.sm) {
                // Primary: derived from the return phase AND the error's
                // recoverability (see `primaryAction(error:returnPhase:)`)
                Button(primaryButtonLabel) {
                    performPrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Secondary: return to empty (start fresh) — only when return phase isn't already .empty
                if case .empty = returnPhase {
                    // Already at empty — no "Start Over" button
                } else {
                    Button("Start Over") {
                        // STATE-6 (Pkg I): gate on confirmation when
                        // there is content to lose. No-regions path
                        // runs directly so the dialog doesn't add
                        // friction in the empty case.
                        if hasDrawnRegions {
                            showStartOverConfirmation = true
                        } else {
                            performStartOver()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("failedStateStartOverButton")
                }

                // Tertiary: report issue (GitHub deep link)
                // WU-46: routes via SafariView, matching the SettingsView
                // Support-section pattern. Reuses the shared `SettingsView.Links`
                // source of truth (the canonical org lives there) instead of a
                // second inline literal. R3 — networking runs in Safari's
                // process, not our binary.
                Button("Report an Issue") {
                    safariURL = SettingsView.Links.reportIssue
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, ResectaTokens.Spacing.xs)
            }
            .padding(.bottom, ResectaTokens.Spacing.xl)
        }
        .accessibilityIdentifier("failedState")
        .sheet(item: $safariURL) { url in
            SafariView(url: url)
                .ignoresSafeArea()
        }
        // STATE-6 (Pkg I): destructive-action confirmation symmetry.
        // Same shape as GATE-3 (Done) — copy describes the action
        // without an outcome promise (ARCH §1.3).
        .confirmationDialog(
            Self.startOverTitle,
            isPresented: $showStartOverConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Over", role: .destructive) {
                performStartOver()
            }
            .accessibilityIdentifier("failedStateStartOverConfirm")
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(Self.startOverMessage)
        }
    }

    // MARK: - Start Over

    /// STATE-6 (Pkg I): teardown for Start Over. Delegates to
    /// `DocumentState.resetForStartOver(redactionState:coordinator:)`
    /// so the whole teardown — the SEC-1 session-close downgrade, the
    /// PII-in-memory clears, and the `.empty` phase transition — is exercised
    /// by a unit test rather than an inline copy that no test could invoke.
    private func performStartOver() {
        documentState.resetForStartOver(redactionState: redactionState, coordinator: coordinator)
    }

    // MARK: - Primary Action

    /// The primary button's action shape. `Equatable` so tests pin the
    /// (error, returnPhase) → action matrix directly.
    enum PrimaryAction: Equatable {
        case reopenDocument      // retry-style: re-run the pipeline on the same document
        case chooseAnotherFile   // non-retry: back to the empty state
        case returnToEditor
        case returnToResults
    }

    /// Primary-action derivation, keyed on `PipelineError.isRecoverable`
    /// in addition to the return phase (previously the phase alone decided,
    /// and `isRecoverable` drove nothing in the app target). A retry-style
    /// primary is offered only when the error class supports retrying;
    /// non-recoverable errors keep the Choose Another File / Start Over
    /// paths. Carve-out: an import failure with an `.editing` return phase
    /// restores the PREVIOUS, still-loaded document (import-while-editing,
    /// ImportService.swift:141) — a go-back, not a retry — so it keeps
    /// "Return to Editor" for both recoverable and non-recoverable import
    /// failures. Static so the matrix is unit-testable without a SwiftUI
    /// host (mirrors `VerificationResultsView.shouldAutoExpand`).
    static func primaryAction(
        error: PipelineError,
        returnPhase: DocumentState.ReturnPhase
    ) -> PrimaryAction {
        switch returnPhase {
        case .empty:
            // KI-4 file-purge case. The `isRecoverable` conjunct pins the
            // retry-style label to the recoverability contract (filePurged
            // is recoverable today; the conjunct keeps that alignment
            // explicit rather than coincidental).
            if error.isRecoverable, case .exportError(.filePurged) = error {
                return .reopenDocument
            }
            return .chooseAnotherFile
        case .editing:
            // Import-while-editing go-back carve-out (see doc comment).
            if case .importError = error { return .returnToEditor }
            return error.isRecoverable ? .returnToEditor : .chooseAnotherFile
        case .verified:
            return error.isRecoverable ? .returnToResults : .chooseAnotherFile
        }
    }

    private var primaryButtonLabel: String {
        switch Self.primaryAction(error: error, returnPhase: returnPhase) {
        case .reopenDocument:    "Re-open Document"
        case .chooseAnotherFile: "Choose Another File"
        case .returnToEditor:    "Return to Editor"
        case .returnToResults:   "Return to Results"
        }
    }

    // MARK: - Transitions

    private func performPrimaryAction() {
        switch Self.primaryAction(error: error, returnPhase: returnPhase) {
        case .reopenDocument, .chooseAnotherFile:
            documentState.transition(to: .empty)
        case .returnToEditor:
            documentState.transition(to: .editing)
        case .returnToResults:
            // The action derivation only returns .returnToResults for a
            // .verified return phase, which carries the report.
            if case .verified(let report) = returnPhase {
                documentState.transition(to: .verified(report: report))
            }
        }
    }
}
