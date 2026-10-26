import SwiftUI
import RedactionEngine

// @main entry point with environment injection.
// First-launch clickwrap gates the entire app.
// MainActor by default (SE-0466, Xcode 26 app target).
@main
struct ResectaApp: App {
    // Persist EULA acceptance. @AppStorage is fine in App struct —
    // it only prohibits @AppStorage inside @Observable classes.
    // Versioned key for EULA re-acceptance on terms change; the key and its
    // history live in `FirstLaunchFlow`, shared with EULAGateView (the
    // acceptance site).
    @AppStorage(FirstLaunchFlow.agreementKey) private var disclaimerAccepted = false
    @State private var settingsState: SettingsState
    @State private var savedRegexStore: SavedRegexStore
    @State private var userTermsStore: UserTermsStore
    /// Saved-searches store — consumed by SavedSearchListSheet;
    /// app-wide like its sibling stores.
    @State private var savedSearchStore: SavedSearchStore
    @State private var appCoordinator: AppCoordinator
    // Screen-capture / mirroring privacy shield. Owned at the
    // WindowGroup level so every workspace observes the same monitor
    // instance via @Environment.
    @State private var screenCaptureMonitor: ScreenCaptureMonitor

    // App-snapshot privacy overlay flag, lifted from ContentView to
    // the WindowGroup root so the overlay can sit as a ZStack peer at the
    // top of the view tree. Root-level placement is intended to cover the
    // full window on iPad Stage Manager + split-view (where ContentView's
    // own layout would not span the whole scene). No animation change to
    // the obscure path here.
    @State private var obscureContent = false
    // The cover's own window: above presented sheets, which the ZStack
    // overlay below does not reach (`SnapshotPrivacyWindowController`).
    @State private var privacyWindow = SnapshotPrivacyWindowController()

    // Tracks scene phase at the root so we can drive `obscureContent`
    // alongside the existing pipeline-cancel behavior.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The persisted-recents feature is excised. Sweep its
        // four retired storage keys out of existing installs at every
        // launch — unconditional and idempotent (no marker key).
        SearchState.purgeRetiredRecentsStorage()

        // App-wide stores for the power-user library: saved regexes and
        // always/never-flag custom terms. Both persist as protected,
        // backup-excluded JSON files under Application Support (the
        // `SavedSearchStore` posture; pre-file installs migrate off
        // their UserDefaults keys once at init) and are read by the
        // search trigger path at scan kickoff.
        let regexStore = SavedRegexStore()
        let termsStore = UserTermsStore()
        let searchStore = SavedSearchStore()
        let set = SettingsState()
        _savedRegexStore = State(initialValue: regexStore)
        _userTermsStore = State(initialValue: termsStore)
        _savedSearchStore = State(initialValue: searchStore)
        _settingsState = State(initialValue: set)
        _appCoordinator = State(initialValue: AppCoordinator(settingsState: set, userTermsStore: termsStore))
        // Instantiate alongside AppCoordinator. The monitor begins
        // observing UIScreen notifications immediately in its init.
        _screenCaptureMonitor = State(initialValue: ScreenCaptureMonitor())
        // Disable shake-to-undo — accidental shakes during precision
        // drawing are disruptive. Toolbar buttons are the sole undo mechanism.
        UIApplication.shared.applicationSupportsShakeToEdit = false

        #if DEBUG
        Self.handleUITestLaunchArguments()
        #endif
    }

    #if DEBUG
    /// Handle launch arguments for UI testing.
    /// --uitesting: Auto-accept EULA to bypass the first-launch gate, and
    ///   clear the
    ///   persisted last-filter shape so every test launch opens the
    ///   search sheet at the default Source=All. The cross-session
    ///   filter persistence is a shipped feature; a non-default source
    ///   filter left in the app container by a manual drive filter-hides
    ///   text-layer results and deterministically reds the XCUI
    ///   text-search suites. Per-launch and test-only: release launches
    ///   never pass the flag, and in-session persistence still works
    ///   after the launch-time clear.
    /// --resetEULA: Clear the acceptance flag so the gate PRESENTS — the
    ///   gate-links UI tests drive the un-accepted gate itself, the
    ///   inverse of --uitesting. DEBUG-only, and it only ever forces the
    ///   gate ON; it adds no path past it.
    /// --seedLegacyAcceptance: The state of a 1.2.0 install — the old
    ///   agreement key accepted, the current one unseen — so
    ///   the upgrade path can be driven. Forces the gate ON, like the above.
    /// --searchSourceFilter=ocr: Write a persisted Source = OCR filter
    ///   AFTER the --uitesting clear, so the next search sheet opens
    ///   filtered to OCR rows — the state a born-digital document must
    ///   be able to leave from inside the sheet.
    private static func handleUITestLaunchArguments() {
        let defaults = UserDefaults.standard
        if CommandLine.arguments.contains("--seedLegacyAcceptance") {
            for key in FirstLaunchFlow.supersededAgreementKeys {
                defaults.set(true, forKey: key)
            }
            defaults.removeObject(forKey: FirstLaunchFlow.agreementKey)
        } else if CommandLine.arguments.contains("--resetEULA") {
            defaults.set(false, forKey: FirstLaunchFlow.agreementKey)
        } else if CommandLine.arguments.contains("--uitesting") {
            defaults.set(true, forKey: FirstLaunchFlow.agreementKey)
            defaults.removeObject(forKey: "search.lastFilter.v1")
        }
        if CommandLine.arguments.contains("--searchSourceFilter=ocr"),
           let data = try? JSONEncoder().encode(SearchState.LastSearchFilterShape(
               sourceFilter: .ocrOnly, minimumOCRConfidence: 0, sortOrder: .discoveryOrder
           )) {
            UserDefaults.standard.set(data, forKey: "search.lastFilter.v1")
        }
    }

    /// Sim-verification: `--searchMode=` arg value → SearchModeType.
    /// Arg names are a stable external contract (verification scripts +
    /// UI tests), mapped to cases directly so a wire-value change can't
    /// silently break the hook.
    static let searchModeArgMap: [String: SearchModeType] = [
        "text": .text,
        "regex": .regex,
        "multiTerm": .multiTerm,
        "piiScan": .piiScan,
    ]

    /// Launch arguments that swap the `--loadTestDocument` fixture for a
    /// different bundled synthetic (UITestFixtures/, Debug only). The
    /// first matching argument wins; none present = the single-page
    /// `test_sample`. Fixture names are the bundle resource names.
    static let fixtureArgMap: [String: String] = [
        // 23-page workpaper: paginated editor + page strip.
        "--multipageDoc": "uitest_multipage",
        // One page carrying a link annotation over its central band
        // (Scripts/generate_uitest_link.py): the editor's link policy.
        "--linkDoc": "uitest_link",
    ]

    /// The `--loadTestDocument` fixture name for a launch-argument list.
    static func testDocumentName(for arguments: [String]) -> String {
        arguments.lazy.compactMap { fixtureArgMap[$0] }.first ?? "test_sample"
    }

    /// The bundled synthetic image `--loadTestImage` opens through the
    /// image loader (UITestFixtures/, Debug only): `--loadTestImage=<name>`
    /// names one; the bare flag, or the flag followed by a name, opens
    /// `uitest_image`. Nil when the flag is absent.
    static func testImageName(for arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--loadTestImage=") {
                let name = String(argument.dropFirst("--loadTestImage=".count))
                return name.isEmpty ? "uitest_image" : name
            }
            if argument == "--loadTestImage" {
                let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
                if let next, !next.hasPrefix("--") { return next }
                return "uitest_image"
            }
        }
        return nil
    }
    #endif

    var body: some Scene {
        WindowGroup {
            // Root-level ZStack peers the snapshot-privacy overlay
            // with the main scene content. Promoting to the WindowGroup
            // root (rather than nesting inside ContentView) is intended to
            // cover the full window on iPad Stage Manager and split-view.
            ZStack {
                // EULA gate — show clickwrap before any app content; the
                // host fades the gate out and the app in.
                RootGate(screen: FirstLaunchFlow.screen(
                    agreementAccepted: disclaimerAccepted)) {
                    ContentView()
                        .environment(settingsState)
                        .environment(savedRegexStore)
                        .environment(userTermsStore)
                        .environment(savedSearchStore)
                        .environment(appCoordinator)
                        .environment(screenCaptureMonitor)
                        // DEBUG launch-argument hooks (test-document load,
                        // search-sheet presentation, capture
                        // simulation). The orphan-temp sweep moved to
                        // a ZStack-level `.task` so it fires
                        // regardless of the EULA gate.
                        .task {
                            #if DEBUG
                            let launchArguments = CommandLine.arguments
                            if launchArguments.contains("--loadTestDocument")
                                || Self.testImageName(for: launchArguments) != nil
                                || launchArguments.contains("--openSearchSheet")
                                || launchArguments.contains("--openSavedSearches")
                                || launchArguments.contains(where: { $0.hasPrefix("--seedVerifiedReport=") }) {
                                appCoordinator.openRedact()
                                if case .redact(let ws) = appCoordinator.activeWorkspace {
                                    // `--multipageDoc` swaps the single-page
                                    // sample for a bundled multi-page fixture
                                    // so a UI test runs with a real paginated
                                    // document behind the sheet;
                                    // `--linkDoc` loads the one-page link
                                    // fixture. See `fixtureArgMap`.
                                    let sampleName = Self.testDocumentName(
                                        for: launchArguments)
                                    if let imageName = Self.testImageName(for: launchArguments) {
                                        // `--loadTestImage`: one bundled synthetic
                                        // image through the image loader, the
                                        // path the out-of-process Photos picker
                                        // cannot be driven down by a UI test.
                                        await ImportService.loadTestImage(
                                            named: imageName,
                                            documentState: ws.documentState,
                                            redactionState: ws.redactionState)
                                    } else {
                                        await ImportService.loadSampleDocument(
                                            named: sampleName,
                                            documentState: ws.documentState,
                                            redactionState: ws.redactionState)
                                    }
                                    // `--seedVerifiedReport=<name>`: the results
                                    // screen on a forged report
                                    // (`VerificationDebugFixtures`), reached by
                                    // the phase machine's own legal steps; an
                                    // unknown name seeds nothing.
                                    if let name = launchArguments
                                        .first(where: { $0.hasPrefix("--seedVerifiedReport=") })?
                                        .split(separator: "=").last,
                                       let report = VerificationDebugFixtures.all[String(name)] {
                                        // `--seedOutput`: a copy of the loaded
                                        // sample stands in for the redacted PDF,
                                        // so Share, its confirm and Preview are
                                        // live; the fixture's run inputs carry
                                        // the mode and the run facts.
                                        if launchArguments.contains("--seedOutput"),
                                           let source = Bundle.main.url(
                                               forResource: sampleName, withExtension: "pdf") {
                                            let copy = FileManager.default.temporaryDirectory
                                                .appendingPathComponent("seeded-output.pdf")
                                            try? FileManager.default.removeItem(at: copy)
                                            if (try? FileManager.default.copyItem(at: source, to: copy)) != nil {
                                                ws.redactionState.outputURL = copy
                                            }
                                        }
                                        if let run = VerificationDebugFixtures.runInputs(for: String(name)) {
                                            ws.redactionState.recordLastRunInputs(.init(
                                                perPageModes: run.modes, perPageFallbackReasons: run.reasons,
                                                sensitiveTerms: SensitiveTermSet(terms: [], manualRegionsWithoutText: 0),
                                                appliedSearches: [], deselection: nil,
                                                ocrSkippedPages: run.ocrSkippedPages, degradeFailures: nil))
                                        }
                                        ws.documentState.transition(to: .redacting(progress: .init(
                                            currentPage: 1, totalPages: 1, currentStep: "Seeded")))
                                        ws.documentState.transition(to: .verified(report: report))
                                    }
                                    // Sim-verification hook: present the
                                    // Search & Redact sheet on the loaded test
                                    // document. Implies the document load via
                                    // the trigger condition above.
                                    if launchArguments.contains("--openSearchSheet")
                                        || launchArguments.contains("--openSavedSearches") {
                                        let seeded = SearchState()
                                        // Sim-verification hooks (read-only
                                        // MCP):
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
                                        // `--openSavedSearches` also
                                        // seeds one sample row so the list
                                        // screenshot shows a populated state;
                                        // the sheet itself presents from
                                        // SearchAndRedactSheet.onAppear.
                                        if launchArguments.contains("--openSavedSearches"),
                                           savedSearchStore.savedSearches.isEmpty {
                                            savedSearchStore.add(SavedSearch(
                                                name: "Sample: Scan",
                                                mode: .piiScan,
                                                enabledPIICategories: [.ssn, .ein, .routingNumber]
                                            ))
                                        }
                                    }
                                }
                            }
                            // Sim-verification hook: drive the screen-capture
                            // monitor's DEBUG seam at launch. UIScreen.isCaptured
                            // cannot be forced on the simulator from outside the
                            // process, and this machine's MCP UI is read-only
                            // (no taps) — the launch arg is the sanctioned route.
                            if launchArguments.contains("--simulateCapture") {
                                screenCaptureMonitor._setForTesting(
                                    isCaptured: true, isMirroring: false
                                )
                            }
                            #endif
                        }
                }

                // Branded placeholder rendered above all content
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
            // task so it does not block MainActor at launch. The open
            // document's session directory is handed in and left in place.
            .task {
                let live = appCoordinator.liveTempDirectories
                Task.detached(priority: .utility) {
                    cleanOrphanedTempFiles(excluding: live)
                }
            }
            // Drive `obscureContent` (and the orphan sweep, below) from
            // scene-phase transitions at
            // the root so the overlay is in the view hierarchy before the
            // system takes its snapshot. The obscure path is synchronous
            // (`withAnimation(.none)`) — animating it would let
            // the snapshot land mid-fade. The reveal path keeps the prior
            // 0.15s ease-in for visual polish on return-to-foreground.
            .onChange(of: scenePhase) { _, newPhase in
                switch SnapshotPrivacyPolicy.action(for: newPhase) {
                case .obscureSynchronously:
                    withAnimation(.none) { obscureContent = true }
                    privacyWindow.show()
                case .revealAnimated:
                    withAnimation(.easeIn(duration: 0.15)) { obscureContent = false }
                    privacyWindow.hide()
                case .none:
                    break
                }
                // Re-run the orphaned-temp-file sweep on every return
                // to the foreground. The launch `.task` above covers a
                // fresh process; a process that stays resident across many
                // foreground/background cycles would otherwise never sweep
                // again. The sweep is idempotent and TTL-bounded, so each
                // extra run costs one directory listing.
                // The open document's session directory is excluded: a
                // session left open past the one-hour TTL keeps its files.
                if LaunchHygienePolicy.shouldSweepOrphans(on: newPhase) {
                    let live = appCoordinator.liveTempDirectories
                    Task.detached(priority: .utility) {
                        cleanOrphanedTempFiles(excluding: live)
                    }
                }
            }
            // Apply the user's appearance
            // preference at the WindowGroup root. `.system` resolves to
            // `nil` so the OS-level Light/Dark setting is honored.
            .preferredColorScheme(settingsState.appearancePreference.colorScheme)
            // Ambient brand tint at the root. The AccentColor colorset
            // (same pair, lockstep-tested) is not adopted as the global tint
            // by the iOS 26.4 simulator runtime, so SwiftUI ambient color is
            // pinned here; the colorset still themes system-presented chrome
            // wherever the OS honors it.
            .tint(ResectaTokens.BrandTeal.tint)
        }
    }
}

/// The root swap between the first-launch gate and the app, with the fade
/// between them: the gate fades out, then the app fades in after it is
/// gone, so two marks never show together; under Reduce Motion one plain
/// cross-fade. Hosted as a view so it reads the environment.
private struct RootGate<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let screen: FirstLaunchFlow.Screen
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            switch screen {
            case .app:
                content()
                    .transition(.asymmetric(insertion: fadeInAfterRemoval, removal: .opacity))
            case .agreement:
                EULAGateView()
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: fadeOut))
            }
        }
        .animation(ResectaTokens.Anim.resolved(.easeInOut(duration: 0.3), reduceMotion: reduceMotion), value: screen)
    }

    /// Each incoming screen's fade waits out the outgoing one's removal;
    /// under Reduce Motion both legs resolve to one 0.2-s fade and run
    /// together.
    private var fadeInAfterRemoval: AnyTransition {
        let delay: Double = reduceMotion ? 0 : 0.12
        return .opacity.animation(
            ResectaTokens.Anim.resolved(.easeOut(duration: 0.18), reduceMotion: reduceMotion)?.delay(delay))
    }

    private var fadeOut: AnyTransition {
        .opacity.animation(
            ResectaTokens.Anim.resolved(.easeIn(duration: 0.12), reduceMotion: reduceMotion))
    }
}
