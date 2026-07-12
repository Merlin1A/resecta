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

        // Design Spec §8.2: Lightweight Equatable discriminator for cross-dissolve animation.
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

    private let settingsState: SettingsState

    init(settingsState: SettingsState) {
        self.settingsState = settingsState
    }

    func openRedact() {
        tearDownCurrentWorkspace()
        activeWorkspace = .redact(RedactWorkspace(settingsState: settingsState))
    }

    /// Creates a RedactWorkspace, transitions to it, and begins importing the document.
    /// Workspace transition is synchronous; import runs asynchronously after.
    func openRedactWithDocument(url: URL) async {
        tearDownCurrentWorkspace()
        let workspace = RedactWorkspace(settingsState: settingsState)
        activeWorkspace = .redact(workspace)
        // SEC-8 override #4 (plan §3, escalation §1.3): paranoid mode
        // enables the LivePhotoAuxStripper hook on the import path.
        await ImportService.importDocument(
            from: url,
            documentState: workspace.documentState,
            redactionState: workspace.redactionState,
            stripAuxData: settingsState.paranoidMode
        )
    }

    func returnHome() {
        tearDownCurrentWorkspace()
        activeWorkspace = .home
    }

    private func tearDownCurrentWorkspace() {
        switch activeWorkspace {
        case .home: break
        case .redact(let ws): ws.tearDown()
        }
    }
}
