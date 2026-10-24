import SwiftUI

// The canvas's bottom status capsule, moved out of `DocumentEditorView.swift`
// (the hub) with its statics: which caption shows and its controls. One
// responsibility; the hub's body mounts `captionOverlay` in the bottom
// overlay slot it always held. One capsule at a time: the drawing caption
// while the Rectangle tool is on, or the Add to Selection capsule — the
// mode, the selection's count, and a Done button that turns the mode off.

extension DocumentEditorView {

    // MARK: - Drawing-mode caption

    /// Caption text shown while the rectangle drawing tool is active.
    /// Mechanism description: names the active gesture so the user knows
    /// what shape the touch will produce.
    static let drawingModeCaption = "Drag to draw · two fingers to scroll"

    /// Caption is visible only when (a) a captioned drawing tool is
    /// active (the rectangle) AND (b) the document is
    /// in the editing phase. Other phases blur the canvas underneath
    /// their own progress UI, so the caption would be stale.
    static func drawingModeCaptionShouldShow(
        activeTool: DrawingTool?,
        phaseKind: DocumentState.PhaseKind
    ) -> Bool {
        guard phaseKind == .editing else { return false }
        return activeTool == .rectangle
    }

    /// Pick the caption string for whichever drawing tool is
    /// active, so the `.overlay` block and the accessibility label read
    /// the same string. Returns nil when no captioned tool is active.
    static func activeDrawingCaption(activeTool: DrawingTool?) -> String? {
        activeTool == .rectangle ? drawingModeCaption : nil
    }

    /// VoiceOver label for the bottom hint capsule. Mirrors the
    /// visible caption so sighted and VoiceOver users hear the same
    /// mechanism description.
    static func captionAccessibilityLabel(activeTool: DrawingTool?) -> String {
        activeDrawingCaption(activeTool: activeTool) ?? ""
    }

    // MARK: - Add to Selection capsule

    /// The capsule's words: the mode, then the selection's count; shorter
    /// at accessibility sizes.
    static func addModeCaption(selectedCount: Int, accessibilitySize: Bool) -> String {
        if accessibilitySize {
            return selectedCount == 0 ? "Tap regions to add" : "\(selectedCount) selected"
        }
        return selectedCount == 0
            ? "Adding to selection — tap regions"
            : "Adding to selection · \(selectedCount) selected"
    }

    /// The capsule as VoiceOver reads it: one sentence.
    static func addModeAccessibilityLabel(selectedCount: Int) -> String {
        selectedCount == 0
            ? "Adding to selection. Tap regions to add them."
            : "Adding to selection, \(selectedCount) selected"
    }

    /// Which capsule the host shows.
    enum BottomCapsule: Equatable {
        case drawing
        case addToSelection
    }

    /// One capsule at a time, only while editing: the drawing caption while
    /// the Rectangle tool is on, else the Add to Selection capsule while
    /// that mode is on. (Entering either turns the other off.)
    static func bottomCapsule(
        activeTool: DrawingTool?, addToSelection: Bool, phaseKind: DocumentState.PhaseKind
    ) -> BottomCapsule? {
        if drawingModeCaptionShouldShow(activeTool: activeTool, phaseKind: phaseKind) { return .drawing }
        return addToSelection && phaseKind == .editing ? .addToSelection : nil
    }

    /// The bottom status capsule.
    @ViewBuilder
    var captionOverlay: some View {
        switch Self.bottomCapsule(
            activeTool: activeTool, addToSelection: isMultiSelectActive, phaseKind: documentState.phaseKind
        ) {
        case .drawing?: drawingCaptionCapsule
        case .addToSelection?: addModeCapsule
        case nil: EmptyView()
        }
    }

    /// The Add to Selection capsule. Done turns the mode off through the
    /// toolbar's one tool-and-toggle reset, the same home every other exit
    /// uses; the caption itself takes no touches.
    private var addModeCapsule: some View {
        let count = redactionState.selectedRegionIDs.count
        return HStack(spacing: ResectaTokens.Spacing.md) {
            Text(Self.addModeCaption(selectedCount: count, accessibilitySize: dynamicTypeSize.isAccessibilitySize))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            Button("Done") {
                editorToolbar.resetCanvasTools()
            }
            .font(.caption.weight(.semibold))
            // A 44-pt hit area around the small word, without moving it.
            .padding(.vertical, 15).padding(.horizontal, 7)
            .contentShape(Rectangle())
            .padding(.vertical, -15).padding(.horizontal, -7)
            .accessibilityHint("Turns off Add to Selection.")
            .accessibilityIdentifier("addModeDoneButton")
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xs)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, ResectaTokens.Spacing.lg + parkedChromeLayout.hintCapsuleLift)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.addModeAccessibilityLabel(selectedCount: count))
        .accessibilityIdentifier("addModeCapsule")
        .transition(.opacity)
    }

    /// The drawing caption: a subtle banner that names the active gesture
    /// for the rectangle tool.
    @ViewBuilder
    private var drawingCaptionCapsule: some View {
        if let caption = DocumentEditorView.activeDrawingCaption(
            activeTool: activeTool
           ) {
            HStack(spacing: ResectaTokens.Spacing.md) {
                Text(caption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
                .padding(.horizontal, ResectaTokens.Spacing.md)
                .padding(.vertical, ResectaTokens.Spacing.xs)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, ResectaTokens.Spacing.lg + parkedChromeLayout.hintCapsuleLift)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    DocumentEditorView.captionAccessibilityLabel(
                        activeTool: activeTool
                    )
                )
                .allowsHitTesting(false).transition(.opacity)
        }
    }
}
