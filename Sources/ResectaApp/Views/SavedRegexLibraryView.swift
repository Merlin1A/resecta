import SwiftUI
import RedactionEngine

// Settings → Saved regexes. App-wide regex library surfaced as two
// sections: the built-in patterns shipped with the app (read-only) and
// the user-saved entries (editable). Tapping into Regex mode inside
// Search & Redact surfaces the same library through the saved-regex
// menu in `SearchToolbarSection`.
//
// Mechanism-description copy only — every label describes what the
// pattern is, not what removing/adding it will do.

struct SavedRegexLibraryView: View {
    @Environment(SavedRegexStore.self) private var savedRegexStore

    @State private var newLabel: String = ""
    @State private var newPattern: String = ""
    @State private var addError: String?
    @State private var addInFlight: Bool = false

    // GATE-2 destructive-action confirmation symmetry (mirrors the
    // Settings Reset-to-Defaults dialog): the delete-all row confirms
    // before dropping the user-saved library.
    @State private var showClearAllConfirmation = false

    var body: some View {
        Form {
            aboutSection
            builtInSection
            userSavedSection
            clearAllSection
            addRow
        }
        .navigationTitle("Saved regexes")
        .navigationBarTitleDisplayMode(.inline)
        // GATE-2: destructive confirm. Copy names exactly what is
        // cleared: user-saved patterns only — built-ins ship with the
        // app and are unaffected.
        .confirmationDialog(
            "Delete all your patterns?",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                savedRegexStore.clearAllUserSaved()
            }
            .accessibilityIdentifier("savedRegexClearAllConfirm")
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every user-saved pattern is deleted from this device. Built-in patterns and other settings are not affected.")
        }
    }

    // MARK: - Delete All

    /// Destructive bulk clear for the user-saved library. Swipe-to-delete
    /// covers single rows; this row removes every user-saved pattern at
    /// once. Hidden while the user list is empty.
    @ViewBuilder
    private var clearAllSection: some View {
        if !savedRegexStore.userSavedRegexes.isEmpty {
            Section {
                Button("Delete All Your Patterns", role: .destructive) {
                    showClearAllConfirmation = true
                }
                .accessibilityIdentifier("savedRegexClearAllButton")
            } footer: {
                Text("Removes every user-saved pattern on this device. Built-in patterns stay.")
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            Text("Saved regexes are available from the regex search bar's saved-pattern menu. Built-in patterns ship with the app; user-saved patterns persist on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }
    }

    // MARK: - Built-ins

    private var builtInSection: some View {
        Section {
            ForEach(SavedRegexStore.builtIns) { regex in
                regexRow(regex)
            }
        } header: {
            Label("Built-in", systemImage: "lock")
        } footer: {
            Text("Built-in patterns can't be edited or removed.")
        }
    }

    // MARK: - User-saved

    private var userSavedSection: some View {
        Section {
            if savedRegexStore.userSavedRegexes.isEmpty {
                Text("No user-saved patterns yet. Add one below or save one from the regex search bar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(savedRegexStore.userSavedRegexes) { regex in
                    regexRow(regex)
                }
                .onDelete { offsets in
                    savedRegexStore.deleteUserSaved(at: offsets)
                }
            }
        } header: {
            Label("Your patterns", systemImage: "person.crop.rectangle")
        }
    }

    // MARK: - Add row

    private var addRow: some View {
        Section {
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xs) {
                TextField("Label", text: $newLabel)
                    .textInputAutocapitalization(.words)
                    .disabled(addInFlight)

                HStack {
                    TextField("Pattern", text: $newPattern)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(.body.monospaced())
                        .disabled(addInFlight)

                    if addInFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await commitAdd() }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .disabled(!canAdd)
                        .accessibilityLabel("Save pattern")
                    }
                }

                if let addError {
                    // GAP-41 — small error text routes through the
                    // measured text tier.
                    Text(addError)
                        .font(.caption)
                        .foregroundStyle(ResectaTokens.SemanticColor.failText)
                } else if savedRegexStore.userSavedRegexes.count >= SavedRegexStore.userSavedCap {
                    Text("User-saved list is at the \(SavedRegexStore.userSavedCap)-entry cap. Remove an item to add another.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("Add pattern", systemImage: "plus.square")
        } footer: {
            Text("Patterns run with the same safety pre-check the search bar uses. Patterns that match too broadly or could backtrack catastrophically are rejected.")
        }
    }

    private var canAdd: Bool {
        let trimmedLabel = newLabel.trimmingCharacters(in: .whitespaces)
        let trimmedPattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty, !trimmedPattern.isEmpty else { return false }
        return savedRegexStore.userSavedRegexes.count < SavedRegexStore.userSavedCap
    }

    private func commitAdd() async {
        addError = nil
        let trimmedLabel = newLabel.trimmingCharacters(in: .whitespaces)
        let trimmedPattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty, !trimmedPattern.isEmpty else { return }
        addInFlight = true
        let accepted = await RegexSentinelCheck.validate(trimmedPattern)
        addInFlight = false
        guard accepted else {
            addError = String(
                localized: "profile.regex.sentinel.rejected",
                table: "Legal",
                bundle: .main
            )
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        let added = savedRegexStore.add(label: trimmedLabel, pattern: trimmedPattern)
        if added {
            newLabel = ""
            newPattern = ""
        } else {
            addError = "Pattern rejected. Check the syntax, length, or label uniqueness."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func regexRow(_ regex: SavedRegex) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.displayLabel(for: regex))
                .font(.subheadline)
            Text(regex.pattern)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .privacySensitive()
        }
    }

    /// Resolve a saved regex's label for display. Built-ins carry a
    /// `Legal.xcstrings` dot-notation key in `label`; user-saved entries
    /// carry their user-typed name verbatim.
    static func displayLabel(for regex: SavedRegex) -> String {
        guard regex.isBuiltIn else { return regex.label }
        return String(
            localized: String.LocalizationValue(regex.label),
            table: "Legal",
            bundle: .main
        )
    }
}
