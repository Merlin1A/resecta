import SwiftUI
import UIKit

/// A brief message: one capsule at the bottom of whatever is in front,
/// near-black in the light appearance and near-white in the dark, a small
/// mark for its tone, its words never cut, and its action (if any) a real
/// button. A tap beside the action does nothing; a tap on a message with no
/// action dismisses it; a downward drag of 20 points dismisses either.
///
/// The queue arrives as a `let`, never through the environment: a body
/// re-evaluated inside a sheet's dismissal transaction cannot resolve an
/// observable environment read and traps (`ToastManagerLetInjectionTests`).
struct ReceiptView: View {
    let item: ToastItem
    let toastManager: ToastQueueManager

    @Environment(\.colorScheme) private var appearance
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var markSide: CGFloat = Metrics.markSide
    @AccessibilityFocusState private var wordsFocused: Bool
    @AccessibilityFocusState private var actionFocused: Bool
    @State private var receiptHeight: CGFloat = Metrics.oneLineHeight
    @State private var touching = false

    /// The receipt's geometry: named constants and no others.
    enum Metrics {
        static let oneLineHeight: CGFloat = 44
        static let corner: CGFloat = 22
        static let verticalPadding: CGFloat = 11.5
        static let leadingPadding: CGFloat = 16
        static let trailingPadding: CGFloat = 16
        static let trailingPaddingWithAction: CGFloat = 7
        static let markSide: CGFloat = 20
        static let markToWords: CGFloat = 10
        /// Half the callout's capital height as a share of the mark's box:
        /// the box's centre sits that far above the first baseline.
        static let markCapitalsShare: CGFloat = 0.28
        static let wordsToAction: CGFloat = 12
        static let pillHeight: CGFloat = 30
        static let pillPadding: CGFloat = 13
        /// The action's tappable frame starts this far before its pill.
        static let actionLeadIn: CGFloat = 8
        static let minimumWidth: CGFloat = 120
        static let maximumWidth: CGFloat = 360
        /// Space kept clear on each side of the receipt.
        static let sideMargin: CGFloat = 16
        static let largeCorner: CGFloat = 28
        static let largeVerticalPadding: CGFloat = 16
        static let largeHorizontalPadding: CGFloat = 18
        static let largePillVertical: CGFloat = 8
        static let largePillHorizontal: CGFloat = 20
        static let largeWordsToAction: CGFloat = 12
        static let dismissDragDistance: CGFloat = 20
    }

    var body: some View {
        let large = Self.takesLargeLayout(dynamicTypeSize)
        Group {
            if large { largeLayout } else { standardLayout }
        }
        // The content takes the opposite scheme, so the shipped tokens
        // resolve for the surface under it (white words on ink).
        .environment(\.colorScheme, appearance == .dark ? .light : .dark)
        .background { surface(large: large) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(item.actionHandler == nil ? "toastMessage" : "toastMessageWithAction")
        .contentShape(RoundedRectangle(cornerRadius: large ? Metrics.largeCorner : Metrics.corner,
                                       style: .continuous))
        .onTapGesture {
            // Beside an action, a tap does nothing: the action is the button.
            if item.actionHandler == nil { toastManager.dismiss(item) }
        }
        .simultaneousGesture(dragToDismiss)
        .onChange(of: wordsFocused) { _, focused in noteFocus(focused || actionFocused) }
        .onChange(of: actionFocused) { _, focused in noteFocus(focused || wordsFocused) }
        // A margin each side, outside the capsule and its element: at the
        // large sizes the capsule takes the rest of the width; at the
        // standard sizes it hugs its words within it.
        .padding(.horizontal, Metrics.sideMargin)
    }

    // MARK: - Layouts

    private var standardLayout: some View {
        // The mark's box is centred on the first line's capitals.
        let markDrop = markSide * Metrics.markCapitalsShare
        return HStack(alignment: .firstTextBaseline, spacing: Metrics.markToWords) {
            mark.frame(width: markSide, height: markSide)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + markDrop }
            words
            if let actionLabel = item.actionLabel, item.actionHandler != nil {
                // Room for the action, which is laid over the capsule so its
                // tappable frame may be taller than the capsule it sits on.
                pill(actionLabel).hidden().accessibilityHidden(true)
                    .padding(.leading, Metrics.wordsToAction - Metrics.markToWords)
            }
        }
        .padding(.vertical, Metrics.verticalPadding)
        .padding(.leading, Metrics.leadingPadding)
        .padding(.trailing, item.actionHandler == nil ? Metrics.trailingPadding : Metrics.trailingPaddingWithAction)
        .frame(minHeight: Metrics.oneLineHeight)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(HugsItsWords())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { receiptHeight = $0 }
        .overlay(alignment: .trailing) {
            if let actionLabel = item.actionLabel, let handler = item.actionHandler {
                actionButton(actionLabel, handler: handler) {
                    pill(actionLabel)
                        .padding(.leading, Metrics.actionLeadIn)
                        .padding(.trailing, Metrics.trailingPaddingWithAction)
                        .frame(height: Self.actionFrameHeight(receiptHeight: receiptHeight))
                        .contentShape(Rectangle())
                }
            }
        }
    }

    private var largeLayout: some View {
        VStack(alignment: .trailing, spacing: Metrics.largeWordsToAction) {
            Text("\(Text(Image(systemName: Self.symbol(for: item.tone))).foregroundStyle(Self.markColor(for: item.tone)))\u{2009}\(item.message)")
                .font(.callout.weight(.medium))
                .foregroundStyle(ResectaTokens.Ink.words)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.message)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityFocused($wordsFocused)
            if let actionLabel = item.actionLabel, let handler = item.actionHandler {
                actionButton(actionLabel, handler: handler) {
                    Text(actionLabel)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(ResectaTokens.Ink.words)
                        .padding(.vertical, Metrics.largePillVertical)
                        .padding(.horizontal, Metrics.largePillHorizontal)
                        .background(Capsule().fill(ResectaTokens.Ink.quietPill))
                        .frame(minHeight: ResectaTokens.TouchTarget.minimum)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.vertical, Metrics.largeVerticalPadding)
        .padding(.horizontal, Metrics.largeHorizontalPadding)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Parts

    private var mark: some View {
        Image(systemName: Self.symbol(for: item.tone))
            .font(.system(size: Self.symbolPointSize(for: item.tone),
                          weight: item.tone == .done ? .bold : .regular))
            .foregroundStyle(Self.markColor(for: item.tone))
            .accessibilityHidden(true)
    }

    private var words: some View {
        Text(item.message)
            .font(.callout.weight(.medium))
            .foregroundStyle(ResectaTokens.Ink.words)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(item.message)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityFocused($wordsFocused)
    }

    private func pill(_ actionLabel: String) -> some View {
        Text(actionLabel)
            .font(.callout.weight(.semibold))
            .foregroundStyle(ResectaTokens.Ink.words)
            .padding(.horizontal, Metrics.pillPadding)
            .frame(height: Metrics.pillHeight)
            .background(Capsule().fill(ResectaTokens.Ink.quietPill))
    }

    /// The action: its handler first, then the dismissal (the queue's
    /// guard sits inside the handler). Spoken "<label> action".
    private func actionButton<Label: View>(_ actionLabel: String, handler: @escaping @MainActor () -> Void,
                                           @ViewBuilder label: () -> Label) -> some View {
        Button {
            handler()
            toastManager.dismiss(item)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(actionLabel) action")
        .accessibilityFocused($actionFocused)
    }

    private func surface(large: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: large ? Metrics.largeCorner : Metrics.corner, style: .continuous)
        let shadows = ResectaTokens.Ink.shadows(for: appearance)
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(ResectaTokens.Ink.surface(for: appearance, increasedContrast: contrast == .increased))
        }
        .overlay {
            // The edges resolve under the content's scheme, as the words do.
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

    private var dragToDismiss: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !touching else { return }
                touching = true
                toastManager.holdClock(item.id, .touch, true)
            }
            .onEnded { value in
                touching = false
                toastManager.holdClock(item.id, .touch, false)
                if value.translation.height >= Metrics.dismissDragDistance { toastManager.dismiss(item) }
            }
    }

    private func noteFocus(_ focused: Bool) {
        toastManager.holdClock(item.id, .voiceOverFocus, focused)
        if focused { toastManager.noteFocused(item.id) }
    }

    // MARK: - Pure parts (pinned by tests)

    /// The large layout from the first accessibility size up.
    static func takesLargeLayout(_ size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    /// The action's tappable height: the receipt's own, never under the
    /// touch floor in layout (46: 44 on screen in a sheet drawn at 0.96).
    static func actionFrameHeight(receiptHeight: CGFloat) -> CGFloat {
        max(receiptHeight, ResectaTokens.TouchTarget.minimum)
    }

    static func symbol(for tone: MessageTone) -> String {
        switch tone {
        case .done: "checkmark"
        case .note: "info.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .stop: "exclamationmark.octagon.fill"
        }
    }

    static func symbolPointSize(for tone: MessageTone) -> CGFloat {
        tone == .done ? 15 : 18
    }

    static func markColor(for tone: MessageTone) -> Color {
        switch tone {
        case .done: ResectaTokens.Ink.words
        case .note: ResectaTokens.Ink.noteMark
        case .caution: ResectaTokens.Ink.cautionMark
        case .stop: ResectaTokens.Ink.stopMark
        }
    }

    /// The receipt's height at `size` in a container `width` wide: a copy
    /// of the receipt laid out at that size and measured, so the sizing
    /// step reads the height that is drawn (an estimate from the font's
    /// line height missed SwiftUI's lines by up to 6 points at the larger
    /// sizes). Kept per words, action, tone, size and width.
    static func height(of item: ToastItem, size: DynamicTypeSize, width: CGFloat) -> CGFloat {
        let key = MeasureKey(text: item.message, actionLabel: item.actionLabel, tone: item.tone, size: size, width: width)
        if let known = measuredHeights[key] { return known }
        let view = ReceiptView(item: item, toastManager: measuringQueue).environment(\.dynamicTypeSize, size)
        let height = UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        if measuredHeights.count >= 64 { measuredHeights.removeAll() }
        measuredHeights[key] = height
        return height
    }

    private struct MeasureKey: Hashable {
        let text: String
        let actionLabel: String?
        let tone: MessageTone
        let size: DynamicTypeSize
        let width: CGFloat
    }

    private static var measuredHeights: [MeasureKey: CGFloat] = [:]
    /// The queue the measuring copy holds; it is never posted to, and the
    /// copy is laid out, never shown, so its action never runs.
    private static let measuringQueue = ToastQueueManager()
}

/// The standard receipt's width: it hugs its words, at least 120 points and
/// at most 360 (the margin each side keeps it within the container less 32).
private struct HugsItsWords: ViewModifier {
    func body(content: Content) -> some View {
        HuggingWidth(minimum: ReceiptView.Metrics.minimumWidth, maximum: ReceiptView.Metrics.maximumWidth) {
            content
        }
    }
}

private struct HuggingWidth: Layout {
    let minimum: CGFloat
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let cap = min(proposal.width ?? maximum, maximum)
        let size = child.sizeThatFits(ProposedViewSize(width: cap, height: proposal.height))
        return CGSize(width: max(size.width, minimum), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
