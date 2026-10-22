import SwiftUI
import RedactionEngine

// The password sheet for a locked document. Presented by
// `RedactWorkspaceView` over the failed state a locked import leaves, from
// `RedactWorkspace.lockedImport`; the hold carries the document's bytes and
// the attempts so far. The field is a plain secure field: no content type
// (it asks the system for no AutoFill; whether iOS offers to save a typed
// secure value is the system's own behaviour, and the copy says so), no
// autocorrection, no capitalisation; the typed value is copied to the session's holder on
// success and the binding is emptied on every exit. The outcome of a
// submitted password is derived by `ImportPasswordFlow`, pure and testable
// without a host.

/// What the sheet does with the outcome of a submitted password.
enum ImportPasswordFlow {

    /// The sheet's next state after an attempt.
    enum Step: Equatable {
        /// The document opened; the hold is released and the sheet dismisses.
        case opened
        /// The password did not unlock it; the hold stays, the field empties.
        case wrongPassword(LockedImportHold)
        /// The password unlocked it, but the document could not be read in
        /// full: the terminal line; OK releases the hold.
        case cannotOpen(LockedImportHold)
        /// The document was refused for a reason of its own (too large, a
        /// page's dimensions, active content, its geometry): the hold is
        /// released and the ordinary failed card shows.
        case refusedForAnotherReason
    }

    /// Derive the next step from the import's outcome and, on a refusal,
    /// the failed phase's error.
    static func step(after outcome: ImportOutcome, phaseError: PipelineError?, hold: LockedImportHold) -> Step {
        switch outcome {
        case .completed:
            return .opened
        case .needsPassword:
            var next = hold
            next.attempts += 1
            next.lastOutcome = .wrongPassword
            return .wrongPassword(next)
        case .refused:
            // The first pass reached `.passwordProtected`, so a `.corrupt` on
            // the re-run means the password unlocked the document and a
            // later stage could not read it in full.
            if case .importError(.corrupt) = phaseError {
                var next = hold
                next.lastOutcome = .cannotOpen
                return .cannotOpen(next)
            }
            return .refusedForAnotherReason
        }
    }

    /// From the third wrong attempt the hint about certificate-protected
    /// documents shows beneath the wrong-password line.
    static func showsCertificateHint(attempts: Int) -> Bool { attempts >= 3 }

    /// The phase Cancel (and the terminal OK) returns to: the same transition
    /// the failed card's primary action derives for a password refusal.
    static func cancelPhase(returnPhase: DocumentState.ReturnPhase) -> DocumentState.Phase {
        switch FailedStateView.primaryAction(error: .importError(.passwordProtected), returnPhase: returnPhase) {
        case .returnToEditor: .editing
        case .returnToResults:
            if case .verified(let report) = returnPhase { .verified(report: report) } else { .empty }
        case .reopenDocument, .chooseAnotherFile: .empty
        }
    }

    // MARK: - Copy

    static let title = "This document needs a password."
    static let body = "Enter the password to open it. The password is used on this device to unlock the document; Resecta does not store it. If iOS offers to save it, that offer is the system's own Passwords feature."
    static let placeholder = "Password"
    static let fieldAccessibilityLabel = "Document password"
    static let open = "Open"
    static let cancel = "Cancel"
    static let ok = "OK"
    static let wrongPassword = "That password did not open the document."
    static let certificateHint = "A document protected by a certificate or by another app's protection scheme, rather than a password, does not open in Resecta."
    static let cannotOpen = "The password was accepted, but the document could not be read in full with it, so it was not opened."
}

struct ImportPasswordSheet: View {
    let hold: LockedImportHold
    /// Submit: the typed password. The caller re-runs the import and feeds
    /// the outcome back through `ImportPasswordFlow`.
    let onSubmit: (String) -> Void
    /// Cancel, the swipe, and the terminal line's OK.
    let onCancel: () -> Void
    let isSubmitting: Bool

    @State private var password = ""
    @FocusState private var fieldFocused: Bool

    private var terminal: Bool { hold.lastOutcome == .cannotOpen }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.md) {
                Image(systemName: "lock.doc")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(ResectaTokens.BrandTeal.tint)
                    .accessibilityHidden(true)

                Text(ImportPasswordFlow.title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                Text(ImportPasswordFlow.body)
                    .font(.subheadline)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)

                if !terminal {
                    SecureField(ImportPasswordFlow.placeholder, text: $password)
                        .textFieldStyle(.roundedBorder)
                        .privacySensitive()
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.default)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .focused($fieldFocused)
                        .disabled(isSubmitting)
                        .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                        .accessibilityLabel(ImportPasswordFlow.fieldAccessibilityLabel)
                        .accessibilityIdentifier("importPasswordField")
                }

                if let line = errorLine {
                    Label {
                        Text(line)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(ResectaTokens.SemanticColor.failText)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("importPasswordError")
                }

                if !terminal, ImportPasswordFlow.showsCertificateHint(attempts: hold.attempts) {
                    Text(ImportPasswordFlow.certificateHint)
                        .font(.footnote)
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                }

                VStack(spacing: ResectaTokens.Spacing.sm) {
                    if terminal {
                        Button(ImportPasswordFlow.ok) { finish(onCancel) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("importPasswordCancel")
                    } else {
                        Button {
                            submit()
                        } label: {
                            if isSubmitting {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text(ImportPasswordFlow.open).frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(password.isEmpty || isSubmitting)
                        .accessibilityIdentifier("importPasswordSubmit")

                        Button(ImportPasswordFlow.cancel) { finish(onCancel) }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .disabled(isSubmitting)
                            .accessibilityIdentifier("importPasswordCancel")
                    }
                }
                .padding(.top, ResectaTokens.Spacing.sm)
            }
            .padding(ResectaTokens.Spacing.lg)
        }
        .accessibilityIdentifier("importPasswordSheet")
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear { fieldFocused = true }
        .task {
            // A sheet's first frame can drop the focus request; ask once more.
            try? await Task.sleep(for: .milliseconds(350))
            if !terminal { fieldFocused = true }
        }
        .onChange(of: hold.attempts) { _, _ in
            // A wrong password: the field empties and takes focus again.
            password = ""
            fieldFocused = true
        }
    }

    private var errorLine: String? {
        switch hold.lastOutcome {
        case .awaiting: nil
        case .wrongPassword: ImportPasswordFlow.wrongPassword
        case .cannotOpen: ImportPasswordFlow.cannotOpen
        }
    }

    private func submit() {
        guard !password.isEmpty, !isSubmitting else { return }
        let typed = password
        password = ""
        onSubmit(typed)
    }

    private func finish(_ action: () -> Void) {
        password = ""
        action()
    }
}
