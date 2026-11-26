import SwiftUI
import UIKit

/// What one notice says: its words, tone and action label from its row in
/// the message table, an optional second line, the words VoiceOver speaks
/// when they differ from the visible ones, whether it has a close, and its
/// identifier. Made only from a row, so a notice's words have one home.
struct NoticeContent: Equatable {
    let id: MessageID
    let text: String
    let detail: String?
    let spokenText: String?
    let tone: MessageTone
    let actionLabel: String?
    let closes: Bool
    let identifier: String

    init(id: MessageID, detail: String? = nil, spokenText: String? = nil, closes: Bool, identifier: String) {
        let row = MessageCatalog.row(for: id)
        self.id = id
        self.text = row.text
        self.detail = detail
        self.spokenText = spokenText
        self.tone = row.tone
        self.actionLabel = row.actionLabel
        self.closes = closes
        self.identifier = identifier
    }

    /// What VoiceOver speaks for the notice: the spoken text when one is
    /// given, else the words and the second line.
    var spokenLine: String {
        if let spokenText { return spokenText }
        guard let detail else { return text }
        return "\(text) \(detail)"
    }

    /// The words a reading time counts: the words and the second line.
    var wordCount: Int {
        NoticeRules.wordCount(text) + NoticeRules.wordCount(detail ?? "")
    }
}

/// A notice: a fact about the document or the run, drawn on the message
/// surface until it is closed or its condition ends. Near-black in the
/// light appearance and near-white in the dark one, its mark, its words
/// never cut, at most one action and a close. In the editor's band it
/// floats over the canvas; in Settings it is the first row of its form.
struct NoticeView: View {
    enum Placement: Equatable {
        case band
        case formRow
    }

    let content: NoticeContent
    var onAction: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    let placement: Placement

    @Environment(\.colorScheme) private var appearance
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The notice's geometry: named constants and no others.
    // nonisolated: plain numbers, read inside layout closures.
    nonisolated enum Metrics {
        static let corner: CGFloat = 22
        /// From each side of the canvas, in the band.
        static let sideInset: CGFloat = 16
        /// Under the toolbar's foot, in the band.
        static let gapUnderToolbar: CGFloat = 8
        static let verticalPadding: CGFloat = 12
        static let leadingPadding: CGFloat = 14
        static let trailingPadding: CGFloat = 14
        /// The trailing padding when a control ends the row.
        static let trailingPaddingBesideControl: CGFloat = 6
        static let markSide: CGFloat = 20
        static let markToWords: CGFloat = 10
        static let wordsToDetail: CGFloat = 2
        static let markSymbolSize: CGFloat = 17
        static let actionHeight: CGFloat = 32
        static let actionPadding: CGFloat = 12
        static let actionCorner: CGFloat = 16
        static let closeGlyph: CGFloat = 13
        /// The close's drawn place: the glyph centred in this box.
        static let closeBoxWidth: CGFloat = 26
        static let closeBoxHeight: CGFloat = 30
        /// Between the action's capsule and the close's glyph box.
        static let capsuleToCloseBox: CGFloat = 10
        static let largeSpacing: CGFloat = 10
        static let foldedSide: CGFloat = 44
        static let badgeHeight: CGFloat = 18
        static let badgeMinimumWidth: CGFloat = 18
        static let badgePadding: CGFloat = 4
        static let badgeCorner: CGFloat = 9
        static let badgeFont: CGFloat = 11
        /// The numeral's offset out from the mark's top trailing corner.
        static let badgeOffset: CGFloat = 3
    }

    /// The tappable side of the close, the action's height and the folded
    /// mark, in layout.
    static let touchSide: CGFloat = ResectaTokens.TouchTarget.minimum

    var body: some View {
        let large = dynamicTypeSize.isAccessibilitySize
        Group {
            if large { largeLayout } else { standardLayout }
        }
        // The content takes the opposite scheme, so the tokens resolve for
        // the surface under it (light words on ink).
        .environment(\.colorScheme, appearance == .dark ? .light : .dark)
        .background { NoticeSurface(shape: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous),
                                     appearance: appearance) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(content.identifier)
        .padding(.horizontal, placement == .band ? Metrics.sideInset : 0)
    }

    // MARK: - Layouts

    private var standardLayout: some View {
        let hasAction = content.actionLabel != nil && onAction != nil
        let hasClose = content.closes && onClose != nil && placement == .band
        return HStack(alignment: hasAction ? .center : .top, spacing: Metrics.capsuleToCloseBox) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.markToWords) {
                mark.frame(width: Metrics.markSide, height: Metrics.markSide)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Metrics.markSide * 0.28 }
                words
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hasAction, let actionLabel = content.actionLabel {
                actionButton(actionLabel, fullWidth: false)
            }
            if hasClose { closeButton }
        }
        .padding(.vertical, Metrics.verticalPadding)
        .padding(.leading, Metrics.leadingPadding)
        .padding(.trailing, hasAction || hasClose ? Metrics.trailingPaddingBesideControl : Metrics.trailingPadding)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// At the accessibility sizes: the mark above the words, the action a
    /// full-width capsule under them, the close at the top trailing corner.
    private var largeLayout: some View {
        let hasClose = content.closes && onClose != nil && placement == .band
        return VStack(alignment: .leading, spacing: Metrics.largeSpacing) {
            mark.frame(width: Metrics.markSide, height: Metrics.markSide)
            words
            if let actionLabel = content.actionLabel, onAction != nil {
                actionButton(actionLabel, fullWidth: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Metrics.verticalPadding)
        .padding(.leading, Metrics.leadingPadding)
        .padding(.trailing, Metrics.trailingPadding)
        .overlay(alignment: .topTrailing) {
            if hasClose { closeButton.padding(.top, Metrics.verticalPadding / 2) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Parts

    private var mark: some View {
        Image(systemName: Self.symbol(for: content.tone))
            .font(.system(size: Metrics.markSymbolSize))
            .foregroundStyle(Self.markColor(for: content.tone))
            .accessibilityHidden(true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: Metrics.wordsToDetail) {
            Text(content.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ResectaTokens.Ink.words)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = content.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(ResectaTokens.Ink.secondaryWords)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.spokenLine)
        .accessibilityAddTraits(.isStaticText)
    }

    /// The action: a solid capsule 32 tall, tappable 46 tall in layout. The
    /// row lays out the capsule; the button is laid over it, so its frame
    /// may be taller than the capsule without moving the row.
    private func actionButton(_ actionLabel: String, fullWidth: Bool) -> some View {
        capsule(actionLabel, fullWidth: fullWidth)
            .hidden()
            .accessibilityHidden(true)
            .overlay {
                Button {
                    onAction?()
                } label: {
                    capsule(actionLabel, fullWidth: fullWidth)
                        .frame(minWidth: Self.touchSide)
                        .frame(height: Self.touchSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(actionLabel)
                .accessibilityIdentifier("noticeAction")
            }
    }

    private func capsule(_ actionLabel: String, fullWidth: Bool) -> some View {
        Text(actionLabel)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ResectaTokens.Ink.solidPillWords)
            .padding(.horizontal, Metrics.actionPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: Metrics.actionHeight)
            .background(RoundedRectangle(cornerRadius: Metrics.actionCorner, style: .continuous)
                .fill(ResectaTokens.Ink.solidPill))
            .fixedSize(horizontal: !fullWidth, vertical: true)
    }

    /// The close: a 13-point glyph centred in its 26 by 30 place, tappable
    /// 46 by 46 in layout around that place. The row keeps the place's
    /// width and one line's height, so a one-line notice stays 44 tall.
    private var closeButton: some View {
        Color.clear
            .frame(width: Metrics.closeBoxWidth, height: Metrics.markSide)
            .overlay {
                Button {
                    onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: Metrics.closeGlyph, weight: .semibold))
                        .foregroundStyle(ResectaTokens.Ink.secondaryWords)
                        .frame(width: Metrics.closeBoxWidth, height: Metrics.closeBoxHeight)
                        .frame(width: Self.touchSide, height: Self.touchSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.closeLabel)
                .accessibilityIdentifier("noticeClose")
            }
    }

    // MARK: - Pure parts (pinned by tests)

    /// The close's label, its one home.
    static let closeLabel = "Dismiss"

    static func symbol(for tone: MessageTone) -> String {
        switch tone {
        case .done: "checkmark"
        case .note: "info.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .stop: "exclamationmark.octagon.fill"
        }
    }

    /// A mark is a glyph, so it takes the message surface's own colour.
    static func markColor(for tone: MessageTone) -> Color {
        switch tone {
        case .done: ResectaTokens.Ink.words
        case .note: ResectaTokens.Ink.noteMark
        case .caution: ResectaTokens.Ink.cautionMark
        case .stop: ResectaTokens.Ink.stopMark
        }
    }

    /// The notice's height at `size` in a container `width` wide: a copy
    /// laid out at that size and measured, as the receipt's measure is, so
    /// the size step reads the height that is drawn. Kept per content,
    /// size and width.
    static func height(of content: NoticeContent, size: DynamicTypeSize, width: CGFloat) -> CGFloat {
        let key = MeasureKey(content: content, size: size, width: width)
        if let known = measuredHeights[key] { return known }
        // Closures stand in for the action and the close: the copy is laid
        // out, never shown, so they never run.
        let view = NoticeView(content: content, onAction: {}, onClose: {}, placement: .band)
            .environment(\.dynamicTypeSize, size)
        let height = UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        if measuredHeights.count >= 64 { measuredHeights.removeAll() }
        measuredHeights[key] = height
        return height
    }

    private struct MeasureKey: Hashable {
        let text: String
        let detail: String?
        let tone: MessageTone
        let actionLabel: String?
        let closes: Bool
        let size: DynamicTypeSize
        let width: CGFloat

        init(content: NoticeContent, size: DynamicTypeSize, width: CGFloat) {
            text = content.text
            detail = content.detail
            tone = content.tone
            actionLabel = content.actionLabel
            closes = content.closes
            self.size = size
            self.width = width
        }
    }

    private static var measuredHeights: [MeasureKey: CGFloat] = [:]
}

/// A folded notice: its mark alone in a 44-point circle of the same
/// surface, at the band's trailing end, with the number of notices that
/// hold when two or more do. A tap opens the notice. VoiceOver hears the
/// notice's own words; the numeral is hidden from it, since its spoken
/// form has no words yet.
struct NoticeFoldedMark: View {
    let content: NoticeContent
    let count: Int?
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var appearance

    var body: some View {
        // The mark and the numeral take the content's scheme, the opposite
        // of the app's appearance, as the notice's words do.
        let contentScheme: ColorScheme = appearance == .dark ? .light : .dark
        Button(action: onOpen) {
            Image(systemName: NoticeView.symbol(for: content.tone))
                .font(.system(size: NoticeView.Metrics.markSymbolSize))
                .foregroundStyle(NoticeView.markColor(for: content.tone))
                .environment(\.colorScheme, contentScheme)
                .frame(width: NoticeView.Metrics.foldedSide, height: NoticeView.Metrics.foldedSide)
                .background { NoticeSurface(shape: Circle(), appearance: appearance) }
                .overlay(alignment: .topTrailing) {
                    if let count { badge(count).environment(\.colorScheme, contentScheme) }
                }
                .frame(width: NoticeView.touchSide, height: NoticeView.touchSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(content.spokenLine)
        .accessibilityIdentifier("noticeFoldedMark")
    }

    private func badge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: NoticeView.Metrics.badgeFont, weight: .bold))
            .foregroundStyle(ResectaTokens.Ink.solidPillWords)
            .padding(.horizontal, NoticeView.Metrics.badgePadding)
            .frame(minWidth: NoticeView.Metrics.badgeMinimumWidth, minHeight: NoticeView.Metrics.badgeHeight)
            .background(RoundedRectangle(cornerRadius: NoticeView.Metrics.badgeCorner, style: .continuous)
                .fill(ResectaTokens.Ink.solidPill))
            .fixedSize()
            .offset(x: NoticeView.Metrics.badgeOffset, y: -NoticeView.Metrics.badgeOffset)
            .accessibilityHidden(true)
    }
}

/// The message surface behind a notice or its folded mark, drawn with the
/// receipt's calls: the material and the ink fill set from the app's
/// appearance, the two edges under the content's scheme, the two shadows.
struct NoticeSurface<S: InsettableShape>: View {
    let shape: S
    /// The app's appearance, which the fill and the shadows are set from.
    let appearance: ColorScheme

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shadows = ResectaTokens.Ink.shadows(for: appearance)
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(ResectaTokens.Ink.surface(for: appearance, increasedContrast: contrast == .increased))
        }
        .overlay {
            ZStack {
                shape.strokeBorder(ResectaTokens.Ink.innerEdge, lineWidth: ResectaTokens.Ink.edgeWidth)
                shape.inset(by: -ResectaTokens.Ink.edgeWidth)
                    .strokeBorder(ResectaTokens.Ink.outerEdge, lineWidth: ResectaTokens.Ink.edgeWidth)
            }
            // The edges resolve under the content's scheme, as the words do.
            .environment(\.colorScheme, appearance == .dark ? .light : .dark)
        }
        .shadow(color: .black.opacity(shadows[0].opacity), radius: shadows[0].blur / 2, y: shadows[0].y)
        .shadow(color: .black.opacity(shadows[1].opacity), radius: shadows[1].blur / 2, y: shadows[1].y)
        .accessibilityHidden(true)
    }
}
