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
            showSettings: .constant(false), searchSheetDetent: .constant(.medium),
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

    @Test("Resetting the canvas tools turns the draw tool and Add to Selection off")
    func resetCanvasToolsTurnsBothOff() {
        let coordinator = makeCoordinator()
        var tool: DocumentEditorView.DrawingTool? = .rectangle
        var addToSelection = true
        let toolbar = DocumentEditorToolbar(
            documentState: coordinator.documentState, redactionState: coordinator.redactionState,
            coordinator: coordinator, horizontalSizeClass: .compact, undoManager: nil,
            activeTool: Binding(get: { tool }, set: { tool = $0 }),
            isMultiSelectActive: Binding(get: { addToSelection }, set: { addToSelection = $0 }),
            showSettings: .constant(false), searchSheetDetent: .constant(.medium),
            documentOverride: nil, redactButtonDisabled: true, redactButtonHint: "",
            handleHomeTap: {}, homeButton: AnyView(EmptyView()), pipelineModePicker: AnyView(EmptyView()),
            deleteSelectedRegions: {}
        )
        toolbar.resetCanvasTools()
        #expect(tool == nil)
        #expect(addToSelection == false)
    }

    @Test("The editor resets the canvas tools when a different document replaces the open one (source pin)")
    func editorResetsToolsOnDocumentSwap() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView.swift")
        guard let observer = source.range(of: ".onChange(of: documentState.sourceDocument) { oldDocument, newDocument in") else {
            Issue.record("The editor observes no document swap")
            return
        }
        let window = source[observer.upperBound...].prefix(300)
        #expect(window.contains("RedactWorkspaceView.isDocumentSwap(from: oldDocument, to: newDocument)"))
        #expect(window.contains("editorToolbar.resetCanvasTools()"))
    }

    @Test("The overflow's Mark Whole Page adds the page bar's whole-page region to the page in view, on a one-page document too")
    func overflowMarksTheWholePage() {
        let coordinator = makeCoordinator()
        coordinator.documentState.sourceDocument = makeMultiPagePDFDocument(pages: 1)
        coordinator.documentState.currentPageIndex = 0
        toolbar(for: coordinator).markWholePage()
        let regions = coordinator.redactionState.regions[0] ?? []
        #expect(regions.count == 1)
        #expect(regions.first?.normalizedRect == PageNavigationBar.wholePageRegion().normalizedRect)
    }

    @Test("The overflow mounts Mark Whole Page after Home (source pin)")
    func overflowMountsMarkWholePage() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorToolbar.swift")
        guard let group = source.range(of: "var secondaryActionToolbarItems: some View {"),
              let end = source.range(of: ".tint(.primary)", range: group.upperBound..<source.endIndex),
              let home = source.range(of: "homeButton", range: group.upperBound..<end.lowerBound),
              let mark = source.range(of: "markWholePageButton", range: group.upperBound..<end.lowerBound)
        else {
            Issue.record("The overflow must mount homeButton and markWholePageButton")
            return
        }
        #expect(home.lowerBound < mark.lowerBound)
        #expect(source.contains("PageNavigationBar.markWholePage("), "one action, the page bar's own")
    }

    /// Mirrors `HonestySurfacesTests.loadRepoFile`.
    private func loadRepoFile(
        _ relativePath: String, from file: StaticString = #filePath
    ) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}
