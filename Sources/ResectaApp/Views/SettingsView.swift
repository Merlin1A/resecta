import SwiftUI
import SafariServices
import RedactionEngine

// ARCH §7: Settings screen. SwiftUI Form gets Liquid Glass styling on iOS 26.
// R1: Mechanism-description language only — no outcome-promise phrasing.

struct SettingsView: View {
    // ACCESSIBILITY.md §9.2 — VoiceOver hint strings exposed as `static`
    // constants so the contract can be pinned by unit tests without
    // rendering the form. Mirrors the `InlineWarningBanner.lineLimit(for:)`
    // pattern used for the AX5 line-cap predicate.
    static let defaultModeAccessibilityHint = "Choose how redacted output is produced. Secure Rasterization produces image-only output; Searchable Redaction preserves non-redacted text."
    static let fillColorAccessibilityHint = "Color used to fill redacted regions in the output."
    static let verifyToggleDefaultHint = "When enabled, the app runs verification checks before you can export"
    static let verifyToggleParanoidLockedHint = "Locked on because Paranoid Mode is enabled."

    /// Routes the Verify Before Export toggle hint between the default
    /// mechanism description and the paranoid-locked variant. Exposed
    /// as `static` so the conditional can be unit-tested without
    /// rendering the toggle.
    static func verifyToggleHint(paranoidMode: Bool) -> String {
        paranoidMode ? verifyToggleParanoidLockedHint : verifyToggleDefaultHint
    }

    @Environment(SettingsState.self) private var settingsState
    // GATE-1 — DocumentState may be absent (e.g., from HomeView before any
    // document is loaded). When nil the banner never renders, matching the
    // "no pipeline can be in flight without a document" contract.
    @Environment(DocumentState.self) private var documentState: DocumentState?
    // Optional for the same reason as DocumentState:
    // Settings opens from HomeView with no workspace. Used by the Reset
    // Detection History affordance to also wipe the live in-memory priors
    // (otherwise clearAll would re-save the old history at document close).
    @Environment(RedactionState.self) private var redactionState: RedactionState?
    @Environment(\.dismiss) private var dismiss

    @State private var safariURL: URL?
    // GATE-2 (Pkg I): destructive-action confirmation symmetry. The
    // Reset-to-Defaults button is wired through a `.confirmationDialog`
    // so a stray tap doesn't wipe user preferences. Custom Terms and
    // Saved Regexes are persisted by separate stores and are not
    // affected by `resetToDefaults()`; the dialog copy names that so
    // the user knows what is and isn't in scope.
    @State private var showResetConfirmation = false
    /// UXF-32: Reset Detection History confirms before dropping the
    /// persisted priors, mirroring the sibling Reset-to-Defaults dialog.
    @State private var showResetHistoryConfirmation = false

    /// GATE-1 — True while a pipeline run is mid-flight. The companion
    /// STATE-5 snapshot in `PipelineCoordinator` already locks the run's
    /// behavior to the entry-time settings; this flag drives the banner
    /// that describes that mechanism to the user.
    private var isPipelineActive: Bool {
        guard let documentState else { return false }
        return Self.isPipelineActive(phaseKind: documentState.phaseKind)
    }

    /// GATE-1 — Phase-kind predicate exposed as a static so unit tests
    /// can pin the banner's visibility contract without hosting the view.
    /// The banner renders in `.detecting / .redacting / .verifying`; the
    /// run-entry STATE-5 snapshot already covers behavior locking, so
    /// the banner is purely informational (not a gate).
    static func isPipelineActive(phaseKind: DocumentState.PhaseKind) -> Bool {
        switch phaseKind {
        case .detecting, .redacting, .verifying:
            return true
        default:
            return false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                if isPipelineActive {
                    pipelineActiveBanner  // GATE-1
                }
                processingSection     // §A4g: renamed from "Redaction Mode"
                exportQualitySection  // §A4g: renamed from "Output"
                workflowSection
                    .id("workflowSection")
                appearanceSection     // 02-dark-mode-design.md §6.2
                paranoidModeSection   // SEC-8 (plan §3, escalation §1.3)
                privacySection        // §A4g: split from "About"
                supportSection        // §A4g: split from "About"

                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        showResetConfirmation = true
                    }
                    .accessibilityIdentifier("settingsResetButton")
                }
            }
            #if DEBUG
            // S7 sim-verification hook (read-only MCP — no scroll gestures):
            // jump to the Workflow section so the detection-preset picker
            // and search-history rows are screenshotable. verification.md §6.
            .onAppear {
                if CommandLine.arguments.contains("--settingsScrollToWorkflow") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        proxy.scrollTo("workflowSection", anchor: .top)
                    }
                }
            }
            #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("settingsView")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $safariURL) { url in
                SafariView(url: url)
                    .ignoresSafeArea()
            }
            // GATE-2 (Pkg I): mirrors the established
            // confirmation-dialog pattern used at Redact /
            // Delete N Regions / Pre-Export / Override-FAIL.
            // Copy is mechanism-description per ARCH §1.3.
            .confirmationDialog(
                "Reset all settings?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    settingsState.resetToDefaults()
                }
                .accessibilityIdentifier("settingsResetConfirm")
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("All settings return to their default values. Custom Terms and Saved Regexes are not affected.")
            }
        }
    }

    // MARK: - GATE-1 — Pipeline-active banner (STATE-5 companion)

    /// Non-blocking banner shown while the pipeline is `.detecting`,
    /// `.redacting`, or `.verifying`. The four pipeline-affecting
    /// controls below (`pipelineMode`, `autoVerify`, `autoApplyDetections`,
    /// `paranoidMode`, plus `fillColor` / `exportDPI`) remain functional;
    /// the banner describes the mechanism (STATE-5: settings snapshot
    /// captured at run entry) without promising an outcome.
    /// Mechanism-description language only (I6 / ARCH §1.3).
    private var pipelineActiveBanner: some View {
        Section {
            HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pipeline in progress")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("A pipeline run is in progress. Changes apply to the next run.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settingsPipelineActiveBanner")
            .accessibilityLabel("Pipeline in progress")
            .accessibilityHint("A pipeline run is in progress. Changes apply to the next run.")
        }
    }

    // MARK: - Processing (§A4g — renamed from "Redaction Mode")

    private var processingSection: some View {
        Section {
            // Phase 4D: Description text rows hide separators for visual clarity
            // ARCH §7: Picker with descriptions per mode
            Picker(selection: Binding(
                get: { settingsState.pipelineMode },
                set: { settingsState.pipelineMode = $0 }
            )) {
                Text("Secure Rasterization").tag(PipelineMode.secureRasterization)
                Text("Searchable Redaction").tag(PipelineMode.searchableRedaction)
            } label: {
                Text("Default Mode")
            }
            // ACCESSIBILITY.md §9.2 — VoiceOver users miss the descriptive
            // mode rows below the picker. Mirror the mechanism-description
            // copy as a hint so the trade-off is audible.
            .accessibilityHint(Self.defaultModeAccessibilityHint)

            // ARCH §7: Description for current selection
            switch settingsState.pipelineMode {
            case .secureRasterization:
                Text("Produces image-only output. The simplest approach \u{2014} recommended when redaction confidence is the top priority.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            case .searchableRedaction:
                Text("Preserves non-redacted text for search and selection. Available for documents with an existing text layer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        } header: {
            Label("Processing", systemImage: "cpu")
        } footer: {
            // ARCH §7: Footer note
            Text("Both modes use the same pixel-destruction process for redacted regions.")
        }
    }

    // MARK: - Export Quality (§A4g — renamed from "Output")

    private var exportQualitySection: some View {
        Section {
            // ARCH §7: DPI picker
            // Phase 4D: Description text hides separator
            Picker(selection: Binding(
                get: { settingsState.exportDPI },
                set: { settingsState.exportDPI = $0 }
            )) {
                Text("150 DPI").tag(150)
                Text("200 DPI").tag(200)
                Text("300 DPI").tag(300)
            } label: {
                Text("Output Quality")
            }
            .accessibilityLabel("Output quality in dots per inch")
            .accessibilityHint("Higher values produce sharper output but larger files")

            Text("Maximum output quality \u{2014} may be reduced on memory-constrained devices. Higher quality produces larger files.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)

            // ARCH §7: Fill color picker. Leading swatch (Q8) renders the
            // currently selected fill color directly (.black / .white) so the
            // user sees what they're choosing; the picker's value chevron and
            // VoiceOver announcement already carry the label → value semantics.
            Picker(selection: Binding(
                get: { settingsState.fillColor },
                set: { settingsState.fillColor = $0 }
            )) {
                Text("Black").tag(FillColor.black)
                Text("White").tag(FillColor.white)
            } label: {
                HStack(spacing: ResectaTokens.Spacing.sm) {
                    Text("Fill Color")
                    Circle()
                        .fill(settingsState.fillColor == .black ? Color.black : Color.white)
                        .overlay(Circle().stroke(Color.secondary, lineWidth: 0.5))
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
            }
            // ACCESSIBILITY.md §9.2 — pin the purpose so VoiceOver users
            // hear what the picker controls before drilling into options.
            .accessibilityHint(Self.fillColorAccessibilityHint)
        } header: {
            Label("Export Quality", systemImage: "square.and.arrow.up")
        }
    }

    // MARK: - Workflow (ARCH §7 + GAP §8.1)

    private var workflowSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: {
                    // SEC-8 override #2: paranoid mode forces verification on.
                    // The toggle reads as on (and is .disabled below) while
                    // paranoid is enabled, regardless of the stored setting.
                    settingsState.paranoidMode || settingsState.autoVerify
                },
                set: { settingsState.autoVerify = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verify Before Export")
                    Text("Run verification checks automatically before exporting")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    // Consequence line for the off position — names what
                    // exporting looks like without the checks (mechanism
                    // description, ARCH §1.3; the copy states what the app
                    // does, not an outcome).
                    Text("Off: documents export without the post-redaction checks. The results screen will show Verification Skipped.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(settingsState.paranoidMode) // SEC-8 override #2
            // ACCESSIBILITY.md §9.2 — when paranoid mode forces the toggle
            // on, swap the hint copy so VoiceOver explains *why* the
            // control reads as disabled instead of the default mechanism
            // description.
            .accessibilityHint(Self.verifyToggleHint(paranoidMode: settingsState.paranoidMode))

            // GAP §8.1: Detection review toggle. Inverted binding — toggle ON
            // means autoApplyDetections is false (triage review enabled).
            Toggle(isOn: Binding(
                get: { !settingsState.autoApplyDetections },
                set: { settingsState.autoApplyDetections = !$0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Detections Before Applying")
                    Text("Auto-detected items are shown for your review before being applied as redaction regions")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHint("When enabled, you can review and filter auto-detected items before they become redaction regions")

            // Detection preset picker. SELECTS one of
            // the calibrated threshold vectors (conservative / balanced /
            // aggressive→"Sensitive"); never edits threshold values.
            Picker(selection: Binding(
                get: { settingsState.detectionPreset },
                set: { settingsState.detectionPreset = $0 }
            )) {
                ForEach(SettingsPreset.allCases, id: \.self) { preset in
                    Text(preset.displayLabel).tag(preset)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detection Sensitivity")
                    Text(settingsState.detectionPreset.mechanismDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint("Choose how much evidence is required before a PII item is flagged for review")

            // Drop the persisted accept/reject
            // history (and the live document's in-memory copy when a
            // workspace is open) so priors return to the uniform default.
            Button("Reset Detection History", role: .destructive) {
                showResetHistoryConfirmation = true
            }
            .accessibilityHint("Clears the on-device record of accepted and rejected detections used to weight future scans")
            .accessibilityIdentifier("resetDetectionHistoryButton")
            // UXF-32: destructive confirm mirroring the GATE-2
            // Reset-to-Defaults dialog below. Copy is
            // mechanism-description per ARCH §1.3.
            .confirmationDialog(
                "Reset detection history?",
                isPresented: $showResetHistoryConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    RedactionState.clearPersistedPriors()
                    redactionState?.priors = PerCategoryPriors()
                }
                .accessibilityIdentifier("resetDetectionHistoryConfirm")
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The on-device record of accepted and rejected detections is cleared. Future scans start from the uniform default weighting.")
            }

            // Save Recent Searches toggle. When turned off,
            // existing recents are cleared immediately so no residual history
            // remains from before the preference was set.
            Toggle(isOn: Binding(
                get: { settingsState.saveRecentSearches },
                set: { newValue in
                    settingsState.saveRecentSearches = newValue
                    if !newValue {
                        // Clear in-memory state via the active search sheet,
                        // and remove the two recents keys from UserDefaults
                        // directly (covers the no-active-sheet case).
                        redactionState?.activeSearch?.clearRecentSearchHistory()
                        UserDefaults.standard.removeObject(forKey: "search.recents.text.v1")
                        UserDefaults.standard.removeObject(forKey: "search.recents.regex.v1")
                    }
                }
            )) {
                Text("Save Recent Searches")
            }
            .accessibilityHint("When enabled, text and regex queries are stored on this device after each search")
            .accessibilityIdentifier("saveRecentSearchesToggle")

            // Clear Search History affordance — clears both
            // UserDefaults keys and the active sheet's in-memory state.
            Button("Clear Search History", role: .destructive) {
                redactionState?.activeSearch?.clearRecentSearchHistory()
                UserDefaults.standard.removeObject(forKey: "search.recents.text.v1")
                UserDefaults.standard.removeObject(forKey: "search.recents.regex.v1")
            }
            .accessibilityHint("Removes all stored text and regex search queries from this device")
            .accessibilityIdentifier("clearSearchHistoryButton")

            // DRAW-7: Snap-to-text-box assist. While drawing a rectangle,
            // edges within 8 points of a recognized text-block edge are
            // nudged onto it. Mechanism-description language (I6) —
            // describes the alignment behavior without promising it.
            Toggle(isOn: Binding(
                get: { settingsState.snapToTextEnabled },
                set: { settingsState.snapToTextEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snap to Text Boxes")
                    Text("While drawing a rectangle, edges near recognized text rows are nudged to align with them")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHint("When enabled, rectangle edges near recognized text rows are nudged to align with them while you draw")

            // Always-flag / never-flag custom keyword lists.
            NavigationLink("Custom Terms") {
                CustomTermsView()
            }
            .accessibilityHint("Add always-flag or never-flag terms applied during PII scans.")

            // App-wide saved-regex library, surfaced in the regex search
            // toolbar's saved-pattern menu.
            NavigationLink("Saved Regexes") {
                SavedRegexLibraryView()
            }
            .accessibilityHint("Manage the saved regex patterns surfaced in the regex search menu.")
        } header: {
            Label("Workflow", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("When detection review is enabled, auto-detected items are shown for your review before being applied as redaction regions.")
                // Verbatim mechanism-description copy.
                Text("Recent searches are stored on this device to help you repeat common queries. Disable to stop recording.")
            }
        }
    }

    // MARK: - Appearance (02-dark-mode-design.md §6)

    /// Three-option appearance picker. `.menu` style matches iOS Settings →
    /// Display & Brightness. Section sits between Workflow and Paranoid
    /// Mode per 02-dark-mode-design.md §6.2. Footer copy is mechanism
    /// description only — no outcome promise (I6 / ARCH §1.3).
    private var appearanceSection: some View {
        Section {
            Picker(selection: Binding(
                get: { settingsState.appearancePreference },
                set: { settingsState.appearancePreference = $0 }
            )) {
                ForEach(AppearancePreference.allCases) { pref in
                    Text(pref.displayLabel).tag(pref)
                }
            } label: {
                Text("Appearance")
            }
            .pickerStyle(.menu)
            .accessibilityLabel("App appearance")
            .accessibilityHint("Choose System to follow your iOS setting, or pin the app to Light or Dark.")
        } header: {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
        } footer: {
            Text("Choose System to follow your iOS setting, or pin Light or Dark.")
        }
    }

    // MARK: - Paranoid Mode (SEC-8 — plan §3, escalation §1.3)

    /// SEC-8 paranoid-mode toggle. Off by default. Copy uses
    /// mechanism-description language only (I6 / ARCH §1.3): each item
    /// describes what the app does, not an outcome promise. The three
    /// listed behaviors land as a bundle — there are no per-behavior
    /// sub-toggles by locked design.
    ///
    /// The never-shipped
    /// report-copy behavior was removed from the paranoid copy — that mechanism
    /// was parked on the overflow menu and never shipped
    /// (VerificationResultsView.swift), so claiming the paranoid mode suppresses
    /// it was a false claim (four overrides → three).
    private var paranoidModeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settingsState.paranoidMode },
                set: { settingsState.paranoidMode = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paranoid Mode")
                    Text("When on, the app forces secure-rasterization mode, runs verification automatically, and removes auxiliary metadata from imported Live Photos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHint("When enabled, the app applies three behavior overrides described below")

            // Explicit list of the three enforced behaviors. Phrased in
            // mechanism-description language (I6). Each row hides its
            // separator for visual continuity with the toggle row.
            VStack(alignment: .leading, spacing: 4) {
                Text("While on:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\u{2022} Pipeline mode is forced to Secure Rasterization.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\u{2022} Verification runs before every export; the toggle above is disabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\u{2022} Auxiliary metadata is removed from imported Live Photo / Portrait depth images.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .listRowSeparator(.hidden)
        } header: {
            Label("Paranoid Mode", systemImage: "lock.fill")
        } footer: {
            Text("Paranoid mode is designed to reduce the surface area of optional side channels. Behavior is best-effort.")
        }
    }

    // MARK: - Privacy (§A4g — split from "About")

    private var privacySection: some View {
        Section {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
            }

            LabeledContent("Developer") {
                Text("Jesse Brookins")
            }

            // R3 compliant: SFSafariViewController runs in Safari's process,
            // no URLSession in our binary.
            Button("Privacy Policy") {
                safariURL = Links.privacyPolicy
            }

            Button("End-User License Agreement") {
                safariURL = Links.eula
            }
        } header: {
            Label("Privacy", systemImage: "lock.shield")
        } footer: {
            // UXF-26: the unsaved-work reality named once, in an honest
            // place. Nothing persists across a quit by design — the same
            // property the privacy posture rests on. Mechanism
            // description only; no outcome promise (ARCH §1.3).
            Text("Resecta doesn't store your documents or edits. In-progress work is cleared when the app closes — export to keep the redacted copy.")
        }
    }

    // MARK: - Support (§A4g — split from "About")

    private var supportSection: some View {
        Section {
            Button {
                safariURL = Links.sourceCode
            } label: {
                Label("Source Code", systemImage: "arrow.up.forward.square")
            }

            Button {
                safariURL = Links.reportIssue
            } label: {
                Label("Report an Issue", systemImage: "arrow.up.forward.square")
            }

            Link(destination: Links.sendFeedback) {
                Label("Send Feedback", systemImage: "envelope")
            }
        } header: {
            Label("Support", systemImage: "questionmark.circle")
        } footer: {
            // §A4g: Safari warning footer
            Text("These links open in Safari. Resecta itself makes no network connections.")
        }
    }

    // MARK: - Link Constants

    /// Single source of truth for every outbound Settings / Support link.
    /// `internal` (not `private`) so `LegalLinkExistenceTests` can assert the
    /// host / org via `@testable import`.
    ///
    /// CND-03 (launch-fix-v2 · S2): Privacy Policy and EULA point at the hosted
    /// resecta.app pages, moved off the prior
    /// `github.com/Merlin1A/resecta/blob/master/…` form — that embedded a
    /// brittle default-branch segment and showed a reviewer raw Markdown. The
    /// pages must be live before submission (a legal & transparency launch gate).
    /// CND-05: `sourceCode` / `reportIssue` use the canonical public org
    /// `Merlin1A/resecta` (the repo is made public at submission, so these 404
    /// until then); `reportIssue` deep-links the issue tracker.
    enum Links {
        static let privacyPolicy = URL(string: "https://resecta.app/privacy")!
        static let eula = URL(string: "https://resecta.app/eula")!
        static let sourceCode = URL(string: "https://github.com/Merlin1A/resecta")!
        static let reportIssue = URL(string: "https://github.com/Merlin1A/resecta/issues")!
        static let sendFeedback = URL(string: "mailto:support@resecta.app?subject=Resecta%20Feedback")!
    }
}

// MARK: - SFSafariViewController Wrapper (ARCH §7)

/// Wraps SFSafariViewController for use in SwiftUI `.sheet`.
/// R3: SafariServices networking runs in Safari's process, not our app binary.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - URL + Identifiable (for .sheet(item:))

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
