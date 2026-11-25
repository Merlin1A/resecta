import SwiftUI
import UIKit

/// A notice in a sheet: one line's text on the message surface, its caution
/// mark, and, when the notice has a control, a quiet pill holding a chevron.
/// It draws with the notice view's metrics and the message tokens and keeps
/// no number, colour or surface of its own for a part the notice view has,
/// so when those change both move. Its words are a sentence built with page
/// numbers, not a row of the message table, so it does not mount the notice
/// view itself.
///
/// For VoiceOver it is one element named by the whole sentence, even when the
/// drawn text is its first part; the mark and the pill are hidden. A notice
/// that opens the details is a button; one that only folds is static text.
struct SheetNoticeView: View {
    let text: String
    let spokenLine: String
    let lineLimit: Int?
    let control: SearchNoticePlace.Control
    let isHeld: Bool
    let identifier: String
    var onTap: () -> Void = {}

    @Environment(\.colorScheme) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private typealias Metrics = NoticeView.Metrics

    var body: some View {
        let large = dynamicTypeSize.isAccessibilitySize
        Group {
            if large { largeLayout } else { standardLayout }
        }
        // The content takes the opposite scheme, so the tokens resolve for the
        // surface under it (light words on ink), as the notice view's do.
        .environment(\.colorScheme, appearance == .dark ? .light : .dark)
        .background { NoticeSurface(shape: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous),
                                     appearance: appearance) }
        .contentShape(Rectangle())
        .onTapGesture { if control != .none { onTap() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLine)
        .accessibilityAddTraits(control == .opensDetails ? .isButton : .isStaticText)
        .accessibilityIdentifier(identifier)
    }

    /// The chevron the pill holds, or nil when the notice shows no pill: a
    /// right chevron opens the details, a down chevron unfolds a folded one.
    static func chevron(for control: SearchNoticePlace.Control) -> String? {
        switch control {
        case .none, .foldsInPlace(folded: false): nil
        case .foldsInPlace(folded: true): "chevron.down"
        case .opensDetails: "chevron.right"
        }
    }

    // MARK: - Layouts

    private var standardLayout: some View {
        let chevron = Self.chevron(for: control)
        return HStack(alignment: .center, spacing: Metrics.capsuleToCloseBox) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.markToWords) {
                mark.frame(width: Metrics.markSide, height: Metrics.markSide)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Metrics.markSide * 0.28 }
                words
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let chevron { pill(chevron) }
        }
        .padding(.vertical, Metrics.verticalPadding)
        .padding(.leading, Metrics.leadingPadding)
        .padding(.trailing, chevron != nil ? Metrics.trailingPaddingBesideControl : Metrics.trailingPadding)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// At the accessibility sizes: the mark above the words, the pill at the
    /// top trailing corner, as the notice view lays out its own parts.
    private var largeLayout: some View {
        VStack(alignment: .leading, spacing: Metrics.largeSpacing) {
            mark.frame(width: Metrics.markSide, height: Metrics.markSide)
            words
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Metrics.verticalPadding)
        .padding(.leading, Metrics.leadingPadding)
        .padding(.trailing, Metrics.trailingPadding)
        .overlay(alignment: .topTrailing) {
            if let chevron = Self.chevron(for: control) {
                pill(chevron).padding(.top, Metrics.verticalPadding / 2).padding(.trailing, Metrics.trailingPaddingBesideControl)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Parts

    private var mark: some View {
        Image(systemName: NoticeView.symbol(for: .caution))
            .font(.system(size: Metrics.markSymbolSize))
            .foregroundStyle(NoticeView.markColor(for: .caution))
            .accessibilityHidden(true)
    }

    private var words: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(ResectaTokens.Ink.words)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(isHeld ? SearchNoticePlace.heldWordsOpacity : 1)
    }

    private func pill(_ chevron: String) -> some View {
        Image(systemName: chevron)
            .font(.system(size: Metrics.closeGlyph, weight: .semibold))
            .foregroundStyle(ResectaTokens.Ink.words)
            .opacity(isHeld ? SearchNoticePlace.heldWordsOpacity : 1)
            .padding(.horizontal, ReceiptView.Metrics.pillPadding)
            .frame(height: ReceiptView.Metrics.pillHeight)
            .background(Capsule().fill(ResectaTokens.Ink.quietPill))
            .accessibilityHidden(true)
    }

    // MARK: - Measure

    /// The notice's height for `text` drawn with `lineLimit` lines at most,
    /// with or without the pill, at `size` in a container `width` wide: a
    /// copy laid out and measured, as the notice view's own measure is.
    static func height(text: String, lineLimit: Int?, control: SearchNoticePlace.Control,
                       size: DynamicTypeSize, width: CGFloat) -> CGFloat {
        let key = MeasureKey(text: text, lineLimit: lineLimit, chevron: chevron(for: control), size: size, width: width)
        if let known = measuredHeights[key] { return known }
        let view = SheetNoticeView(text: text, spokenLine: text, lineLimit: lineLimit, control: control,
                                   isHeld: false, identifier: "")
            .environment(\.dynamicTypeSize, size)
        let height = UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        if measuredHeights.count >= 64 { measuredHeights.removeAll() }
        measuredHeights[key] = height
        return height
    }

    private struct MeasureKey: Hashable {
        let text: String
        let lineLimit: Int?
        let chevron: String?
        let size: DynamicTypeSize
        let width: CGFloat
    }

    private static var measuredHeights: [MeasureKey: CGFloat] = [:]
}
