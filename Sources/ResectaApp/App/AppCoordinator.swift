import PDFKit
import SwiftUI

// Workspace navigation coordinator.
// Switches between Home and Redact workspaces.
// MainActor by SE-0466 default.

@Observable
final class AppCoordinator {
    enum ActiveWorkspace {
        case home
        case redact(RedactWorkspace)

        // Lightweight Equatable discriminator for cross-dissolve animation.
        // Avoids making workspace objects Equatable.
        enum Kind { case home, redact }
        var kind: Kind {
            switch self {
            case .home: .home
            case .redact: .redact
            }
        }
    }

    var activeWorkspace: ActiveWorkspace = .home

    /// The door the open workspace's document came through, so the failed
    /// screen's primary action can name it and open it again; nil at home.
    private(set) var openedDoor: ImportDoor?
    /// A door the next home screen presents on arrival, requested by the
    /// failed screen's "Choose Another File" / "Choose Other Photos".
    private var reopenRequested: ImportDoor?

    private let settingsState: SettingsState
    private let userTermsStore: UserTermsStore

    init(settingsState: SettingsState, userTermsStore: UserTermsStore) {
        self.settingsState = settingsState
        self.userTermsStore = userTermsStore
    }

    /// The open workspace's temporary session directory — the orphan sweep
    /// leaves it in place whatever its age. Empty at home.
    var liveTempDirectories: Set<URL> {
        switch activeWorkspace {
        case .home: []
        case .redact(let ws): [ws.coordinator.tempExportDirectory.url]
        }
    }

    /// A fresh workspace with no document yet; `door` records where the
    /// document is about to come from (nil for a bootstrap that opens none).
    func openRedact(door: ImportDoor? = nil) {
        tearDownCurrentWorkspace()
        openedDoor = door
        activeWorkspace = .redact(RedactWorkspace(settingsState: settingsState, userTermsStore: userTermsStore))
    }

    /// Creates a RedactWorkspace, transitions to it, and begins importing the document.
    /// Workspace transition is synchronous; import runs asynchronously after.
    func openRedactWithDocument(url: URL) async {
        tearDownCurrentWorkspace()
        openedDoor = .files
        let workspace = RedactWorkspace(settingsState: settingsState, userTermsStore: userTermsStore)
        activeWorkspace = .redact(workspace)
        let outcome = await ImportService.importDocument(
            from: url,
            documentState: workspace.documentState,
            redactionState: workspace.redactionState
        )
        // A locked document waits in the workspace for its password; the
        // sheet presents over the failed state the import left.
        if case .needsPassword(let hold) = outcome {
            workspace.lockedImport = hold
        }
    }

    /// The Photos door: tear down the current workspace, create a new one,
    /// and import the picked images, one page each, in pick order.
    func openRedactWithImages(_ images: AsyncThrowingStream<Data, any Error>, count: Int) async {
        tearDownCurrentWorkspace()
        openedDoor = .photos
        let workspace = RedactWorkspace(settingsState: settingsState, userTermsStore: userTermsStore)
        activeWorkspace = .redact(workspace)
        await ImportService.importImages(
            images, count: count,
            documentState: workspace.documentState,
            redactionState: workspace.redactionState)
    }

    func returnHome() {
        tearDownCurrentWorkspace()
        openedDoor = nil
        activeWorkspace = .home
    }

    /// Ask the next home screen to present the door the document came
    /// through (Files or Photos); the sample and a bootstrap open no picker.
    func requestReopenDoor() {
        switch openedDoor {
        case .files, .photos: reopenRequested = openedDoor
        default: reopenRequested = nil
        }
    }

    /// The door requested for re-opening, handed over once.
    func consumeReopenDoor() -> ImportDoor? {
        defer { reopenRequested = nil }
        return reopenRequested
    }

    private func tearDownCurrentWorkspace() {
        switch activeWorkspace {
        case .home: break
        case .redact(let ws): ws.tearDown()
        }
    }
}
