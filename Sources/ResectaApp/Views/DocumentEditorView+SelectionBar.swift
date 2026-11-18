import SwiftUI
import RedactionEngine

// The selection bar: while boxes are selected (no drawing tool, Add to
// Selection off) the bottom slot shows the count, a hairline, Duplicate and
// Delete. Delete is the "…" menu's Delete; Duplicate is the touch-and-hold
// menu's Duplicate and is dimmed, never removed, where that menu would not
// offer it. At the accessibility sizes the two actions are the hold menu's
// symbols. After a lasso cut at the selection limit, a second line says so
// for a few seconds.

extension DocumentEditorView {

    // MARK: - Words

    /// The count's words: "1 selected", "12 selected".
    static func selectionBarCount(_ selectedCount: Int) -> String {
        "\(selectedCount) selected"
    }

    static let selectionBarDuplicateWord = "Duplicate"
    static let selectionBarDeleteWord = "Delete"

    /// The count as VoiceOver reads it: "Selection, 1 box".
    static func selectionBarCountSpoken(_ selectedCount: Int) -> String {
        selectedCount == 1 ? "Selection, 1 box" : "Selection, \(selectedCount) boxes"
    }

    static let selectionBarDuplicateSpoken = "Duplicate Box"

    /// Delete as VoiceOver reads it: "Delete Box", "Delete 3 Boxes".
    static func selectionBarDeleteSpoken(_ selectedCount: Int) -> String {
        selectedCount > 1 ? "Delete \(selectedCount) Boxes" : "Delete Box"
    }

    // MARK: - Rules

    /// The box Duplicate copies: the one selected box, when the touch-and-hold
    /// menu would offer Duplicate for it. Nil for several boxes, a whole page,
    /// or no box.
    static func selectionBarDuplicateTarget(
        selection: Set<UUID>, regions: [Int: [RedactionRegion]]
    ) -> RedactionRegion? {
        guard selection.count == 1, let id = selection.first,
              let region = regions.values.lazy.flatMap({ $0 }).first(where: { $0.id == id })
        else { return nil }
        let rows = RedactionOverlayView.contextMenuRows(
            for: region, selectedIDs: selection, infoTitle: nil,
            canSelectAllOnPage: false, showsRationale: false)
        return rows.contains(.duplicate) ? region : nil
    }

    /// At every accessibility size the actions are symbols.
    static func selectionBarUsesSymbols(_ size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    /// The actions' symbols: the touch-and-hold menu's.
    static let selectionBarDuplicateSymbol = RedactionOverlayView.ContextMenuRow.duplicate.systemImage
    static let selectionBarDeleteSymbol = RedactionOverlayView.ContextMenuRow.deleteRegion.systemImage

    /// How long the limit's second line lasts: 4 seconds, 5 while VoiceOver
    /// runs (a message lasts at least that long there).
    static func selectionLimitLineSeconds(voiceOverRunning: Bool) -> TimeInterval {
        voiceOverRunning ? 5 : 4
    }

    /// The limit's second line shows from the cut for its few seconds, while
    /// the selection is still the one the cut left. A change of the
    /// selection, a delete and a page turn (which keeps only the boxes of
    /// the page in view) each change it, and so end the line.
    static func selectionLimitLineShows(
        cut: LassoCut?, selection: Set<UUID>, now: Date, voiceOverRunning: Bool
    ) -> Bool {
        guard let cut, cut.selection == selection else { return false }
        let elapsed = now.timeIntervalSince(cut.at)
        return elapsed >= 0 && elapsed < selectionLimitLineSeconds(voiceOverRunning: voiceOverRunning)
    }

    // MARK: - Colours and measures

    /// The word Delete: the status text tier's red.
    static let selectionBarDeleteWordColour = ResectaTokens.SemanticColor.failText
    /// The trash symbol: the system's red (symbols stay on the system tier).
    static let selectionBarDeleteSymbolColour = Color.red
    /// Duplicate, word and symbol.
    static let selectionBarDuplicateColour = ResectaTokens.BrandTeal.text
    /// The count and the limit's line.
    static let selectionBarQuietColour = ResectaTokens.SemanticColor.supportText
    /// Duplicate dimmed, where the hold menu would not offer it.
    static let selectionBarDimmedOpacity: Double = 0.4

    /// Each action's tappable height and least width.
    static let selectionBarHitSize: CGFloat = ResectaTokens.TouchTarget.minimum
    /// The padding above and below an action's word that makes its tappable
    /// height the touch target, without moving the word.
    static func selectionBarHitPadding(lineHeight: CGFloat) -> CGFloat {
        max(0, (selectionBarHitSize - lineHeight) / 2)
    }
    /// The padding beside an action's word: wider than half the gap between
    /// the two words, so a tap between them lands on one of them.
    static let selectionBarWordSidePadding: CGFloat = 12
    static let selectionBarWordGap: CGFloat = ResectaTokens.Spacing.md
    /// The row's height at the accessibility sizes: the symbols' 46-pt frames
    /// reach past it, above and below, without making the bar taller.
    static let selectionBarSymbolRowHeight: CGFloat = 28
}

/// The selection bar, drawn inside the bottom slot's glass.
struct SelectionBar: View {
    @Environment(RedactionState.self) private var redactionState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverRunning
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var wordLineHeight: CGFloat = 20

    let toolbar: DocumentEditorToolbar
    /// Bumped when the limit's line runs out, to draw the bar again.
    @State private var clock = 0

    private typealias Bar = DocumentEditorView

    var body: some View {
        let selection = redactionState.selectedRegionIDs
        let count = selection.count
        let symbols = Bar.selectionBarUsesSymbols(dynamicTypeSize)
        let duplicateTarget = Bar.selectionBarDuplicateTarget(selection: selection, regions: redactionState.regions)
        let _ = clock
        let limitShows = Bar.selectionLimitLineShows(
            cut: redactionState.lassoCut, selection: selection, now: .now, voiceOverRunning: voiceOverRunning)
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
            HStack(spacing: ResectaTokens.Spacing.sm) {
                countView(count)
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1, height: symbols ? Bar.selectionBarSymbolRowHeight : wordLineHeight)
                    .accessibilityHidden(true)
                HStack(spacing: symbols ? ResectaTokens.Spacing.xs : Bar.selectionBarWordGap) {
                    duplicateButton(duplicateTarget, symbols: symbols)
                    deleteButton(count, symbols: symbols)
                }
            }
            if limitShows {
                Text(RedactionState.lassoSelectionCapToastMessage)
                    .font(.footnote)
                    .foregroundStyle(Bar.selectionBarQuietColour)
                    .accessibilityIdentifier("selectionBarLimit")
                    .transition(.opacity)
            }
        }
        // A tap on the bar stays on the bar: none reaches the page under it.
        // The shape is the slot's whole glass, not only the row: a shape on
        // the row alone also stopped the actions' 44-pt hit areas at the
        // row's edge, so a tap near the glass's top or foot fell through to
        // the page and ended the selection.
        .padding(.vertical, Bar.bottomSlotVerticalPadding)
        .padding(.horizontal, Bar.bottomSlotHorizontalPadding)
        .contentShape(Rectangle())
        .padding(.vertical, -Bar.bottomSlotVerticalPadding)
        .padding(.horizontal, -Bar.bottomSlotHorizontalPadding)
        .animation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.stateChange, reduceMotion: reduceMotion), value: limitShows)
        .task(id: redactionState.lassoCut) { await runLimitLine() }
        // The line ends when the bar leaves.
        .onDisappear { redactionState.lassoCut = nil }
    }

    /// Speak the limit's line once as it appears, then draw the bar again
    /// when it runs out.
    private func runLimitLine() async {
        guard let cut = redactionState.lassoCut, cut.selection == redactionState.selectedRegionIDs else { return }
        let remaining = Bar.selectionLimitLineSeconds(voiceOverRunning: voiceOverRunning) - Date.now.timeIntervalSince(cut.at)
        guard remaining > 0 else { return }
        AccessibilityNotification.Announcement(RedactionState.lassoSelectionCapToastMessage).post()
        try? await Task.sleep(for: .seconds(remaining))
        clock &+= 1
    }

    private func countView(_ count: Int) -> some View {
        // Sized for two digits, so the bar keeps its width from 1 to 99.
        ZStack(alignment: .leading) {
            Text(Bar.selectionBarCount(88)).hidden().accessibilityHidden(true)
            Text(Bar.selectionBarCount(count))
        }
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(Bar.selectionBarQuietColour)
        .lineLimit(1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Bar.selectionBarCountSpoken(count))
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("selectionBarCount")
        .accessibilityShowsLargeContentViewer {
            Text(Bar.selectionBarCount(count))
        }
    }

    private func duplicateButton(_ target: RedactionRegion?, symbols: Bool) -> some View {
        Button {
            guard let target else { return }
            let page = redactionState.pageIndex(for: target.id) ?? 0
            redactionState.duplicateRegion(target.id, page: page, undoManager: toolbar.undoManager)
        } label: {
            actionLabel(word: Bar.selectionBarDuplicateWord, symbol: Bar.selectionBarDuplicateSymbol,
                        wordColour: Bar.selectionBarDuplicateColour, symbolColour: Bar.selectionBarDuplicateColour,
                        symbols: symbols)
                .opacity(target == nil ? Bar.selectionBarDimmedOpacity : 1)
        }
        .modifier(SelectionBarHitArea(symbols: symbols, wordLineHeight: wordLineHeight))
        .accessibilityLabel(Bar.selectionBarDuplicateSpoken)
        .accessibilityIdentifier("selectionBarDuplicate")
        .accessibilityShowsLargeContentViewer {
            Label(Bar.selectionBarDuplicateWord, systemImage: Bar.selectionBarDuplicateSymbol)
        }
        .disabled(target == nil)
    }

    private func deleteButton(_ count: Int, symbols: Bool) -> some View {
        Button {
            toolbar.deleteSelection()
        } label: {
            actionLabel(word: Bar.selectionBarDeleteWord, symbol: Bar.selectionBarDeleteSymbol,
                        wordColour: Bar.selectionBarDeleteWordColour, symbolColour: Bar.selectionBarDeleteSymbolColour,
                        symbols: symbols)
        }
        .modifier(SelectionBarHitArea(symbols: symbols, wordLineHeight: wordLineHeight))
        .accessibilityLabel(Bar.selectionBarDeleteSpoken(count))
        .accessibilityIdentifier("selectionBarDelete")
        .accessibilityShowsLargeContentViewer {
            Label(Bar.selectionBarDeleteWord, systemImage: Bar.selectionBarDeleteSymbol)
        }
    }

    @ViewBuilder
    private func actionLabel(word: String, symbol: String, wordColour: Color, symbolColour: Color, symbols: Bool) -> some View {
        if symbols {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(symbolColour)
        } else {
            Text(word)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(wordColour)
                .lineLimit(1)
        }
    }
}

/// An action's tappable frame. A word: padded to the touch target's height,
/// and beside it past half the gap to its neighbour, then the padding given
/// back so the word does not move (as Add to Selection's Done). A symbol: a
/// real 46 × 46 frame, reaching past the row above and below.
struct SelectionBarHitArea: ViewModifier {
    let symbols: Bool
    let wordLineHeight: CGFloat

    func body(content: Content) -> some View {
        let size = DocumentEditorView.selectionBarHitSize
        if symbols {
            let overhang = (size - DocumentEditorView.selectionBarSymbolRowHeight) / 2
            content
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .padding(.vertical, -overhang)
        } else {
            let vertical = DocumentEditorView.selectionBarHitPadding(lineHeight: wordLineHeight)
            let side = DocumentEditorView.selectionBarWordSidePadding
            content
                .padding(.vertical, vertical).padding(.horizontal, side)
                .frame(minWidth: size)
                .contentShape(Rectangle())
                .padding(.vertical, -vertical).padding(.horizontal, -side)
        }
    }
}
