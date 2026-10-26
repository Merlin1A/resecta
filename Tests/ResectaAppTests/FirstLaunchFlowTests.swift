import Testing
import Foundation
@testable import ResectaApp

// The first-launch sequence: the agreement under a key bumped for the 1.3.0
// terms (so a 1.2.0 install agrees again), then the app. The order is pure
// (`FirstLaunchFlow.screen`); the keys are read from a scratch defaults
// suite the way the app reads the standard one; the wiring is read from the
// sources, as the home screen's contract tests read theirs.

@Suite("First-launch flow")
struct FirstLaunchFlowTests {

    static let appPath = "Sources/ResectaApp/App/ResectaApp.swift"
    static let gatePath = "Sources/ResectaApp/Views/EULAGateView.swift"
    static let flowPath = "Sources/ResectaApp/App/FirstLaunchFlow.swift"

    // MARK: - Keys

    @Test("The agreement key is bumped past the one 1.0.0–1.2.0 shipped, which is now superseded")
    func agreementKeyBumped() {
        #expect(FirstLaunchFlow.agreementKey == "disclaimerAccepted_v2")
        #expect(FirstLaunchFlow.supersededAgreementKeys == ["disclaimerAccepted_v1"])
        #expect(!FirstLaunchFlow.supersededAgreementKeys.contains(FirstLaunchFlow.agreementKey))
    }

    // MARK: - Order

    @Test("A fresh install opens on the agreement")
    func freshInstall() {
        withScratchDefaults { defaults in
            #expect(screen(in: defaults) == .agreement)
        }
    }

    @Test("A 1.2.0 install (the old key accepted) opens on the agreement again")
    func upgradeFromAcceptedEarlierTerms() {
        withScratchDefaults { defaults in
            defaults.set(true, forKey: "disclaimerAccepted_v1")
            #expect(screen(in: defaults) == .agreement)
        }
    }

    @Test("Agree leads straight to the app; a relaunch stays in the app")
    func agreeThenApp() {
        withScratchDefaults { defaults in
            defaults.set(true, forKey: FirstLaunchFlow.agreementKey)
            #expect(screen(in: defaults) == .app)
            // A relaunch reads the same flag.
            #expect(screen(in: defaults) == .app)
        }
    }

    @Test("The agreement is the only first-launch screen: unaccepted shows it, accepted shows the app")
    func agreementOnlyFlow() {
        #expect(FirstLaunchFlow.screen(agreementAccepted: false) == .agreement)
        #expect(FirstLaunchFlow.screen(agreementAccepted: true) == .app)
    }

    @Test("The developer's note does not come back: no view file and no seen-flag key under Sources")
    func noDeveloperNote() throws {
        #expect(!FileManager.default.fileExists(atPath: repoRoot()
            .appendingPathComponent("Sources/ResectaApp/Views/DeveloperNoteView.swift").path))
        let sources = try swiftFiles(under: repoRoot().appendingPathComponent("Sources"))
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("developerNoteSeen"), "\(file.lastPathComponent) names the retired note's key")
        }
    }

    // MARK: - Wiring

    @Test("The app and the gate read the agreement key through FirstLaunchFlow; no other source names a versioned key")
    func keysHaveOneHome() throws {
        let app = try loadRepoFile(Self.appPath)
        let gate = try loadRepoFile(Self.gatePath)
        #expect(app.contains("@AppStorage(FirstLaunchFlow.agreementKey)"))
        #expect(gate.contains("@AppStorage(FirstLaunchFlow.agreementKey)"))
        #expect(gate.contains("FirstLaunchFlow.supersededAgreementKeys"), "Agree clears the superseded flags")
        let sources = try swiftFiles(under: repoRoot().appendingPathComponent("Sources"))
        for file in sources where !file.path.hasSuffix(Self.flowPath) {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("disclaimerAccepted_v"), "\(file.lastPathComponent) names a versioned agreement key")
        }
    }

    @Test("The root swaps on the flow's screen, and the gate fades under Reduce Motion")
    func rootGateWiring() throws {
        let app = try loadRepoFile(Self.appPath)
        #expect(app.contains("FirstLaunchFlow.screen("))
        #expect(app.contains("value: screen)"), "the swap animates on the screen, not on acceptance alone")
        #expect(app.contains("reduceMotion: reduceMotion"))
    }

    @Test("--uitesting passes the gate; --resetEULA and --seedLegacyAcceptance show it")
    func launchHooks() throws {
        let app = try loadRepoFile(Self.appPath)
        #expect(app.contains("defaults.set(true, forKey: FirstLaunchFlow.agreementKey)"))
        #expect(app.contains("defaults.set(false, forKey: FirstLaunchFlow.agreementKey)"))
        #expect(app.contains("\"--seedLegacyAcceptance\""))
        #expect(app.contains("\"--resetEULA\""))
        #expect(app.contains("\"--uitesting\""))
        let hooks = try #require(app.range(of: "private static func handleUITestLaunchArguments()"))
        let debugOpen = try #require(app.range(of: "#if DEBUG\n    /// Handle launch arguments for UI testing."))
        #expect(debugOpen.lowerBound < hooks.lowerBound, "the hooks stay DEBUG-only")
    }

    // MARK: - Helpers

    private func screen(in defaults: UserDefaults) -> FirstLaunchFlow.Screen {
        FirstLaunchFlow.screen(
            agreementAccepted: defaults.bool(forKey: FirstLaunchFlow.agreementKey))
    }

    private func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func loadRepoFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
