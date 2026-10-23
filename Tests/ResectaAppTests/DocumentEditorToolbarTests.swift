import Testing
import SwiftUI
@testable import ResectaApp
@testable import RedactionEngine

// The editor's toolbar TYPE builds from explicit inputs: the state it reads,
// the bindings it writes and the actions the editor hands it. These pin the
// construction and the selection-driven delete label it renders.

@Suite("Editor toolbar type")
@MainActor
struct DocumentEditorToolbarTests {

    private func toolbar(for coordinator: PipelineCoordinator) -> DocumentEditorToolbar {
        DocumentEditorToolbar(
            documentState: coordinator.documentState, redactionState: coordinator.redactionState,
            coordinator: coordinator, horizontalSizeClass: .compact, undoManager: nil,
            activeTool: .constant(nil), isMultiSelectActive: .constant(false),
            showBatchDeleteConfirmation: .constant(false), showSettings: .constant(false),
            documentOverride: nil, redactButtonDisabled: true, redactButtonHint: "",
            handleHomeTap: {}, homeButton: AnyView(EmptyView()), pipelineModePicker: AnyView(EmptyView()),
            deleteSelectedRegions: {}
        )
    }

    @Test("The delete label names one region, or the count of a multi-selection")
    func deleteLabelFollowsTheSelection() {
        let coordinator = makeCoordinator()
        coordinator.redactionState.selectedRegionIDs = [UUID()]
        #expect(toolbar(for: coordinator).deleteButtonLabel == "Delete Region")
        coordinator.redactionState.selectedRegionIDs = [UUID(), UUID()]
        #expect(toolbar(for: coordinator).deleteButtonLabel == "Delete 2 Regions")
    }
}
