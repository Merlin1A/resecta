import SwiftUI

// The home screen — the app's mark over the wordmark and tagline, three
// entries (Open a Document · Import Photos · Try the Sample), the trust
// words and the version, centred between the bar and the home indicator.
// Mechanism-description language only — no outcome promises.
// Frozen strings: the tagline and the trust words.

struct HomeView: View {
    @Environment(AppCoordinator.self) private var appCoordinator
    @Environment(SettingsState.self) private var settingsState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var showSettings = false
    /// The scroll view's visible height, read from its geometry; the stack is
    /// given it as a minimum height so it centres when it fits and scrolls
    /// from the top when it does not.
    @State private var viewportHeight: CGFloat = 0
    /// Armed when an entry opens a workspace, so a second tap before the
    /// switch opens nothing more; a cancelled picker opens no workspace and
    /// leaves the entries live. Home is rebuilt on every return, so the flag
    /// needs no reset.
    @State private var isOpening = false
    // The prior `showImportError` state field
    // drove a generic `.alert("Import Error", ...)` on HomeView. Removed —
    // import errors now uniformly surface through the workspace-level
    // FailedStateView via `.failed(.importError(.corrupt))`. See
    // `handleFileImportResult` for the failure-routing path.

    static let tagline = "On-device PDF redaction designed to remove the underlying content."

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        masthead
                        Spacer().frame(height: ResectaTokens.Spacing.xl)
                        entries
                        if isAccessibilitySize {
                            // The tagline moves below the entries; the
                            // masthead element keeps speaking it.
                            Spacer().frame(height: ResectaTokens.Spacing.lg)
                            taglineText
                                .accessibilityHidden(true)
                        }
                        Spacer().frame(height: ResectaTokens.Spacing.lg)
                        TrustLine()
                            .frame(maxWidth: columnMaxWidth)
                        Spacer().frame(height: ResectaTokens.Spacing.sm)
                        footer
                    }
                    .padding(.horizontal, ResectaTokens.Spacing.md)
                    .padding(.vertical, ResectaTokens.HomeEntry.verticalPad)
                    .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .center)
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    // containerSize is already inset by the bar and the home indicator.
                    geometry.containerSize.height
                } action: { _, height in
                    viewportHeight = max(0, height)
                }

                .scrollBounceBehavior(.basedOnSize)
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") {
                        showSettings = true
                    }
                    // Neutral, like the editor toolbar's Settings
                    // button — `.primary` is black in light and
                    // white in dark; scoped to the button, so the Settings
                    // sheet's own tint is unaffected.
                    .tint(.primary)
                    .accessibilityIdentifier("homeSettingsButton")
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: ImportService.acceptedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImportResult(result)
            }
            .photoImport(isPresented: $showPhotoPicker) { images, count in
                guard !isOpening else { return }
                isOpening = true
                Task { await appCoordinator.openRedactWithImages(images, count: count) }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environment(settingsState)
                    .presentationDetents([.medium, .large])
            }
            // The failed screen's "Choose Another File" asks for the door the
            // document came through to open again; the fresh Home presents it.
            .task {
                switch appCoordinator.consumeReopenDoor() {
                case .files: showFilePicker = true
                case .photos: showPhotoPicker = true
                default: break
                }
            }
            #if DEBUG
            // Sim-verification hook (read-only MCP — no taps): open the
            // Settings sheet at launch so the detection-preset picker and
            // search-history affordances are screenshotable.
            .onAppear {
                if CommandLine.arguments.contains("--openSettings") {
                    showSettings = true
                }
            }
            #endif
            // The generic Import Error alert
            // is gone. The fileImporter `.failure` branch now opens a
            // workspace whose phase lands on `.failed(.importError(.corrupt))`
            // — the same FailedStateView the corrupt-file import branch
            // surfaces inside the workspace. Uniformity replaces the
            // dual-surface design.
        }
    }

    // MARK: - Layout

    private var columnMaxWidth: CGFloat {
        horizontalSizeClass == .regular
            ? ResectaTokens.BrandedSurface.panelMaxWidthRegular
            : ResectaTokens.BrandedSurface.panelMaxWidthCompact
    }

    private var taglineText: some View {
        Text(Self.tagline)
            .font(.subheadline)
            .foregroundStyle(ResectaTokens.SemanticColor.supportText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: ResectaTokens.HomeEntry.taglineMaxWidth)
    }

    /// The mark, the wordmark and the tagline: one spoken heading. At the
    /// accessibility sizes the mark is hidden and the tagline shows below
    /// the entries instead.
    private var masthead: some View {
        VStack(spacing: ResectaTokens.Spacing.sm) {
            if !isAccessibilitySize {
                HomeMark(size: ResectaTokens.HomeEntry.markTile)
                    .padding(.bottom, ResectaTokens.Spacing.xs)
            }

            Text("Resecta")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)

            if !isAccessibilitySize {
                taglineText
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Resecta") + Text(", ") + Text(Self.tagline))
        .accessibilityAddTraits(.isHeader)
    }

    private var entries: some View {
        VStack(spacing: ResectaTokens.HomeEntry.gap) {
            HomeChoiceCard(
                symbol: "doc.badge.plus",
                style: .primary,
                title: "Open a Document",
                bodyText: "Import a PDF or an image from Files. Nothing is uploaded.",
                action: { showFilePicker = true }
            )
            .accessibilityHint("Opens the Files picker.")
            .accessibilityIdentifier("homeOpenDocument")

            HomeChoiceCard(
                symbol: "photo.on.rectangle.angled",
                style: .subtle,
                title: "Import Photos",
                bodyText: "Choose up to 20 photos, one page each. Nothing is uploaded.",
                action: { showPhotoPicker = true }
            )
            .accessibilityHint("Opens the system Photos picker.")
            .accessibilityIdentifier("homeImportPhotos")

            HomeChoiceCard(
                symbol: "doc.text",
                style: .row,
                title: "Try the Sample",
                bodyText: "A bundled 3-page bank statement.",
                action: { openSampleDocument() }
            )
            .accessibilityHint("Opens the sample in the editor.")
            .accessibilityIdentifier("homeTrySample")
        }
        .frame(maxWidth: columnMaxWidth)
        .disabled(isOpening)
    }

    private var footer: some View {
        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
            .font(.footnote)
            .foregroundStyle(ResectaTokens.SemanticColor.supportText)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ResectaTokens.Spacing.sm)
    }

    // MARK: - Import

    private func handleFileImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard !isOpening else { return }
            isOpening = true
            Task {
                await appCoordinator.openRedactWithDocument(url: url)
            }
        case .failure(let error):
            // A cancelled picker may be reported as `userCancelled`; nothing
            // to show, no workspace opens, and the entries stay live.
            if (error as? CocoaError)?.code == .userCancelled { return }
            guard !isOpening else { return }
            isOpening = true
            // Open a fresh workspace and drive
            // its DocumentState to `.failed(.importError(.corrupt))`. The
            // workspace's FailedStateView is the same surface a corrupt-
            // file import (from inside the workspace) lands on; threading
            // the HomeView failure through the same route removes the
            // prior dual-surface design (HomeView alert + workspace
            // FailedStateView). The user reaches workspace chrome and
            // can re-import via the standard recovery affordance.
            appCoordinator.openRedact(door: .files)
            guard case .redact(let workspace) = appCoordinator.activeWorkspace else { return }
            workspace.documentState.transition(to: .importing)
            workspace.documentState.transition(to: .failed(
                error: .importError(.corrupt),
                returnPhase: .empty
            ))
        }
    }

    // Bundled-sample entry point. DocumentState / RedactionState are
    // workspace-scoped (created by RedactWorkspace), so we spin up a
    // fresh workspace before loading the doc — same pattern as the
    // --loadTestDocument debug hook in ResectaApp.swift.
    // The "Try the Sample" entry is a permanent affordance
    // by design, so this path no longer flips a first-run flag.
    private func openSampleDocument() {
        guard !isOpening else { return }
        isOpening = true
        Task {
            appCoordinator.openRedact(door: .sample)
            guard case .redact(let workspace) = appCoordinator.activeWorkspace else { return }
            await ImportService.loadSampleDocument(
                documentState: workspace.documentState,
                redactionState: workspace.redactionState
            )
        }
    }
}
