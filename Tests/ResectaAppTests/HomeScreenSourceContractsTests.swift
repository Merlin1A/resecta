import Testing
import Foundation
@testable import ResectaApp

// The home screen's contract, read from the sources the way the editor's
// source-contract tests read theirs: the entries' identifiers, hints and
// strings as the copy of record has them; the masthead and the gate title
// as headers; the trust words as one spoken line with no separator glyph
// in the tertiary colour; one open guard per workspace-opening site; the
// app's mark drawn from shapes with no SF Symbol looked up for it; and the
// gate's cross-references by symbol, not by line.

@Suite("Home screen source contracts")
struct HomeScreenSourceContractsTests {

    static let homePath = "Sources/ResectaApp/Views/HomeView.swift"
    static let gatePath = "Sources/ResectaApp/Views/EULAGateView.swift"
    static let cardPath = "Sources/ResectaApp/Views/HomeChoiceCard.swift"
    static let overlayPath = "Sources/ResectaApp/Views/SnapshotPrivacyOverlay.swift"
    static let progressPath = "Sources/ResectaApp/Views/VerificationProgressView.swift"

    @Test("The four entry and gear identifiers are on the home screen")
    func identifiers() throws {
        let home = try loadRepoFile(Self.homePath)
        for id in ["homeSettingsButton", "homeOpenDocument", "homeImportPhotos", "homeTrySample"] {
            #expect(home.contains(".accessibilityIdentifier(\"\(id)\")"), "\(id)")
        }
    }

    @Test("The three hints read as the copy of record has them")
    func hints() throws {
        let home = try loadRepoFile(Self.homePath)
        for hint in ["Opens the Files picker.", "Opens the system Photos picker.", "Opens the sample in the editor."] {
            #expect(home.contains(".accessibilityHint(\"\(hint)\")"), "\(hint)")
        }
    }

    @Test("Every string on the home screen is the copy of record's, verbatim")
    func strings() throws {
        let home = try loadRepoFile(Self.homePath)
        for string in [
            "On-device PDF redaction designed to remove the underlying content.",
            "Open a Document",
            "Import a PDF or an image from Files. Nothing is uploaded.",
            "Import Photos",
            "Choose up to 20 photos, one page each. Nothing is uploaded.",
            "Try the Sample",
            "A bundled 3-page bank statement.",
            "Version \\(",
        ] {
            #expect(home.contains(string), "\(string)")
        }
        #expect(TrustLine.words == ["On-device", "No tracking", "Open source"], "the ruled trust words, verbatim")
        #expect(!home.contains("→"), "no arrow line on any entry")
        #expect(!home.contains("Choose photos from your library"), "the staged body is replaced")
        #expect(!home.contains("Open a bundled sample bank statement to see"), "the shipped sample body is replaced")
        #expect(!home.contains("sparkles"), "the sample row's glyph is doc.text")
    }

    @Test("The trust words are one spoken line in supportText, with no tertiary separator and no shared item")
    func trustLine() throws {
        let home = try loadRepoFile(Self.homePath)
        #expect(!home.contains(".tertiary"), "no tertiary separator on Home")
        #expect(!home.contains("TrustItem("), "the shared item leaves Home")
        #expect(!home.contains("FlowLayout("), "the flow layout leaves Home")
        #expect(home.contains("TrustLine()"), "Home draws the shared trust line")
        #expect(TrustLine.spokenLabel == "On-device, No tracking, Open source")
        let card = try loadRepoFile(Self.cardPath)
        #expect(card.contains(".accessibilityLabel(Self.spokenLabel)"), "the trust line speaks its one label")
    }

    // MARK: - Beside Home: the re-opened door

    @Test("Choose Another File re-opens the door the document came through; the sample opens no picker")
    @MainActor
    func reopenDoor() {
        let coordinator = AppCoordinator(settingsState: SettingsState(defaults: makeScratchDefaults().0),
                                         userTermsStore: UserTermsStore())
        coordinator.openRedact(door: .files)
        #expect(coordinator.openedDoor == .files)
        coordinator.requestReopenDoor()
        coordinator.returnHome()
        #expect(coordinator.openedDoor == nil)
        #expect(coordinator.consumeReopenDoor() == .files)
        #expect(coordinator.consumeReopenDoor() == nil, "handed over once")

        coordinator.openRedact(door: .sample)
        coordinator.requestReopenDoor()
        coordinator.returnHome()
        #expect(coordinator.consumeReopenDoor() == nil, "the sample opens no picker")

        coordinator.openRedact(door: .photos)
        coordinator.requestReopenDoor()
        coordinator.returnHome()
        #expect(coordinator.consumeReopenDoor() == .photos)
    }

    @Test("The failed screen's primary action names photos for the Photos door")
    func chooseAnotherLabelPerDoor() {
        #expect(FailedStateView.primaryActionLabel(.chooseAnotherFile, door: .photos) == "Choose Other Photos")
        #expect(FailedStateView.primaryActionLabel(.chooseAnotherFile, door: .files) == "Choose Another File")
        #expect(FailedStateView.primaryActionLabel(.chooseAnotherFile, door: nil) == "Choose Another File")
        #expect(FailedStateView.primaryActionLabel(.chooseAnotherFile, door: .sample) == "Choose Another File")
        #expect(FailedStateView.primaryActionLabel(.reopenDocument, door: .photos) == "Re-open Document")
    }

    @Test("A refused drop on the failed screen names the button as it reads after a Photos import")
    func refusalNamesThePhotosButton() {
        let documentState = DocumentState()
        documentState.phase = .failed(error: .importError(.unsupportedFormat), returnPhase: .empty)
        #expect(documentState.importRefusalMessage(with: RedactionState(), door: .photos)
                == "Cannot import from this screen. Tap Choose Other Photos first.")
        #expect(documentState.importRefusalMessage(with: RedactionState(), door: .files)
                == "Cannot import from this screen. Tap Choose Another File first.")
    }

    @Test("The masthead and the gate title carry the header trait")
    func headers() throws {
        let home = try loadRepoFile(Self.homePath)
        let gate = try loadRepoFile(Self.gatePath)
        #expect(home.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(gate.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(home.contains(".accessibilityElement(children: .ignore)"), "the masthead is one element with an explicit label")
    }

    @Test("One open guard per workspace-opening site, and the entries are disabled while one opens")
    func openGuard() throws {
        let home = try loadRepoFile(Self.homePath)
        #expect(count(of: "guard !isOpening", in: home) == 4,
                "the sample, the importer's success, its non-cancel failure and the Photos pick: \(count(of: "guard !isOpening", in: home))")
        #expect(count(of: ".disabled(isOpening)", in: home) == 1)
    }

    @Test("The mark is drawn from shapes; no SF Symbol is looked up for it anywhere under Sources")
    func markIsShapes() throws {
        let sources = try swiftFiles(under: repoRoot().appendingPathComponent("Sources"))
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("doc.text.redact"), "\(file.lastPathComponent) names the retired symbol")
        }
        for path in [Self.homePath, Self.gatePath, Self.overlayPath] {
            let text = try loadRepoFile(path)
            #expect(text.contains("HomeMark("), "\(path) draws the mark")
            #expect(!text.contains("doc.viewfinder"), "\(path) still names the scan glyph")
            #expect(!text.contains("heroSymbol"), "\(path) keeps the retired guard")
        }
    }

    @Test("The gate keeps its three identifiers and cites files by symbol, not by line")
    func gateContract() throws {
        let gate = try loadRepoFile(Self.gatePath)
        for id in ["eulaViewEULA", "eulaViewPrivacy", "eulaAccept"] {
            #expect(gate.contains(".accessibilityIdentifier(\"\(id)\")"), "\(id)")
        }
        let lineRefs = try NSRegularExpression(pattern: #"\.swift:[0-9]"#)
        #expect(lineRefs.firstMatch(in: gate, range: NSRange(gate.startIndex..., in: gate)) == nil, "a stale file:line reference")
        #expect(!gate.contains("Full-screen cover"))
        #expect(gate.contains(".safeAreaBar(edge: .bottom)"), "I Agree is pinned beneath the scrolling text as a bar, so the soft edge fades the text under it")
    }

    @Test("The progress screen's trust words use the shared line, not the item strip")
    func progressTrustLine() throws {
        let progress = try loadRepoFile(Self.progressPath)
        #expect(!progress.contains("TrustItem("))
        #expect(!progress.contains(".tertiary"))
        #expect(progress.contains("TrustLine("))
    }

    @Test("The snapshot overlay draws the mark on the grouped background with no symbol")
    func overlayContract() throws {
        let overlay = try loadRepoFile(Self.overlayPath)
        #expect(overlay.contains("HomeMark("))
        #expect(overlay.contains("systemGroupedBackground"))
        #expect(!overlay.contains("UIImage(systemName:"))
        #expect(!overlay.contains("symbolName"))
    }

    // MARK: - Helpers

    private func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
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
