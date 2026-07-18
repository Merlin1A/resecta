import SwiftUI
import UIKit
import RedactionEngine

// W3 — power-user always-flag / never-flag custom keyword screen.
//
// Presented via NavigationLink from `SettingsView.workflowSection`, below
// the existing Advanced Thresholds link. Two sections (Always Flag and
// Never Flag) with swipe-to-delete rows and an add-row that validates
// synchronously (length cap + regex validity) before mutating state.
//
// Copy is mechanism-description only.

struct CustomTermsView: View {
    @Environment(UserTermsStore.self) private var userTermsStore

    @State private var newAlwaysPattern: String = ""
    @State private var newAlwaysIsRegex: Bool = false
    @State private var alwaysError: String?

    @State private var newNeverPattern: String = ""
    @State private var newNeverIsRegex: Bool = false
    @State private var neverError: String?

    @State private var showingTemplatePicker = false

    /// CL-QP1-02 (approved at QCP-P 2026-07-03) — V1.0 ships without the
    /// template-picker entry point; the browse button is gated off behind
    /// this flag. Flip it to `true` to re-enable the UI — the picker view,
    /// import machinery, template JSON, and their test suites are
    /// intentionally preserved and stay compiled and green, so revival is
    /// a one-line flip. Mirrors
    /// `DocumentEditorView.advancedDrawToolsEnabled`.
    static let templatePickerEnabled = false

    var body: some View {
        Form {
            aboutSection
            if Self.templatePickerEnabled {
                templatesSection
            }
            alwaysFlagSection
            neverFlagSection
        }
        .navigationTitle("Custom Terms")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingTemplatePicker) {
            CustomTermsTemplatePicker(isPresented: $showingTemplatePicker)
                .environment(userTermsStore)
        }
    }

    // MARK: - Templates (W-B)

    private var templatesSection: some View {
        Section {
            Button {
                showingTemplatePicker = true
            } label: {
                Label("Browse starter templates", systemImage: "square.and.arrow.down.on.square")
            }
        } footer: {
            Text("Templates ship with placeholder patterns the user can edit after import.")
                .font(.caption)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            Text("Always-flag terms are added as matches during every scan. Never-flag terms drop matches whose text equals the term. Only affects scans \u{2014} Search matches pass through unchanged.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }
    }

    // MARK: - Always Flag

    private var alwaysFlagSection: some View {
        Section {
            ForEach(userTermsStore.blob.alwaysFlag, id: \.self) { term in
                TermRow(term: term)
            }
            .onDelete { offsets in
                userTermsStore.removeAlwaysFlag(at: offsets)
            }

            AddTermRow(
                pattern: $newAlwaysPattern,
                isRegex: $newAlwaysIsRegex,
                error: $alwaysError,
                placeholder: "Add always-flag term",
                listName: "always-flag",
                isAtCap: userTermsStore.blob.alwaysFlag.count
                    >= UserTermsStore.perListCap
            ) { term in
                // Q-UX-customterms-error-generic / V1.0-safe (Pkg N):
                // view-side duplicate detection BEFORE calling
                // `addAlwaysFlag`. The store still rejects duplicates on
                // its own (and stays the authoritative gate), but the
                // pre-check lets us surface a specific reason — duplicate
                // vs. invalid-regex — without expanding the store API to
                // return an enum result (HARD-STOP guard per CLAUDE.md;
                // store API surface unchanged in this package).
                let isDuplicate = userTermsStore.blob.alwaysFlag.contains(where: {
                    $0.pattern == term.pattern && $0.isRegex == term.isRegex
                })
                if isDuplicate {
                    alwaysError = "This term is already on the always-flag list."
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    return
                }
                if userTermsStore.addAlwaysFlag(term) {
                    newAlwaysPattern = ""
                    newAlwaysIsRegex = false
                    alwaysError = nil
                } else {
                    // The duplicate path above is covered; remaining
                    // store rejections come from the validation chain
                    // (regex compile, length cap, per-list cap). The
                    // length-cap path is already surfaced by AddTermRow,
                    // and the per-list cap is gated by `isAtCap` above —
                    // a reject here narrows to "validation failed" with
                    // regex / invalid-input as the typical cause.
                    alwaysError = "Term rejected. The pattern may be invalid or fail the regex safety check."
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        } header: {
            Label("Always Flag", systemImage: "flag.fill")
        } footer: {
            Text("Added as matches alongside detector hits. Use for names, project codes, or identifiers your detector presets may not recognize.")
        }
    }

    // MARK: - Never Flag

    private var neverFlagSection: some View {
        Section {
            ForEach(userTermsStore.blob.neverFlag, id: \.self) { term in
                TermRow(term: term)
            }
            .onDelete { offsets in
                userTermsStore.removeNeverFlag(at: offsets)
            }

            AddTermRow(
                pattern: $newNeverPattern,
                isRegex: $newNeverIsRegex,
                error: $neverError,
                placeholder: "Add never-flag term",
                listName: "never-flag",
                isAtCap: userTermsStore.blob.neverFlag.count
                    >= UserTermsStore.perListCap
            ) { term in
                // Q-UX-customterms-error-generic / V1.0-safe (Pkg N):
                // view-side duplicate detection BEFORE calling
                // `addNeverFlag`. See the always-flag analogue above
                // for the rationale and HARD-STOP guard.
                let isDuplicate = userTermsStore.blob.neverFlag.contains(where: {
                    $0.pattern == term.pattern && $0.isRegex == term.isRegex
                })
                if isDuplicate {
                    neverError = "This term is already on the never-flag list."
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    return
                }
                if userTermsStore.addNeverFlag(term) {
                    newNeverPattern = ""
                    newNeverIsRegex = false
                    neverError = nil
                } else {
                    neverError = "Term rejected. The pattern may be invalid or fail the regex safety check."
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        } header: {
            Label("Never Flag", systemImage: "flag.slash")
        } footer: {
            Text("Matches whose text equals a never-flag term are dropped before appearing in results.")
        }
    }
}

// MARK: - Term Row

struct TermRow: View {
    let term: UserTerm

    var body: some View {
        HStack {
            Text(term.pattern)
                .font(.body.monospaced())
                .privacySensitive()
                .lineLimit(2)
            if term.isRegex {
                Spacer()
                Text("REGEX")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ResectaTokens.BrandTeal.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(ResectaTokens.BrandTeal.tint)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(term.pattern), \(term.isRegex ? "regex" : "literal")")
    }
}

// MARK: - Add Row

struct AddTermRow: View {
    @Binding var pattern: String
    @Binding var isRegex: Bool
    @Binding var error: String?
    let placeholder: String
    let listName: String
    let isAtCap: Bool
    let onAdd: (UserTerm) -> Void

    @FocusState private var isFocused: Bool

    /// Pkg G.3 / TRUST-customterms-no-async-sentinel: in-flight gate
    /// for the async `RegexSentinelCheck.validate` call. Mirrors the
    /// sibling sites (`SavedRegexLibraryView.commitAdd`,
    /// `SearchToolbarSection.saveCurrentRegex`) so the user can't queue
    /// repeated submissions while a sentinel probe is running.
    @State private var submitInFlight: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(placeholder, text: $pattern)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($isFocused)
                    .disabled(isAtCap || submitInFlight)
                    .onSubmit { Task { await submit() } }
                    .accessibilityLabel("\(listName) term input")
                Toggle("Regex", isOn: $isRegex)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .disabled(isAtCap || submitInFlight)
                    .accessibilityLabel("Treat as regular expression")
                if submitInFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await submit() }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty || isAtCap)
                    .accessibilityLabel("Add term to \(listName) list")
                }
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if isAtCap {
                Text("List is at the \(UserTermsStore.perListCap)-entry cap. Remove an item to add another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if pattern.count > UserTermsStore.patternLengthCap {
                Text("Pattern too long (max \(UserTermsStore.patternLengthCap) characters).")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// Pkg G.3 / TRUST-customterms-no-async-sentinel: regex submissions
    /// now route through `RegexSentinelCheck.validate` ahead of the
    /// commit step, mirroring `SavedRegexLibraryView.commitAdd` and
    /// `SearchToolbarSection.saveCurrentRegex`. Literal (non-regex)
    /// submissions skip the sentinel — the sync length + duplicate
    /// guards already cover those entries since they are not compiled
    /// as regex by the engine.
    private func submit() async {
        submitInFlight = true
        defer { submitInFlight = false }
        let outcome = await Self.validateSubmission(
            rawPattern: pattern,
            isRegex: isRegex
        )
        switch outcome {
        case .empty:
            return
        case .tooLong(let message):
            error = message
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .invalidRegex(let message):
            error = message
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .sentinelRejected(let message):
            error = message
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .accepted(let term):
            onAdd(term)
        }
    }

    /// Pkg G.3 / TRUST-customterms-no-async-sentinel: pure-output
    /// representation of every path the `submit` flow can take. The
    /// view wires each case to the appropriate UI side-effect (error
    /// banner + haptic, or `onAdd`); unit tests pin the case + message
    /// each path produces without driving a SwiftUI host.
    enum SubmissionOutcome: Equatable {
        case empty
        case tooLong(message: String)
        case invalidRegex(message: String)
        case sentinelRejected(message: String)
        case accepted(UserTerm)
    }

    /// Pkg G.3 / TRUST-customterms-no-async-sentinel: static
    /// validation chain mirroring `SavedRegexLibraryView.commitAdd`.
    /// For regex submissions: sync `validateRegexPattern` is the
    /// fast-fail (200-char cap, nested-quantifier heuristic, NSRegex
    /// compile), then `RegexSentinelCheck.validate` runs the ReDoS
    /// sentinel probe. Literal submissions skip the regex chain — the
    /// sync length guard alone is sufficient since they are not
    /// compiled by the engine.
    /// `@MainActor` because the cap constant is read from the
    /// `@MainActor`-isolated `UserTermsStore`.
    @MainActor
    static func validateSubmission(
        rawPattern: String,
        isRegex: Bool
    ) async -> SubmissionOutcome {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        guard trimmed.count <= UserTermsStore.patternLengthCap else {
            return .tooLong(
                message: "Pattern exceeds \(UserTermsStore.patternLengthCap) characters."
            )
        }
        if isRegex {
            guard DocumentSearcher.validateRegexPattern(trimmed) != nil else {
                return .invalidRegex(message: "Invalid or unsafe regex pattern.")
            }
            let accepted = await RegexSentinelCheck.validate(trimmed)
            guard accepted else {
                let message = String(
                    localized: "profile.regex.sentinel.rejected",
                    table: "Legal",
                    bundle: .main
                )
                return .sentinelRejected(message: message)
            }
        }
        return .accepted(UserTerm(pattern: trimmed, isRegex: isRegex))
    }
}
