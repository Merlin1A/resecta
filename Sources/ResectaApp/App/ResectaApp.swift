import SwiftUI
import RedactionEngine

// ARCH §4.2: @main entry point with environment injection.
// ARCH §6.1: First-launch clickwrap gates the entire app.
// MainActor by default (SE-0466, Xcode 26 app target).
@main
struct ResectaApp: App {
    // ARCH §6.1: Persist EULA acceptance. @AppStorage is fine in App struct (R6
    // only prohibits @AppStorage inside @Observable classes).
    // Versioned key for EULA re-acceptance on terms change.
    // The key-history list + superseded-key cleanup live in EULAGateView
    // (the acceptance site). Bump this key and EULAGateView's in lockstep.
    @AppStorage("disclaimerAccepted_v1") private var disclaimerAccepted = false
    @State private var settingsState: SettingsState
    @State private var savedRegexStore: SavedRegexStore
    @State private var userTermsStore: UserTermsStore
    /// Saved-searches store — consumed by SavedSearchListSheet;
    /// app-wide like its sibling stores.
    @State private var savedSearchStore: SavedSearchStore
    @State private var appCoordinator: AppCoordinator
    // SEC-3: Screen-capture / mirroring privacy shield. Owned at the
    // WindowGroup level so every workspace observes the same monitor
    // instance via @Environment.
    @State private var screenCaptureMonitor: ScreenCaptureMonitor

    // SEC-4: App-snapshot privacy overlay flag, lifted from ContentView to
    // the WindowGroup root so the overlay can sit as a ZStack peer at the
    // top of the view tree. Root-level placement is intended to cover the
    // full window on iPad Stage Manager + split-view (where ContentView's
    // own layout would not span the whole scene).
    // See plan §3 SEC-4 and §0.1 (no animation change to the obscure path).
    @State private var obscureContent = false

    // Tracks scene phase at the root so we can drive `obscureContent`
    // alongside the existing pipeline-cancel behavior.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Pin the cold-start baseline at the earliest user-controllable
        // point. First-call-wins; release builds compile to a no-op shim.
        // Pairs with the DataPipeline `bundle_size.json` build probe via
        // `_meta.git_head` (engineer-facing diagnostic; not consumed at runtime).
        ColdStartTimer.shared.captureProcessStart()

        // Recents privacy: one-shot removal of the recents lists
        // persisted by earlier builds (recents are private-by-default
        // now; see the flag guard on the callee).
        SearchState.deletePersistedRecentsOnce()

        // App-wide stores for the power-user library: saved regexes and
        // always/never-flag custom terms. Both persist via UserDefaults
        // JSON blobs and are read by the search trigger path at scan
        // kickoff.
        let regexStore = SavedRegexStore()
        let termsStore = UserTermsStore()
        let searchStore = SavedSearchStore()
        let set = SettingsState()
        _savedRegexStore = State(initialValue: regexStore)
        _userTermsStore = State(initialValue: termsStore)
        _savedSearchStore = State(initialValue: searchStore)
        _settingsState = State(initialValue: set)
        _appCoordinator = State(initialValue: AppCoordinator(settingsState: set))
        // SEC-3: instantiate alongside AppCoordinator. The monitor begins
        // observing UIScreen notifications immediately in its init.
        _screenCaptureMonitor = State(initialValue: ScreenCaptureMonitor())
        // R7/D10: Disable shake-to-undo — accidental shakes during precision
        // drawing are disruptive. Toolbar buttons are the sole undo mechanism.
        UIApplication.shared.applicationSupportsShakeToEdit = false

        #if DEBUG
        Self.handleUITestLaunchArguments()
        #endif
    }

    #if DEBUG
    /// Handle launch arguments for UI testing.
    /// --uitesting: Auto-accept EULA to bypass the gate.
    /// --resetEULA: Clear the acceptance flag so the gate PRESENTS — the
    ///   gate-links UI tests drive the un-accepted gate itself, the
    ///   inverse of --uitesting. DEBUG-only, and it only ever forces the
    ///   gate ON; it adds no path past it.
    private static func handleUITestLaunchArguments() {
        if CommandLine.arguments.contains("--resetEULA") {
            UserDefaults.standard.set(false, forKey: "disclaimerAccepted_v1")
        } else if CommandLine.arguments.contains("--uitesting") {
            UserDefaults.standard.set(true, forKey: "disclaimerAccepted_v1")
        }
    }

    /// S7 sim-verification: `--searchMode=` arg value → SearchModeType.
    /// Arg names are a stable external contract (verification scripts +
    /// UI tests), mapped to cases directly so a wire-value change can't
    /// silently break the hook.
    static let searchModeArgMap: [String: SearchModeType] = [
        "text": .text,
        "regex": .regex,
        "multiTerm": .multiTerm,
        "piiScan": .piiScan,
    ]
    #endif

    var body: some Scene {
        WindowGroup {
            // SEC-4: Root-level ZStack peers the snapshot-privacy overlay
            // with the main scene content. Promoting to the WindowGroup
            // root (rather than nesting inside ContentView) is intended to
            // cover the full window on iPad Stage Manager and split-view.
            ZStack {
                // UI_UX §6.4: EULA gate — show clickwrap before any app content
                if disclaimerAccepted {
                    ContentView()
                        .environment(settingsState)
                        .environment(savedRegexStore)
                        .environment(userTermsStore)
                        .environment(savedSearchStore)
                        .environment(appCoordinator)
                        .environment(screenCaptureMonitor)
                        // DEBUG launch-argument hooks (test-document load,
                        // triage seeding, search-sheet presentation, capture
                        // simulation). The orphan-temp sweep moved to
                        // a ZStack-level `.task` so it fires
                        // regardless of the EULA gate.
                        .task {
                            #if DEBUG
                            // `--seedTriage` implies the test-document load so
                            // the editor (DocumentEditorView) and its single
                            // `.sheet(item:)` slot are mounted before the mock
                            // triage state is seeded.
                            let launchArguments = CommandLine.arguments
                            if launchArguments.contains("--loadTestDocument")
                                || launchArguments.contains("--seedTriage")
                                || launchArguments.contains("--openSearchSheet")
                                || launchArguments.contains("--openSavedSearches") {
                                appCoordinator.openRedact()
                                if case .redact(let ws) = appCoordinator.activeWorkspace {
                                    // `--multipageDoc` swaps the single-page
                                    // sample for a bundled multi-page fixture
                                    // so the triage → Dismiss path runs with a
                                    // real paginated document behind the sheet
                                    // (the editor's page-strip layout, which
                                    // the Dismiss toast's synchronous graph
                                    // flush re-resolves, differs by page count).
                                    let sampleName = launchArguments.contains("--multipageDoc")
                                        ? "uitest_multipage" : "test_sample"
                                    await ImportService.loadSampleDocument(
                                        named: sampleName,
                                        documentState: ws.documentState,
                                        redactionState: ws.redactionState)
                                    // DEBUG triage repro hook: seed mock
                                    // detections so the "Review Detections"
                                    // sheet presents on the Simulator without
                                    // running on-device detection (which the
                                    // sim cannot service). The sheet appears
                                    // because its `.sheet(item:)` getter returns
                                    // `.triage` when `pendingTriage != nil`.
                                    if launchArguments.contains("--seedTriage") {
                                        ws.redactionState.seedDebugTriage()
                                    }
                                    // Sim-verification hook: present the
                                    // Search & Redact sheet on the loaded test
                                    // document. Implies the document load via
                                    // the trigger condition above.
                                    if launchArguments.contains("--openSearchSheet")
                                        || launchArguments.contains("--openSavedSearches") {
                                        let seeded = SearchState()
                                        // S7 sim-verification hooks (read-only
                                        // MCP; verification.md §6):
                                        // `--searchMode=<text|regex|multiTerm|piiScan>`
                                        // sets the initial mode so per-mode
                                        // surfaces (saved-regex menu, piiScan
                                        // empty state) are screenshotable
                                        // without taps.
                                        if let modeArg = launchArguments
                                            .first(where: { $0.hasPrefix("--searchMode=") })?
                                            .split(separator: "=").last,
                                           let mode = Self.searchModeArgMap[String(modeArg)] {
                                            seeded.searchModeType = mode
                                        }
                                        ws.redactionState.activeSearch = seeded
                                        // `--openSavedSearches` (S7 §4.1) also
                                        // seeds one sample row so the list
                                        // screenshot shows a populated state;
                                        // the sheet itself presents from
                                        // SearchAndRedactSheet.onAppear.
                                        if launchArguments.contains("--openSavedSearches"),
                                           savedSearchStore.savedSearches.isEmpty {
                                            savedSearchStore.add(SavedSearch(
                                                name: "Sample: PII scan",
                                                mode: .piiScan,
                                                enabledPIICategories: [.ssn, .ein, .routingNumber]
                                            ))
                                        }
                                    }
                                }
                            }
                            // S6 / C10 sim-verification hook: drive the SEC-3
                            // monitor's DEBUG seam at launch. UIScreen.isCaptured
                            // cannot be forced on the simulator from outside the
                            // process, and this machine's MCP UI is read-only
                            // (no taps) — the launch arg is the sanctioned route
                            // per verification.md §6.
                            if launchArguments.contains("--simulateCapture") {
                                screenCaptureMonitor._setForTesting(
                                    isCaptured: true, isMirroring: false
                                )
                            }
                            #endif
                        }
                } else {
                    EULAGateView()
                }

                // SEC-4: Branded placeholder rendered above all content
                // when the scene is inactive or backgrounded.
                if obscureContent {
                    SnapshotPrivacyOverlay()
                }
            }
            // Clean orphaned temp files from prior
            // sessions on every launch. Attached to the ZStack (which wraps
            // BOTH the EULA gate and ContentView) so the sweep fires
            // regardless of `disclaimerAccepted` — a crash during a session
            // before EULA acceptance (or a EULA-version bump) previously left
            // orphans unswept until the user accepted. Detached `.utility`
            // task so it does not block MainActor at launch.
            .task {
                Task.detached(priority: .utility) {
                    cleanOrphanedTempFiles()
                }
            }
            // SEC-4: Drive `obscureContent` from scene-phase transitions at
            // the root so the overlay is in the view hierarchy before the
            // system takes its snapshot. The obscure path is synchronous
            // (`withAnimation(.none)`) per §0.1 — animating it would let
            // the snapshot land mid-fade. The reveal path keeps the prior
            // 0.15s ease-in for visual polish on return-to-foreground.
            .onChange(of: scenePhase) { _, newPhase in
                switch SnapshotPrivacyPolicy.action(for: newPhase) {
                case .obscureSynchronously:
                    withAnimation(.none) { obscureContent = true }
                case .revealAnimated:
                    withAnimation(.easeIn(duration: 0.15)) { obscureContent = false }
                case .none:
                    break
                }
            }
            // 02-dark-mode-design.md §5: apply the user's appearance
            // preference at the WindowGroup root. `.system` resolves to
            // `nil` so the OS-level Light/Dark setting is honored.
            .preferredColorScheme(settingsState.appearancePreference.colorScheme)
            // CD-19: ambient brand tint at the root. The AccentColor colorset
            // (same pair, lockstep-tested) is not adopted as the global tint
            // by the iOS 26.4 simulator runtime, so SwiftUI ambient color is
            // pinned here; the colorset still themes system-presented chrome
            // wherever the OS honors it.
            .tint(ResectaTokens.BrandTeal.tint)
        }
    }
}
