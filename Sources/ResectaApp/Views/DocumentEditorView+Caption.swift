import SwiftUI

// The canvas's bottom slot: one place, above the page bar, where at most one
// thing shows at a time, on one glass shape. `bottomSlotOccupant` decides who
// holds it: a message, then the first-time line, then the selection (Add to
// Selection is its adding state), then the drawing caption. A selection made
// after the message takes the slot from it. (The notice for a page holding a
// box drawn wider than its word is in the editor's band: the fit notice.) Outside editing nothing holds it. The hub's body mounts
// `captionOverlay` in the bottom overlay slot it always held.

/// Who holds the bottom slot.
nonisolated enum BottomSlotOccupant: Equatable, Sendable {
    case message
    case firstTimeLine
    case selection(adding: Bool)
    case drawingCaption
}

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

    /// The slot's occupant: the first that asks, in this order: a message,
    /// the first-time line, the selection (Add to Selection is its adding
    /// state, whether or not a box is selected), the drawing caption. A
    /// message and a selection made after it: the selection. Outside
    /// editing, nobody.
    static func bottomSlotOccupant(
        phaseKind: DocumentState.PhaseKind,
        messageShowing: Bool,
        selectionNewerThanMessage: Bool,
        firstTimeLineDue: Bool,
        selectedCount: Int,
        addToSelection: Bool,
        activeTool: DrawingTool?
    ) -> BottomSlotOccupant? {
        guard phaseKind == .editing else { return nil }
        let selection: BottomSlotOccupant? = addToSelection
            ? .selection(adding: true)
            : (selectedCount > 0 ? .selection(adding: false) : nil)
        if messageShowing {
            if let selection, selectionNewerThanMessage { return selection }
            return .message
        }
        if firstTimeLineDue { return .firstTimeLine }
        if let selection { return selection }
        return drawingModeCaptionShouldShow(activeTool: activeTool, phaseKind: phaseKind) ? .drawingCaption : nil
    }

    // MARK: - The slot's measures

    /// Leading and trailing, around the occupant's words.
    static let bottomSlotHorizontalPadding: CGFloat = ResectaTokens.Spacing.md
    /// Above and below the words: 44 pt tall at one line at the default size.
    static let bottomSlotVerticalPadding: CGFloat = ResectaTokens.Spacing.toastVertical
    /// The glass shape's corner: half a one-line slot's height.
    static let bottomSlotCornerRadius: CGFloat = 22
    static let bottomSlotMinimumWidth: CGFloat = 120
    /// At most 360 pt wide, and 16 pt in from each edge of the screen.
    static func bottomSlotMaximumWidth(containerWidth: CGFloat) -> CGFloat {
        min(containerWidth - 2 * ResectaTokens.Spacing.md, 360)
    }
    /// The slot's own padding under it: none. The canvas it sits on already
    /// ends 8 pt above the page bar's glass (the bar's own spacing), so the
    /// slot's foot is 8 pt above the glass.
    static let bottomSlotFootPadding: CGFloat = 0

    /// The capsules' text stops growing at Accessibility 1: past it the
    /// drawing caption covered the bottom fifth of the page. (The Add to
    /// Selection capsule still switches to its short words at every
    /// accessibility size.)
    static let capsuleTypeSizeCeiling: DynamicTypeSize = .accessibility1

    /// The bottom slot, with its one occupant.
    var captionOverlay: some View {
        let occupant = Self.bottomSlotOccupant(
            phaseKind: documentState.phaseKind,
            // The message and the first-time line have no view yet, so they never ask for the slot.
            messageShowing: false,
            selectionNewerThanMessage: false,
            firstTimeLineDue: false,
            selectedCount: redactionState.selectedRegionIDs.count,
            addToSelection: isMultiSelectActive,
            activeTool: activeTool
        )
        return Group {
            if let occupant, Self.bottomSlotDrawsHere(occupant) {
                BottomSlot(
                    footPadding: Self.bottomSlotFootPadding + parkedChromeLayout.hintCapsuleLift,
                    identifier: Self.bottomSlotIdentifier(occupant),
                    label: slotAccessibilityLabel(occupant),
                    takesTouches: occupant == .selection(adding: true) || occupant == .selection(adding: false)
                ) {
                    switch occupant {
                    case .drawingCaption: drawingCaptionWords
                    case .selection(adding: true): addModeWords
                    case .selection(adding: false): SelectionBar(toolbar: editorToolbar)
                    // Drawn by the message host.
                    case .message: EmptyView()
                    // The first-time line.
                    case .firstTimeLine: EmptyView()
                    }
                }
                .transition(.opacity)
            }
        }
        .dynamicTypeSize(...Self.capsuleTypeSizeCeiling)
        .animation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.stateChange, reduceMotion: reduceMotion), value: occupant)
    }

    /// The occupants this view draws: the drawing caption and the selection
    /// (its bar, or Add to Selection). The others are drawn by their own views.
    static func bottomSlotDrawsHere(_ occupant: BottomSlotOccupant) -> Bool {
        switch occupant {
        case .drawingCaption, .selection: true
        case .message, .firstTimeLine: false
        }
    }

    /// Each drawn occupant's identifier, as shipped, and the caption's.
    static func bottomSlotIdentifier(_ occupant: BottomSlotOccupant) -> String {
        switch occupant {
        case .drawingCaption: "drawingCaption"
        case .selection(adding: true): "addModeCapsule"
        case .selection(adding: false): "selectionBar"
        case .message, .firstTimeLine: ""
        }
    }

    private func slotAccessibilityLabel(_ occupant: BottomSlotOccupant) -> String {
        switch occupant {
        case .drawingCaption: Self.captionAccessibilityLabel(activeTool: activeTool)
        case .selection(adding: true): Self.addModeAccessibilityLabel(selectedCount: redactionState.selectedRegionIDs.count)
        // The bar's parts speak for themselves.
        case .message, .firstTimeLine, .selection(adding: false): ""
        }
    }

    /// Add to Selection's words and Done. Done turns the mode off through
    /// the toolbar's one tool-and-toggle reset, the same home every other
    /// exit uses; the words take no touches.
    private var addModeWords: some View {
        let count = redactionState.selectedRegionIDs.count
        return HStack(spacing: ResectaTokens.Spacing.md) {
            Text(Self.addModeCaption(selectedCount: count, accessibilitySize: dynamicTypeSize.isAccessibilitySize))
                .font(.subheadline)
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .allowsHitTesting(false)
            Button {
                editorToolbar.resetCanvasTools()
            } label: {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ResectaTokens.BrandTeal.text)
            }
            // A 44-pt hit area around the word, without moving it.
            .padding(.vertical, 15).padding(.horizontal, 7)
            .contentShape(Rectangle())
            .padding(.vertical, -15).padding(.horizontal, -7)
            .accessibilityHint("Turns off Add to Selection.")
            .accessibilityIdentifier("addModeDoneButton")
        }
        .transition(.opacity)
    }

    /// The drawing caption: names the active gesture for the rectangle tool.
    @ViewBuilder
    private var drawingCaptionWords: some View {
        if let caption = DocumentEditorView.activeDrawingCaption(activeTool: activeTool) {
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .transition(.opacity)
        }
    }
}

/// The bottom slot: draws its occupant centred, padded, on one glass shape,
/// at least 120 pt wide and at most 360 pt (16 pt in from each screen edge).
/// The glass shape is the occupant's accessibility element: its identifier,
/// its label, and whether it takes touches (the selection does: its
/// bar's actions and Add to Selection's Done).
struct BottomSlot<Content: View>: View {
    let footPadding: CGFloat
    let identifier: String
    let label: String
    let takesTouches: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .multilineTextAlignment(.leading)
            .padding(.horizontal, DocumentEditorView.bottomSlotHorizontalPadding)
            .padding(.vertical, DocumentEditorView.bottomSlotVerticalPadding)
            .frame(minWidth: DocumentEditorView.bottomSlotMinimumWidth)
            .glassEffect(.regular, in: RoundedRectangle(
                cornerRadius: DocumentEditorView.bottomSlotCornerRadius, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
            .allowsHitTesting(takesTouches)
            .containerRelativeFrame(.horizontal) { length, _ in
                DocumentEditorView.bottomSlotMaximumWidth(containerWidth: length)
            }
            .padding(.bottom, footPadding)
    }
}
