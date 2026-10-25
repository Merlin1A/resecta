import Testing
import Foundation
@testable import ResectaApp

// The first-launch sequence: the agreement under a key bumped for the 1.3.0
// terms (so a 1.2.0 install agrees again), then the developer's note once
// per install, then the app. The order is pure (`FirstLaunchFlow.screen`);
// the keys are read from a scratch defaults suite the way the app reads
// the standard one; the wiring and the note's chrome are read from the
// sources, as the home screen's contract tests read theirs.

@Suite("First-launch flow")
struct FirstLaunchFlowTests {

    static let appPath = "Sources/ResectaApp/App/ResectaApp.swift"
    static let gatePath = "Sources/ResectaApp/Views/EULAGateView.swift"
    static let notePath = "Sources/ResectaApp/Views/DeveloperNoteView.swift"
    static let flowPath = "Sources/ResectaApp/App/FirstLaunchFlow.swift"

    // MARK: - Keys

    @Test("The agreement key is bumped past the one 1.0.0–1.2.0 shipped, which is now superseded")
    func agreementKeyBumped() {
        #expect(FirstLaunchFlow.agreementKey == "disclaimerAccepted_v2")
        #expect(FirstLaunchFlow.supersededAgreementKeys == ["disclaimerAccepted_v1"])
        #expect(!FirstLaunchFlow.supersededAgreementKeys.contains(FirstLaunchFlow.agreementKey))
    }

    @Test("The note's key is its own, so a later terms bump brings back the agreement but not the note")
    func noteKeyIndependent() {
        let agreementKeys = [FirstLaunchFlow.agreementKey] + FirstLaunchFlow.supersededAgreementKeys
        #expect(!agreementKeys.contains(FirstLaunchFlow.noteSeenKey))
        #expect(!FirstLaunchFlow.noteSeenKey.hasPrefix("disclaimerAccepted"))
    }

    // MARK: - Order

    @Test("A fresh install opens on the agreement")
    func freshInstall() {
        withScratchDefaults { defaults in
            #expect(screen(in: defaults) == .agreement)
        }
    }

    @Test("A 1.2.0 install (the old key accepted, the note never seen) opens on the agreement again")
    func upgradeFromAcceptedEarlierTerms() {
        withScratchDefaults { defaults in
            defaults.set(true, forKey: "disclaimerAccepted_v1")
            #expect(screen(in: defaults) == .agreement)
        }
    }

    @Test("Agree leads to the note; Continue leads to the app; a relaunch stays in the app")
    func agreeThenNoteThenApp() {
        withScratchDefaults { defaults in
            defaults.set(true, forKey: FirstLaunchFlow.agreementKey)
            #expect(screen(in: defaults) == .note)
            defaults.set(true, forKey: FirstLaunchFlow.noteSeenKey)
            #expect(screen(in: defaults) == .app)
            // A relaunch reads the same two flags.
            #expect(screen(in: defaults) == .app)
        }
    }

    @Test("A note seen under earlier terms is not shown again after the next Agree")
    func noteSeenSurvivesTermsBump() {
        #expect(FirstLaunchFlow.screen(agreementAccepted: false, noteSeen: true) == .agreement)
        #expect(FirstLaunchFlow.screen(agreementAccepted: true, noteSeen: true) == .app)
    }

    // MARK: - Wiring

    @Test("The app and the gate read the agreement key through FirstLaunchFlow; no other source names a versioned key")
    func keysHaveOneHome() throws {
        let app = try loadRepoFile(Self.appPath)
        let gate = try loadRepoFile(Self.gatePath)
        #expect(app.contains("@AppStorage(FirstLaunchFlow.agreementKey)"))
        #expect(app.contains("@AppStorage(FirstLaunchFlow.noteSeenKey)"))
        #expect(gate.contains("@AppStorage(FirstLaunchFlow.agreementKey)"))
        #expect(gate.contains("FirstLaunchFlow.supersededAgreementKeys"), "Agree clears the superseded flags")
        let sources = try swiftFiles(under: repoRoot().appendingPathComponent("Sources"))
        for file in sources where !file.path.hasSuffix(Self.flowPath) {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("disclaimerAccepted_v"), "\(file.lastPathComponent) names a versioned agreement key")
            #expect(!text.contains("developerNoteSeen_v"), "\(file.lastPathComponent) names the note's key")
        }
    }

    @Test("The root swaps on the flow's screen, and the note fades like the gate under Reduce Motion")
    func rootGateWiring() throws {
        let app = try loadRepoFile(Self.appPath)
        #expect(app.contains("FirstLaunchFlow.screen("))
        #expect(app.contains("DeveloperNoteView()"))
        #expect(app.contains("value: screen)"), "the swap animates on the screen, not on acceptance alone")
        #expect(app.contains("reduceMotion: reduceMotion"))
    }

    @Test("--uitesting passes both first-launch screens; --resetEULA and --seedLegacyAcceptance show the gate")
    func launchHooks() throws {
        let app = try loadRepoFile(Self.appPath)
        #expect(app.contains("defaults.set(true, forKey: FirstLaunchFlow.noteSeenKey)"))
        #expect(app.contains("\"--seedLegacyAcceptance\""))
        let hooks = try #require(app.range(of: "private static func handleUITestLaunchArguments()"))
        let debugOpen = try #require(app.range(of: "#if DEBUG\n    /// Handle launch arguments for UI testing."))
        #expect(debugOpen.lowerBound < hooks.lowerBound, "the hooks stay DEBUG-only")
    }

    // MARK: - The note's chrome

    @Test("The note wears the gate's chrome: the mark, a header, a pinned bottom button, the grouped background")
    func noteChrome() throws {
        let note = try loadRepoFile(Self.notePath)
        #expect(note.contains("HomeMark("))
        #expect(note.contains("dynamicTypeSize.isAccessibilitySize"), "the mark hides at the accessibility sizes, as on the gate")
        #expect(note.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(note.contains(".safeAreaBar(edge: .bottom)"))
        #expect(note.contains(".scrollEdgeEffectStyle(.soft, for: .bottom)"))
        #expect(note.contains("systemGroupedBackground"))
        #expect(note.contains("ScrollView"), "AX5 text scrolls rather than clips")
        for id in ["developerNoteBody", "developerNoteContinue"] {
            #expect(note.contains(".accessibilityIdentifier(\"\(id)\")"), "\(id)")
        }
        #expect(note.contains("noteSeen = true"), "Continue records the note as seen")
    }

    @Test("The note adds no hand-off: its address is plain text")
    func noteHasNoLink() throws {
        let note = try loadRepoFile(Self.notePath)
        #expect(!note.contains("mailto:"))
        #expect(!note.contains("http"))
        #expect(!note.contains("openURL"))
        #expect(!note.contains("Link("))
    }

    // MARK: - The note's copy

    @Test("The note's words are the approved ones")
    func noteCopy() {
        #expect(DeveloperNoteView.title == "Why I Made Resecta")
        #expect(DeveloperNoteView.continueLabel == "Continue")
        #expect(DeveloperNoteView.signature == "\u{2014} Jesse")
        #expect(DeveloperNoteView.paragraphs.count == 8)
        #expect(DeveloperNoteView.paragraphs.first == "Hi, I\u{2019}m Jesse, & thank you for trying Resecta.")
        #expect(DeveloperNoteView.paragraphs.last == "If something looks wrong, or you have an idea, write to me at jesse@resecta.app.")
    }

    @Test("The note carries no outcome-promise or ranking word")
    func noteVoiceFence() {
        let all = ([DeveloperNoteView.title, DeveloperNoteView.continueLabel] + DeveloperNoteView.paragraphs)
        var text = all.joined(separator: "\n").lowercased()
        // The author's wording, none of it a promise about Resecta:
        // each phrase is lifted out before the word check, and must still
        // be in the note, so a stale exemption fails here.
        for phrase in ["they do best with", "finding and exploiting", "no software is perfect"] { // LegalPhrases:safe
            #expect(text.contains(phrase), "\(phrase)")
            text = text.replacingOccurrences(of: phrase, with: "")
        }
        for banned in LegalPhrases.bannedTerms {
            #expect(!text.contains(banned.lowercased()), "\(banned)")
        }
        for word in ["best", "secure", "safe", "guarantee", "ensure", "impossible", "perfect", "flawless", "verified", "catch", "find"] { // LegalPhrases:safe (the lint's own word list)
            #expect(text.range(of: "\\b\(word)", options: .regularExpression) == nil, "\(word)")
        }
        #expect(!text.contains("!"))
        #expect(!text.contains("100"))
    }

    // MARK: - Helpers

    private func screen(in defaults: UserDefaults) -> FirstLaunchFlow.Screen {
        FirstLaunchFlow.screen(
            agreementAccepted: defaults.bool(forKey: FirstLaunchFlow.agreementKey),
            noteSeen: defaults.bool(forKey: FirstLaunchFlow.noteSeenKey))
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
