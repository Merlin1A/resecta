import Testing
import SwiftUI
@testable import ResectaApp

// Where brief messages are drawn: the place's arithmetic, and source scans
// over the app that keep every presentation, dialog and announcement on the
// queue's terms. The scans skip comment lines (a line whose first
// characters after its indent are `//`).

@Suite("Message hosts")
@MainActor
struct MessageHostTests {

    @Test("The root place is 8 points above the bottom chrome while editing and 44 above the screen's foot otherwise")
    func rootPlace() {
        #expect(MessagePlacement.rootLift(editing: true, bottomClearance: 62, safeAreaBottom: 34) == 70)
        #expect(MessagePlacement.rootLift(editing: true, bottomClearance: 125, safeAreaBottom: 34) == 133)
        #expect(MessagePlacement.rootLift(editing: false, bottomClearance: 62, safeAreaBottom: 34) == 10)
        #expect(MessagePlacement.rootLift(editing: false, bottomClearance: 0, safeAreaBottom: 50) == 0)
    }

    @Test("A sheet's receipt sits 12 points above its footer")
    func sheetPlace() {
        #expect(MessagePlacement.sheetLift(footerLift: 63) == 75)
        #expect(MessagePlacement.sheetLift(footerLift: 0) == 12)
    }

    @Test("A view leaving the screen ends no message")
    func leavingEndsNothing() throws {
        let lines = try Self.codeLines("Sources/ResectaApp/Views/Messages/MessageHost.swift")
        let leaving = lines.filter { $0.contains(".onDisappear") }
        #expect(leaving.count == 3)
        for line in leaving {
            let allowed = line.contains("unregisterLayer(")
                || line.contains("setLayerSurface(") && line.contains("visible: false")
                || line.contains("setHold(") && line.contains(", false)")
            #expect(allowed, "\(line)")
        }
    }

    /// Per file: presentations (`.sheet(`, `.fullScreenCover(`, `.popover(`),
    /// `.messageLayer(` and `.messageHost(`. A presentation without a layer is
    /// an exemption named here: the agreement's legal page (no queue exists
    /// before agreement) and the canvas's pointer-hover popover.
    static let presentationTable: [String: [Int]] = [
        "Views/ContentView.swift": [0, 1, 1],
        "Views/DocumentEditorView.swift": [1, 2, 1],
        "Views/SearchAndRedactSheet.swift": [1, 3, 3],
        "Views/Search/SavedSearchListSheet.swift": [0, 0, 1],
        "Views/RedactWorkspaceView.swift": [2, 2, 2],
        "Views/HomeView.swift": [1, 1, 1],
        "Views/SettingsView.swift": [2, 2, 0],
        "Views/FailedStateView.swift": [1, 1, 0],
        "Views/ShareRiskConfirm.swift": [1, 1, 0],
        "Views/EULAGateView.swift": [1, 0, 0],
        "Views/EditorAnnouncementObservers.swift": [1, 0, 0],
    ]

    @Test("Every presentation has a layer and a host or a listed exemption")
    func everyPresentationHasALayer() throws {
        let app = Self.repoRoot().appendingPathComponent("Sources/ResectaApp")
        let files = try Self.swiftFiles(under: app)
        #expect(files.count > 100, "the scan read \(files.count) files")
        var seen: Set<String> = []
        for url in files {
            let relative = String(url.path.dropFirst(app.path.count + 1))
            if relative == "Views/Messages/MessageHost.swift" { continue }
            let lines = try Self.codeLines("Sources/ResectaApp/" + relative)
            let counts = [
                Self.count(lines, [".sheet(", ".fullScreenCover(", ".popover("]),
                Self.count(lines, [".messageLayer("]),
                Self.count(lines, [".messageHost("]),
            ]
            if let want = Self.presentationTable[relative] {
                seen.insert(relative)
                #expect(counts == want, "\(relative): \(counts), not \(want)")
            } else {
                #expect(counts == [0, 0, 0], "\(relative) presents or hosts but is not in the table: \(counts)")
            }
        }
        #expect(seen == Set(Self.presentationTable.keys), "files in the table that were not read: \(Set(Self.presentationTable.keys).subtracting(seen))")
    }

    @Test("A drawing host sits inside its view's capture cover")
    func hostInsideTheCover() throws {
        for relative in ["Views/SearchAndRedactSheet.swift", "Views/Search/SavedSearchListSheet.swift"] {
            let lines = try Self.codeLines("Sources/ResectaApp/" + relative)
            let hosts = lines.indices.filter { lines[$0].contains(".messageHost(") }
            let cover = try #require(lines.firstIndex { $0.contains(".shieldedSheetContent(") }, "\(relative) has its cover")
            #expect(!hosts.isEmpty, "\(relative) draws its receipts")
            for host in hosts { #expect(host < cover, "\(relative): a host after the cover") }
        }
    }

    @Test("Every dialog and picker holds the messages")
    func everyDialogHolds() throws {
        let app = Self.repoRoot().appendingPathComponent("Sources/ResectaApp")
        var dialogs = 0
        for url in try Self.swiftFiles(under: app) {
            let relative = String(url.path.dropFirst(app.path.count + 1))
            let lines = try Self.codeLines("Sources/ResectaApp/" + relative)
            let shown = Self.count(lines, [".alert(", ".confirmationDialog(", ".fileImporter(", ".photosPicker("])
            dialogs += shown
            if relative == "Views/Messages/MessageHost.swift" { continue }
            #expect(Self.count(lines, [".holdsMessages("]) == shown, "\(relative): \(shown) dialogs or pickers")
        }
        #expect(dialogs == 15, "the scan saw \(dialogs) dialogs and pickers")
        let share = try Self.codeLines("Sources/ResectaApp/Views/DocumentEditorView+Export.swift")
        #expect(Self.count(share, ["toastManager.setHold(attempt, true)"]) == 1)
        #expect(Self.count(share, ["toastManager.setHold(attempt, false)"]) == 2, "released by the share's end and by its abandon")
    }

    @Test("The source scans leave comment lines out")
    func scansLeaveCommentLinesOut() {
        // The two lines the dialog scan was first written against, as they
        // read when they were comments, and the same calls as code.
        let commented = [
            "    // .alert(\"Import Error\", isPresented: $showImportError) {",
            "\t\t// .alert(\"Redaction Applied\", isPresented: $showApplied) {",
        ]
        let code = [
            "        .alert(\"Import Error\", isPresented: $showImportError) {",
            "        .holdsMessages(toastManager, while: showImportError)",
        ]
        #expect(commented.allSatisfy(Self.isComment))
        #expect(!code.contains(where: Self.isComment))
        let kept = (commented + code).filter { !Self.isComment($0) }
        #expect(Self.count(kept, [".alert("]) == 1)
        #expect(Self.count(kept, [".holdsMessages("]) == 1)
    }

    /// Per file, the announcements posted past the queue: each a line that
    /// names `notification: .announcement` or builds an
    /// `AccessibilityNotification.Announcement(`. The queue's own is the one
    /// in `announce`.
    static let directAnnouncementTable: [String: Int] = [
        "State/ToastQueueManager.swift": 1,
        "State/PipelineCoordinator.swift": 1,
        "Overlay/RedactionOverlayView+Touches.swift": 3,
        "Overlay/PDFViewCoordinator.swift": 2,
        "Overlay/SnapGuideEngine.swift": 1,
        "Views/SearchResultRow.swift": 1,
        "Views/Search/SearchAndRedactSheet+Trigger.swift": 2,
        "Views/VerificationProgressView.swift": 1,
        "Views/DocumentEditorView+SelectionBar.swift": 1,
    ]

    @Test("Only the listed lines post announcements directly")
    func onlyListedLinesPostDirectly() throws {
        let app = Self.repoRoot().appendingPathComponent("Sources/ResectaApp")
        var found: [String: Int] = [:]
        for url in try Self.swiftFiles(under: app) {
            let relative = String(url.path.dropFirst(app.path.count + 1))
            let lines = try Self.codeLines("Sources/ResectaApp/" + relative)
            let posts = Self.count(lines, ["notification: .announcement", "AccessibilityNotification.Announcement("])
            if posts > 0 { found[relative] = posts }
        }
        #expect(found == Self.directAnnouncementTable)
    }

    @Test("The receipt's animations go through the resolver")
    func animationsGoThroughTheResolver() throws {
        for relative in ["Views/Messages/MessageHost.swift", "Views/Messages/ReceiptView.swift"] {
            for line in try Self.codeLines("Sources/ResectaApp/" + relative) where line.contains("Anim.toast") {
                #expect(line.contains("resolved("), "\(relative): \(line)")
            }
        }
    }

    // MARK: - Reading the source

    static func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }

    /// A file's lines with comment lines left out.
    static func codeLines(_ relativePath: String) throws -> [String] {
        let text = try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
        return text.components(separatedBy: "\n").filter { !isComment($0) }
    }

    static func swiftFiles(under directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    static func count(_ lines: [String], _ needles: [String]) -> Int {
        lines.reduce(0) { total, line in total + needles.reduce(0) { $0 + line.components(separatedBy: $1).count - 1 } }
    }

    static func isComment(_ line: String) -> Bool {
        line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//")
    }
}
