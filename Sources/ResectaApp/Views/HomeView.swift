import SwiftUI
import UIKit

// Variant B home screen — wordmark masthead, two equally-weighted choice
// cards (Open a Document / Try the Sample), trust strip, version footer.
// R1: Mechanism-description language only — no outcome promises.
// Frozen strings (handoff §10): tagline, card bodies, trust labels.

struct HomeView: View {
    @Environment(AppCoordinator.self) private var appCoordinator
    @Environment(SettingsState.self) private var settingsState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showFilePicker = false
    @State private var showSettings = false
    // Q-FLOW-1 / FLOW-1 (Pkg N): the prior `showImportError` state field
    // drove a generic `.alert("Import Error", ...)` on HomeView. Removed —
    // import errors now uniformly surface through the workspace-level
    // FailedStateView via `.failed(.importError(.corrupt))`. See
    // `handleFileImportResult` for the failure-routing path.

    // KI-3: doc.text.redact SF Symbol availability unverified for iOS 26.
    private var heroSymbol: String {
        UIImage(systemName: "doc.text.redact") != nil
            ? "doc.text.redact" : "doc.viewfinder"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: ResectaTokens.Spacing.xl) {
                        masthead
                        choiceStack
                        trustStrip
                        footer
                    }
                    .padding(.horizontal, ResectaTokens.Spacing.md)
                    .padding(.vertical, dynamicTypeSize.isAccessibilitySize
                        ? ResectaTokens.Spacing.lg : ResectaTokens.Spacing.xxl)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") {
                        showSettings = true
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.pdf, .image],
                allowsMultipleSelection: false
            ) { result in
                handleFileImportResult(result)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environment(settingsState)
                    .presentationDetents([.medium, .large])
            }
            #if DEBUG
            // S7 sim-verification hook (read-only MCP — no taps): open the
            // Settings sheet at launch so the detection-preset picker and
            // search-history affordances are screenshotable. Documented
            // per verification.md §6.
            .onAppear {
                if CommandLine.arguments.contains("--openSettings") {
                    showSettings = true
                }
            }
            #endif
            // Q-FLOW-1 / FLOW-1 (Pkg N): the generic Import Error alert
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

    private var masthead: some View {
        VStack(spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: heroSymbol)
                .font(.system(size: 56))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            Text("Resecta")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)

            Text("On-device PDF redaction designed to remove the underlying content.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .accessibilityElement(children: .combine)
    }

    private var choiceStack: some View {
        VStack(spacing: ResectaTokens.Spacing.md) {
            HomeChoiceCard(
                symbol: "doc.badge.plus",
                style: .primary,
                title: "Open a Document",
                bodyText: "Import a PDF from Files. Nothing is uploaded.",
                affordance: "Choose File →",
                action: { showFilePicker = true }
            )

            HomeChoiceCard(
                symbol: "sparkles",
                style: .subtle,
                title: "Try the Sample",
                bodyText: "Open a bundled sample bank statement to see what Resecta does before importing your own.",
                affordance: "Open Sample →",
                action: { openSampleDocument() }
            )
        }
        .frame(maxWidth: columnMaxWidth)
    }

    private var trustStrip: some View {
        FlowLayout(spacing: ResectaTokens.Spacing.sm, alignment: .center) {
            TrustItem(label: "On-device")
            Text("·").foregroundStyle(.tertiary).font(.caption)
            TrustItem(label: "No tracking")
            Text("·").foregroundStyle(.tertiary).font(.caption)
            TrustItem(label: "Open source")
        }
        .frame(maxWidth: columnMaxWidth)
    }

    private var footer: some View {
        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ResectaTokens.Spacing.sm)
    }

    // MARK: - Import

    private func handleFileImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                await appCoordinator.openRedactWithDocument(url: url)
            }
        case .failure(let error):
            // User cancellation returns CocoaError.userCancelled — no surface needed.
            if (error as? CocoaError)?.code == .userCancelled { return }
            // Q-FLOW-1 / FLOW-1 (Pkg N): open a fresh workspace and drive
            // its DocumentState to `.failed(.importError(.corrupt))`. The
            // workspace's FailedStateView is the same surface a corrupt-
            // file import (from inside the workspace) lands on; threading
            // the HomeView failure through the same route removes the
            // prior dual-surface design (HomeView alert + workspace
            // FailedStateView). The user reaches workspace chrome and
            // can re-import via the standard recovery affordance.
            appCoordinator.openRedact()
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
    // The "Try the Sample" card is a permanent affordance
    // by design, so this path no longer flips a first-run flag.
    // The dead `hasCompletedFirstRun` @AppStorage write+declaration (it had no
    // reader anywhere in Sources/) was removed.
    private func openSampleDocument() {
        Task {
            appCoordinator.openRedact()
            guard case .redact(let workspace) = appCoordinator.activeWorkspace else { return }
            await ImportService.loadSampleDocument(
                documentState: workspace.documentState,
                redactionState: workspace.redactionState
            )
        }
    }
}
