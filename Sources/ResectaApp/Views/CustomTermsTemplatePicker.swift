import SwiftUI
import RedactionEngine

// W-B (e) — Template picker sheet for Custom Terms. Confirmation-
// gated; user retains control; mechanism-description copy only
// (CLAUDE.md Hard Rules).

struct CustomTermsTemplatePicker: View {
    @Environment(UserTermsStore.self) private var userTermsStore
    @Binding var isPresented: Bool

    @State private var template: CustomTermsTemplate?
    @State private var loadError: String?
    @State private var showingConfirmation = false
    @State private var importPreview: ImportPreview?
    /// QW-2 (D07-F2) — in-flight gate for the async
    /// `RegexSentinelCheck.validate` probes that now run at preview
    /// time. Mirrors the sibling add-sites (`AddTermRow.submit`,
    /// `SavedRegexLibraryView.commitAdd`,
    /// `SearchToolbarSection.saveCurrentRegex`) so repeated taps can't
    /// queue overlapping preview builds.
    @State private var previewInFlight = false

    private struct ImportPreview {
        let toImport: [UserTerm]
        let skipped: [UserTerm]
        /// Pkg G.3 / TRUST-template-preview-count-mismatch +
        /// UX-template-preview-precount: template entries that fail
        /// `UserTermsStore.isValidUserTerm` (empty pattern, > 200 chars,
        /// or unsafe regex) are excluded from `toImport` at preview
        /// build time so the confirmation dialog's "Add N entries"
        /// matches the count `performImport` actually commits.
        let skippedInvalid: [UserTerm]
        let exceedsCap: Bool
        let projectedTotal: Int
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let template {
                        templateRow(template)
                    } else if let loadError {
                        Text("Template unavailable: \(loadError)")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ProgressView().task { await load() }
                    }
                } header: {
                    Text("Available templates")
                }
            }
            .navigationTitle("Import a template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .confirmationDialog(
                confirmationTitle,
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                if let preview = importPreview, !preview.exceedsCap {
                    Button("Add \(preview.toImport.count) entries") {
                        performImport()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmationBody)
            }
        }
    }

    @ViewBuilder
    private func templateRow(_ template: CustomTermsTemplate) -> some View {
        Button {
            Task { await preview(template) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.templateName)
                        .font(.body.weight(.medium))
                    Text("\(template.entries.count) entries \u{2014} designed to add per-state shape patterns to the always-flag list")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if previewInFlight {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(previewInFlight)
    }

    private var confirmationTitle: String {
        guard let preview = importPreview, let template else { return "" }
        if preview.exceedsCap {
            return "Cannot import"
        }
        return "Import \(preview.toImport.count) of \(template.entries.count) entries"
    }

    private var confirmationBody: String {
        guard let preview = importPreview else { return "" }
        if preview.exceedsCap {
            return "Adding \(preview.toImport.count) entries would exceed the \(UserTermsStore.perListCap)-entry cap (current \(userTermsStore.blob.alwaysFlag.count) + \(preview.toImport.count) > \(UserTermsStore.perListCap)). Reduce the existing list first."
        }
        var lines: [String] = [
            "These entries are added to the always-flag list. The starter regex shape is a permissive default \u{2014} review and tighten per state as needed."
        ]
        if !preview.skipped.isEmpty {
            lines.append("\(preview.skipped.count) entries already present and will be skipped.")
        }
        // Pkg G.3 / UX-template-preview-precount: surface invalid
        // entries excluded by the pre-filter so the user knows why the
        // displayed N may be smaller than the template's raw entry count.
        if !preview.skippedInvalid.isEmpty {
            lines.append("\(preview.skippedInvalid.count) entries skipped as invalid (empty, too long, or unsafe regex).")
        }
        return lines.joined(separator: "\n\n")
    }

    private func load() async {
        do {
            template = try CustomTermsTemplateLoader.licensePlate50StateStarter()
        } catch {
            loadError = String(describing: error)
        }
    }

    private func preview(_ template: CustomTermsTemplate) async {
        previewInFlight = true
        defer { previewInFlight = false }
        let candidates = CustomTermsTemplateLoader.userTerms(from: template)
        let existing = userTermsStore.blob.alwaysFlag
        // Pkg G.3 / TRUST-template-preview-count-mismatch: split the
        // candidate list into entries that pass
        // `UserTermsStore.isValidUserTerm` and those that do not.
        // `performImport` would skip the invalid set on commit, so
        // dropping them BEFORE the dedup pass keeps the preview's "Add
        // N" count and the actual import count in lockstep.
        // QW-2 (D07-F2) — the partition now also runs the async
        // `RegexSentinelCheck.validate` probe on each regex candidate,
        // matching the three interactive add-sites, so a pathological
        // template pattern is rejected here instead of stalling scans
        // after import.
        let (validCandidates, invalidCandidates) = await Self.partitionValid(candidates)
        let dedup = CustomTermsTemplateLoader.deduplicating(
            validCandidates, against: existing
        )
        let projectedTotal = existing.count + dedup.toImport.count
        importPreview = ImportPreview(
            toImport: dedup.toImport,
            skipped: dedup.skipped,
            skippedInvalid: invalidCandidates,
            exceedsCap: projectedTotal > UserTermsStore.perListCap,
            projectedTotal: projectedTotal
        )
        showingConfirmation = true
    }

    /// Pkg G.3 / TRUST-template-preview-count-mismatch: partition a
    /// candidate list into entries `UserTermsStore.isValidUserTerm`
    /// accepts and entries it rejects. Pure-data helper so the gating
    /// contract can be pinned in unit tests without driving the view.
    /// `@MainActor` because `UserTermsStore.isValidUserTerm` inherits
    /// the store's actor isolation.
    ///
    /// QW-2 (D07-F2) — regex candidates that pass the static heuristic
    /// additionally run the async `RegexSentinelCheck.validate` ReDoS
    /// probe, the same gate the three interactive add-sites apply
    /// (`AddTermRow`, `SavedRegexLibraryView`, `SearchToolbarSection`).
    /// A heuristic-passing but sentinel-failing pattern lands in
    /// `invalid`, so it is excluded from `toImport` at preview-build
    /// time and the preview's "Add N" count still equals what
    /// `performImport` commits. Literal (non-regex) entries skip the
    /// probe — they are never compiled as regex by the engine.
    @MainActor
    static func partitionValid(
        _ candidates: [UserTerm]
    ) async -> (valid: [UserTerm], invalid: [UserTerm]) {
        var valid: [UserTerm] = []
        var invalid: [UserTerm] = []
        for term in candidates {
            guard UserTermsStore.isValidUserTerm(term) else {
                invalid.append(term)
                continue
            }
            if term.isRegex {
                let accepted = await RegexSentinelCheck.validate(term.pattern)
                guard accepted else {
                    invalid.append(term)
                    continue
                }
            }
            valid.append(term)
        }
        return (valid, invalid)
    }

    private func performImport() {
        guard let preview = importPreview, !preview.exceedsCap else { return }
        for term in preview.toImport {
            _ = userTermsStore.addAlwaysFlag(term)
        }
        isPresented = false
    }
}
