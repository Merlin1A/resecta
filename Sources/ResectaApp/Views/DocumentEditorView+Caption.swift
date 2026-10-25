import SwiftUI

// The canvas's bottom status capsule, moved out of `DocumentEditorView.swift`
// (the hub) with its statics: which caption shows and its controls. One
// responsibility; the hub's body mounts `captionOverlay` in the bottom
// overlay slot it always held. One capsule at a time: the drawing caption
// while the Rectangle tool is on, or the Add to Selection capsule — the
// mode, the selection's count, and a Done button that turns the mode off —
// or, on a page holding a box drawn wider than its word, the widened-box
// notice (`RedactionState+WidenedBoxes`).

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

    // MARK: - Widened-box capsule

    /// The capsule's words: shorter at accessibility sizes.
    static func widenedBoxCaption(accessibilitySize: Bool) -> String {
        accessibilitySize
            ? "Wide boxes: keep them wide"
            : "Some boxes here are wider than their words. Keep them wide."
    }

    /// The capsule as VoiceOver reads it: the reason and the ask.
    static let widenedBoxAccessibilityLabel = "Some boxes on this page were drawn wider than their words, because the "
        + "text could not be fitted to the printed words. Keep them wide: shrinking one can leave part of a word readable."

    /// Which capsule the host shows.
    enum BottomCapsule: Equatable {
        case drawing
        case addToSelection
        case widenedBoxes
    }

    /// One capsule at a time, only while editing: the drawing caption while
    /// the Rectangle tool is on, else the Add to Selection capsule while
    /// that mode is on (entering either turns the other off), else the
    /// widened-box notice while the page in view holds a widened box.
    static func bottomCapsule(
        activeTool: DrawingTool?, addToSelection: Bool, phaseKind: DocumentState.PhaseKind,
        widenedOnPage: Bool = false
    ) -> BottomCapsule? {
        if drawingModeCaptionShouldShow(activeTool: activeTool, phaseKind: phaseKind) { return .drawing }
        guard phaseKind == .editing else { return nil }
        if addToSelection { return .addToSelection }
        return widenedOnPage ? .widenedBoxes : nil
    }

    /// The capsules' text stops growing at Accessibility 1: past it the
    /// drawing caption covered the bottom fifth of the page. (The Add to
    /// Selection capsule still switches to its short words at every
    /// accessibility size.)
    static let capsuleTypeSizeCeiling: DynamicTypeSize = .accessibility1

    /// The bottom status capsule.
    var captionOverlay: some View {
        Group {
            switch Self.bottomCapsule(
                activeTool: activeTool, addToSelection: isMultiSelectActive, phaseKind: documentState.phaseKind,
                widenedOnPage: redactionState.pageHoldsWidenedBox(documentState.currentPageIndex)
            ) {
            case .drawing?: drawingCaptionCapsule
            case .addToSelection?: addModeCapsule
            case .widenedBoxes?: widenedBoxCapsule
            case nil: EmptyView()
            }
        }
        .dynamicTypeSize(...Self.capsuleTypeSizeCeiling)
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

    /// The widened-box notice: the page in view holds a box drawn wider
    /// than its word. It takes no touches.
    private var widenedBoxCapsule: some View {
        HStack(spacing: ResectaTokens.Spacing.xs) {
            Image(systemName: "arrow.left.and.right.square")
            Text(Self.widenedBoxCaption(accessibilitySize: dynamicTypeSize.isAccessibilitySize))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xs)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.bottom, ResectaTokens.Spacing.lg + parkedChromeLayout.hintCapsuleLift)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.widenedBoxAccessibilityLabel)
        .accessibilityIdentifier("widenedBoxCapsule")
        .allowsHitTesting(false)
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
