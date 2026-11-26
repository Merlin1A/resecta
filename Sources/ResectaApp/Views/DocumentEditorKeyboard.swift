import SwiftUI
import PDFKit
import RedactionEngine

// The editor's keyboard shortcuts, moved out of `DocumentEditorView.swift`
// (the hub) along its `// MARK: - Keyboard Shortcuts` seam: Escape,
// Command-A and the arrow-key nudge. The handlers live on
// `DocumentEditorKeyboard`, a modifier the hub's `body` mounts with a
// binding to its drawing tool (Escape clears it); it reads the same
// environment the hub does. The nudge's step stays a static on
// `DocumentEditorView`, where the tests read it.

extension DocumentEditorView {

    /// Nudge amount in normalized coordinates: ONE point of the page as
    /// shown, from the page's geometry (on a page turned 90 or 270 the
    /// crop box's sides are swapped); the pre-1.1.0 0.0025 stands in when
    /// there is no page.
    static func nudgeStep(page: PDFPage?) -> (dx: CGFloat, dy: CGFloat) {
        let step = page.map { RunRecord.PageGeometry(page: $0, box: .cropBox).pointStep }
            ?? CGSize(width: RunRecord.PageGeometry.fallbackStep, height: RunRecord.PageGeometry.fallbackStep)
        return (dx: step.width, dy: step.height)
    }

    /// `rect` nudged by one step and clamped to the page. PDF Y is
    /// bottom-left, so the up arrow (negative `dy` on screen) moves the
    /// rect up the page.
    static func nudgedRect(_ rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var rect = rect
        rect.origin.x = max(0, min(rect.origin.x + dx, 1 - rect.width))
        rect.origin.y = max(0, min(rect.origin.y - dy, 1 - rect.height))
        return rect
    }
}

/// The editor's key handling. Mounted once by `DocumentEditorView.body`;
/// owns the `.onKeyPress` the editing shortcuts arrive through.
struct DocumentEditorKeyboard: ViewModifier {
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState
    @Environment(\.undoManager) private var undoManager
    @Binding var activeTool: DocumentEditorView.DrawingTool?
    @Binding var isMultiSelectActive: Bool
    /// The nudge run in progress: its selection and its last key press.
    @State private var nudgeRun: NudgeRun?

    struct NudgeRun: Equatable {
        let selection: Set<UUID>
        let at: Date
    }

    /// How long after one nudge the next still belongs to its run.
    static let nudgeRunWindow: TimeInterval = 1.0

    /// A nudge continues the run, and registers no undo step of its own,
    /// when it moves the same selection within the window: the run's first
    /// step undoes to where the run began and redoes to where it ended.
    static func nudgeContinuesRun(previous: NudgeRun?, selection: Set<UUID>, now: Date) -> Bool {
        guard let previous else { return false }
        return previous.selection == selection && now.timeIntervalSince(previous.at) < nudgeRunWindow
    }

    func body(content: Content) -> some View {
        content.onKeyPress(phases: .down, action: handleKeyPress)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Keyboard-shortcut entry point honors the
        // phase gate. The `runChromePhaseKind == .editing` guard mirrors the
        // `canStartPipeline` / `canMutateRegions` discipline so a
        // mid-pipeline arrow / Escape / Cmd-A press cannot mutate
        // `redactionState.regions` while `.detecting / .redacting /
        // .verifying` owns it. Every key-handler delegate
        // (handleEscapeKey, handleSelectAllKey, nudgeSelection)
        // re-asserts the same guard for defense-in-depth. Spot-check
        // passed — no behavioral change needed.
        guard documentState.runChromePhaseKind == .editing else { return .ignored }

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
        guard documentState.runChromePhaseKind == .editing else { return .ignored }
        if !redactionState.selectedRegionIDs.isEmpty {
            redactionState.deselectAllRegions()
            return .handled
        }
        if activeTool != nil {
            activeTool = nil
            return .handled
        }
        if isMultiSelectActive {
            isMultiSelectActive = false
            return .handled
        }
        return .ignored
    }

    private func handleSelectAllKey() -> KeyPress.Result {
        guard documentState.runChromePhaseKind == .editing else { return .ignored }
        let page = documentState.currentPageIndex
        guard redactionState.canSelectAllOnPage(page) else { return .ignored }
        redactionState.selectAllOnPage(page)
        return .handled
    }

    // MARK: - Keyboard Nudge

    private var nudgeDelta: (dx: CGFloat, dy: CGFloat) {
        DocumentEditorView.nudgeStep(page: documentState.sourceDocument?.page(at: documentState.currentPageIndex))
    }

    private func nudgeSelection(dx: CGFloat, dy: CGFloat) -> KeyPress.Result {
        guard documentState.runChromePhaseKind == .editing,
              !redactionState.selectedRegionIDs.isEmpty else { return .ignored }
        let page = documentState.currentPageIndex
        let moves: [(id: UUID, newRect: CGRect)] = redactionState.selectedRegionIDs.compactMap { id in
            guard let regions = redactionState.regions[page],
                  let region = regions.first(where: { $0.id == id }) else { return nil }
            return (id: id, newRect: DocumentEditorView.nudgedRect(region.normalizedRect, dx: dx, dy: dy))
        }
        guard !moves.isEmpty else { return .ignored }
        for move in moves { assert(RedactionState.admitsEditorShare(move.newRect)) }
        let now = Date()
        let selection = redactionState.selectedRegionIDs
        let undo = Self.nudgeContinuesRun(previous: nudgeRun, selection: selection, now: now) ? nil : undoManager
        let moved = moves.count == 1
            ? redactionState.moveRegion(moves[0].id, page: page, newRect: moves[0].newRect, undoManager: undo)
            : redactionState.moveRegions(moves, page: page, undoManager: undo)
        // A press held at the page edge moves nothing, so it neither starts
        // nor extends a run: the next real move still records its step.
        if moved { nudgeRun = NudgeRun(selection: selection, at: now) }
        return .handled
    }
}
