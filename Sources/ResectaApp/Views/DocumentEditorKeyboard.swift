import SwiftUI
import PDFKit

// The editor's keyboard shortcuts, moved out of `DocumentEditorView.swift`
// (the hub) along its `// MARK: - Keyboard Shortcuts` seam: Escape,
// Command-A and the arrow-key nudge. The handlers live on
// `DocumentEditorKeyboard`, a modifier the hub's `body` mounts with a
// binding to its drawing tool (Escape clears it); it reads the same
// environment the hub does. The nudge's step stays a static on
// `DocumentEditorView`, where the tests read it.

extension DocumentEditorView {

    /// Nudge amount in normalized coordinates: ONE PDF point on the
    /// current page, i.e. 1/pageWidth × 1/pageHeight from
    /// the page's crop box; the pre-1.1.0 0.0025 stands in when no page
    /// geometry is available.
    static let nudgeFallback: CGFloat = 0.0025

    static func nudgeDelta(pageSize: CGSize?) -> (dx: CGFloat, dy: CGFloat) {
        guard let size = pageSize, size.width > 0, size.height > 0 else {
            return (dx: nudgeFallback, dy: nudgeFallback)
        }
        return (dx: 1 / size.width, dy: 1 / size.height)
    }
}

/// The editor's key handling. Mounted once by `DocumentEditorView.body`;
/// owns the `.onKeyPress` the editing shortcuts arrive through.
struct DocumentEditorKeyboard: ViewModifier {
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState
    @Environment(\.undoManager) private var undoManager
    @Binding var activeTool: DocumentEditorView.DrawingTool?

    func body(content: Content) -> some View {
        content.onKeyPress(phases: .down, action: handleKeyPress)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Keyboard-shortcut entry point honors the
        // phase gate. The `phaseKind == .editing` guard mirrors the
        // `canStartPipeline` / `canMutateRegions` discipline so a
        // mid-pipeline arrow / Escape / Cmd-A press cannot mutate
        // `redactionState.regions` while `.detecting / .redacting /
        // .verifying` owns it. Every key-handler delegate
        // (handleEscapeKey, handleSelectAllKey, nudgeSelection)
        // re-asserts the same guard for defense-in-depth. Spot-check
        // passed — no behavioral change needed.
        guard documentState.phaseKind == .editing else { return .ignored }

        switch press.key {
        case .escape:
            return handleEscapeKey()
        case .upArrow:
            return nudgeSelection(dx: 0, dy: -nudgeDelta.dy)
        case .downArrow:
            return nudgeSelection(dx: 0, dy: nudgeDelta.dy)
        case .leftArrow:
            return nudgeSelection(dx: -nudgeDelta.dx, dy: 0)
        case .rightArrow:
            return nudgeSelection(dx: nudgeDelta.dx, dy: 0)
        default:
            if press.characters == "a", press.modifiers.contains(.command) {
                return handleSelectAllKey()
            }
            return .ignored
        }
    }

    private func handleEscapeKey() -> KeyPress.Result {
        guard documentState.phaseKind == .editing else { return .ignored }
        if !redactionState.selectedRegionIDs.isEmpty {
            redactionState.selectedRegionIDs = []
            return .handled
        }
        if activeTool != nil {
            activeTool = nil
            return .handled
        }
        return .ignored
    }

    private func handleSelectAllKey() -> KeyPress.Result {
        guard documentState.phaseKind == .editing else { return .ignored }
        let page = documentState.currentPageIndex
        guard let pageRegions = redactionState.regions[page], !pageRegions.isEmpty else { return .ignored }
        redactionState.selectedRegionIDs = Set(pageRegions.map(\.id))
        return .handled
    }

    // MARK: - Keyboard Nudge

    private var nudgeDelta: (dx: CGFloat, dy: CGFloat) {
        let page = documentState.currentPageIndex
        let size = documentState.sourceDocument?.page(at: page)?.bounds(for: .cropBox).size
        return DocumentEditorView.nudgeDelta(pageSize: size)
    }

    private func nudgeSelection(dx: CGFloat, dy: CGFloat) -> KeyPress.Result {
        guard documentState.phaseKind == .editing,
              !redactionState.selectedRegionIDs.isEmpty else { return .ignored }
        let page = documentState.currentPageIndex
        let moves: [(id: UUID, newRect: CGRect)] = redactionState.selectedRegionIDs.compactMap { id in
            guard let regions = redactionState.regions[page],
                  let region = regions.first(where: { $0.id == id }) else { return nil }
            var rect = region.normalizedRect
            rect.origin.x += dx
            // PDF Y is bottom-left, so up arrow (negative dy in screen) = positive in PDF
            rect.origin.y -= dy
            // Clamp to 0–1
            rect.origin.x = max(0, min(rect.origin.x, 1 - rect.width))
            rect.origin.y = max(0, min(rect.origin.y, 1 - rect.height))
            return (id: id, newRect: rect)
        }
        guard !moves.isEmpty else { return .ignored }
        if moves.count == 1 {
            redactionState.moveRegion(moves[0].id, page: page,
                                      newRect: moves[0].newRect, undoManager: undoManager)
        } else {
            redactionState.moveRegions(moves, page: page, undoManager: undoManager)
        }
        return .handled
    }
}
