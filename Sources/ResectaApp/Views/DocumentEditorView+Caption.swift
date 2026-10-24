import SwiftUI

// The canvas's bottom status capsule, moved out of `DocumentEditorView.swift`
// (the hub) with its statics: which caption shows and its controls. One
// responsibility; the hub's body mounts `captionOverlay` in the bottom
// overlay slot it always held.

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
    static func activeDrawingCaption(
        activeTool: DrawingTool?
    ) -> String? {
        switch activeTool {
        case .rectangle: return drawingModeCaption
        default: return nil
        }
    }

    /// VoiceOver label for the bottom hint capsule. Mirrors the
    /// visible caption so sighted and VoiceOver users hear the same
    /// mechanism description.
    static func captionAccessibilityLabel(
        activeTool: DrawingTool?
    ) -> String {
        guard let caption = activeDrawingCaption(
            activeTool: activeTool
        ) else {
            return ""
        }
        return caption
    }

    /// The bottom status capsule: a subtle banner that names the active
    /// gesture for the rectangle tool.
    @ViewBuilder
    var captionOverlay: some View {
        if DocumentEditorView.drawingModeCaptionShouldShow(
            activeTool: activeTool,
            phaseKind: documentState.phaseKind
        ),
           let caption = DocumentEditorView.activeDrawingCaption(
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
