import SwiftUI
import UIKit

// The line a first document shows in the bottom slot: how to begin, on the
// message surface with the brief message's geometry, until the person's
// first action. Its second sentence names the Redact button where the bar
// shows it and the More menu where Redact is folded into it, read from the
// bar's own layout value.

/// The line's words: visible and spoken.
enum FirstDocumentHintWords {
    static let firstSentence = "Draw a box, or use Search or Scan."
    /// Around the Redact button's symbol, where the bar shows it.
    static let onBarLead = "Then tap"
    static let onBarTail = "to redact."
    /// Around the More symbol, where Redact is a row of the More menu.
    static let foldedLead = "Then tap"
    static let foldedTail = "and choose Redact."
    /// As VoiceOver reads it, at every text size.
    static let spoken = "Use Search or Scan. Then use Redact."
    /// The Redact button's symbol and the More menu's, as the toolbar draws them.
    static let redactSymbol = "scissors"
    static let moreSymbol = "ellipsis"

    /// Whether the bar shows Redact at the person's text size: the toolbar
    /// layout's own answer.
    static func redactOnBar(_ size: DynamicTypeSize) -> Bool {
        EditorToolbarLayout(dynamicTypeSize: size, canUndo: false, canRedo: false).trailing.contains(.redact)
    }

    /// The second sentence at the person's text size: its words before the
    /// symbol, the symbol, its words after.
    static func secondSentence(_ size: DynamicTypeSize) -> (lead: String, symbol: String, tail: String) {
        redactOnBar(size)
            ? (onBarLead, redactSymbol, onBarTail)
            : (foldedLead, moreSymbol, foldedTail)
    }
}

/// The line, drawn at the size its environment gives it; its words follow
/// the bar at the person's own size.
struct FirstDocumentHintView: View {
    /// The person's text size, which the bar's layout reads.
    let personSize: DynamicTypeSize

    @Environment(\.colorScheme) private var appearance
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private typealias Metrics = ReceiptView.Metrics

    var body: some View {
        let large = ReceiptView.takesLargeLayout(dynamicTypeSize)
        let shape = RoundedRectangle(cornerRadius: large ? Metrics.largeCorner : Metrics.corner, style: .continuous)
        return words
            .font(.callout.weight(.medium))
            .foregroundStyle(ResectaTokens.Ink.words)
            .padding(.vertical, large ? Metrics.largeVerticalPadding : Metrics.verticalPadding)
            .padding(.horizontal, large ? Metrics.largeHorizontalPadding : Metrics.leadingPadding)
            .frame(minHeight: Metrics.oneLineHeight)
            .frame(maxWidth: large ? .infinity : Metrics.maximumWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // The words take the opposite scheme, so the shipped tokens
            // resolve for the surface under them, as on a brief message.
            .environment(\.colorScheme, appearance == .dark ? .light : .dark)
            .background { surface(shape) }
            // A touch on the line reaches nothing under it.
            .contentShape(shape)
            .onTapGesture {}
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FirstDocumentHintWords.spoken)
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("firstDocumentHint")
            .padding(.horizontal, Metrics.sideMargin)
    }

    /// Two texts, one per sentence: side by side when both fit on one line,
    /// the second under the first when they do not.
    private var words: some View {
        let second = FirstDocumentHintWords.secondSentence(personSize)
        let first = Text(FirstDocumentHintWords.firstSentence)
        let rest = Text("\(second.lead) \(Image(systemName: second.symbol)) \(second.tail)")
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: ResectaTokens.Spacing.xs) {
                first
                rest
            }
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                first.fixedSize(horizontal: false, vertical: true)
                rest.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The message surface: the ink fill, its two edges and its two shadows.
    private func surface(_ shape: RoundedRectangle) -> some View {
        let shadows = ResectaTokens.Ink.shadows(for: appearance)
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(ResectaTokens.Ink.surface(for: appearance, increasedContrast: contrast == .increased))
        }
        .overlay {
            ZStack {
                shape.strokeBorder(ResectaTokens.Ink.innerEdge, lineWidth: ResectaTokens.Ink.edgeWidth)
                shape.inset(by: -ResectaTokens.Ink.edgeWidth)
                    .strokeBorder(ResectaTokens.Ink.outerEdge, lineWidth: ResectaTokens.Ink.edgeWidth)
            }
            .environment(\.colorScheme, appearance == .dark ? .light : .dark)
        }
        .shadow(color: .black.opacity(shadows[0].opacity), radius: shadows[0].blur / 2, y: shadows[0].y)
        .shadow(color: .black.opacity(shadows[1].opacity), radius: shadows[1].blur / 2, y: shadows[1].y)
        .accessibilityHidden(true)
    }

    // MARK: - Its measure

    private struct MeasureKey: Hashable {
        let personSize: DynamicTypeSize
        let size: DynamicTypeSize
        let width: CGFloat
    }

    private static var measuredHeights: [MeasureKey: CGFloat] = [:]

    /// The line's block at `size`, `width` points wide: what the sizing
    /// function weighs against the limit.
    static func height(personSize: DynamicTypeSize, size: DynamicTypeSize, width: CGFloat) -> CGFloat {
        let key = MeasureKey(personSize: personSize, size: size, width: width)
        if let known = measuredHeights[key] { return known }
        let view = FirstDocumentHintView(personSize: personSize).environment(\.dynamicTypeSize, size)
        let height = UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        if measuredHeights.count >= 64 { measuredHeights.removeAll() }
        measuredHeights[key] = height
        return height
    }

    /// The size the line is drawn at in a canvas of `canvas`: the person's,
    /// unless its block would then be taller than two fifths of the canvas;
    /// then by the brief message's one sizing rule.
    static func drawSize(personSize: DynamicTypeSize, canvas: CGSize) -> DynamicTypeSize {
        guard canvas.width > 0 else { return personSize }
        return MessageSizing.drawSize(person: personSize, limit: MessageSizing.limit(space: canvas.height)) {
            height(personSize: personSize, size: $0, width: canvas.width)
        }
    }
}
