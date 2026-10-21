import SwiftUI

/// Full-card-tappable entry used on the home screen.
///
/// The entire card is the hit target: the wrapping `Button` is what
/// receives taps. VoiceOver reads one explicit label — the title, a comma,
/// the body — set on the content inside the button; the hosting screen adds
/// the hint and the identifier at its call site.
///
/// Three visual styles share the same outer chrome (regular-material
/// background, `CornerRadius.card`, `Shadow.subtle`); the leading tile
/// differs:
///   * `.primary` — the filled brand tile (`BrandTeal.fill`), white glyph.
///   * `.subtle`  — the washed tile, the tile glyph colour.
///   * `.row`     — the quieter entry: a smaller washed tile in the same
///     slot, less vertical padding.
/// At accessibility sizes every style restacks: a smaller tile above the
/// text.
struct HomeChoiceCard: View {

    enum Style {
        /// Filled brand tile, white glyph. Visually leads despite being a
        /// peer card — used for the "Open a Document" path on the home screen.
        case primary
        /// Washed tile, tinted glyph. Used for the peer entries.
        case subtle
        /// The quieter entry: a smaller washed tile, less vertical padding.
        case row
    }

    let symbol: String
    let style: Style
    let title: LocalizedStringKey
    let bodyText: LocalizedStringKey
    /// An optional trailing line in the brand text colour. The home screen
    /// passes none (the whole card is the target); hosts that still pass one
    /// keep it until their own copy moves.
    let affordance: LocalizedStringKey?
    /// When non-nil, replaces the tile's brand colour. Hosts that paint the
    /// tile another colour pass it; the home screen never does.
    let tintOverride: Color?
    let action: () -> Void

    init(
        symbol: String,
        style: Style,
        title: LocalizedStringKey,
        bodyText: LocalizedStringKey,
        affordance: LocalizedStringKey? = nil,
        tintOverride: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.style = style
        self.title = title
        self.bodyText = bodyText
        self.affordance = affordance
        self.tintOverride = tintOverride
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HomeChoiceCardContent(
                symbol: symbol,
                style: style,
                title: title,
                bodyText: bodyText,
                affordance: affordance,
                tintOverride: tintOverride
            )
        }
        .buttonStyle(HomeChoiceCardButtonStyle())
    }
}

/// The visual chrome of an entry — the leading tile plus the title and body —
/// with **no control of its own**.
///
/// Extracted from `HomeChoiceCard` so a card's appearance can be hosted by
/// whatever single activatable control a surface needs: the `Button` inside
/// the `HomeChoiceCard` convenience wrapper, or a `NavigationLink`. SwiftUI
/// does not support an activatable control whose label is *itself* a
/// `Button`; keeping the chrome control-free lets each card carry exactly
/// one control.
///
/// VoiceOver reads one explicit label here — the title, a comma, the body —
/// so the hosting control surfaces as a single button or link (a host may
/// still override the spoken label with its own `.accessibilityLabel`).
struct HomeChoiceCardContent: View {
    let symbol: String
    let style: HomeChoiceCard.Style
    let title: LocalizedStringKey
    let bodyText: LocalizedStringKey
    let affordance: LocalizedStringKey?
    /// See `HomeChoiceCard.tintOverride`.
    let tintOverride: Color?

    init(
        symbol: String,
        style: HomeChoiceCard.Style,
        title: LocalizedStringKey,
        bodyText: LocalizedStringKey,
        affordance: LocalizedStringKey? = nil,
        tintOverride: Color? = nil
    ) {
        self.symbol = symbol
        self.style = style
        self.title = title
        self.bodyText = bodyText
        self.affordance = affordance
        self.tintOverride = tintOverride
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The tile's fill for a style: the filled brand tier for `.primary`, the
    /// brand wash for the others; an override repaints both.
    static func tileFill(style: HomeChoiceCard.Style, tintOverride: Color? = nil, dark: Bool = false) -> Color {
        let base = tintOverride ?? ResectaTokens.BrandTeal.fill
        switch style {
        case .primary:
            return base
        case .subtle, .row:
            let wash = tintOverride ?? ResectaTokens.BrandTeal.tint
            return wash.opacity(dark ? ResectaTokens.Opacity.tileWashDark : ResectaTokens.Opacity.tileWashLight)
        }
    }

    private var tileBackground: Color {
        Self.tileFill(style: style, tintOverride: tintOverride, dark: colorScheme == .dark)
    }

    private var tileForeground: Color {
        switch style {
        case .primary: return .white
        case .subtle, .row: return tintOverride ?? ResectaTokens.BrandTeal.tileGlyph
        }
    }

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    /// The tile's side, radius and glyph size for the style and type size.
    private var tileMetrics: (side: CGFloat, radius: CGFloat, glyph: CGFloat) {
        if isAccessibilitySize {
            return (ResectaTokens.HomeEntry.tileAX, ResectaTokens.HomeEntry.tileRadiusAX, ResectaTokens.HomeEntry.tileGlyphAX)
        }
        switch style {
        case .primary, .subtle:
            return (ResectaTokens.HomeEntry.tile, ResectaTokens.HomeEntry.tileRadius, ResectaTokens.HomeEntry.tileGlyph)
        case .row:
            return (ResectaTokens.HomeEntry.rowTile, ResectaTokens.HomeEntry.rowTileRadius, ResectaTokens.HomeEntry.rowGlyph)
        }
    }

    private var tile: some View {
        let metrics = tileMetrics
        return Image(systemName: symbol)
            .font(.system(size: metrics.glyph, weight: .semibold))
            .foregroundStyle(tileForeground)
            .frame(width: metrics.side, height: metrics.side)
            .background(
                tileBackground,
                in: RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    /// The tile in the slot every entry shares, so the text starts on one edge.
    private var slottedTile: some View {
        tile.frame(width: ResectaTokens.HomeEntry.slot)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(bodyText)
                .font(.subheadline)
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let affordance {
                Text(affordance)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ResectaTokens.BrandTeal.text)
                    .padding(.top, ResectaTokens.Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        Group {
            if isAccessibilitySize {
                // Every entry restacks: the smaller tile above the text.
                VStack(alignment: .leading, spacing: ResectaTokens.HomeEntry.gap) {
                    tile
                    text
                }
                .padding(ResectaTokens.Spacing.md)
            } else if style == .row {
                // The tile is centred on the text while the caption is one
                // line; top-aligned with the title once it wraps.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: ResectaTokens.Spacing.md) {
                        slottedTile
                        text.fixedSize(horizontal: true, vertical: false)
                    }
                    HStack(alignment: .top, spacing: ResectaTokens.Spacing.md) {
                        slottedTile
                        text
                    }
                }
                .padding(.vertical, ResectaTokens.HomeEntry.rowPadV)
                .padding(.horizontal, ResectaTokens.Spacing.md)
            } else {
                HStack(alignment: .top, spacing: ResectaTokens.Spacing.md) {
                    slottedTile
                    text
                }
                .padding(ResectaTokens.Spacing.md)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title) + Text(", ") + Text(bodyText))
    }
}

/// Internal (not `private`) so other screens can host `HomeChoiceCardContent`
/// in their own `Button` / `NavigationLink` and still get the card's
/// material chrome, shadow and press look. Reuse keeps a single source of
/// truth for the card's pressed appearance.
struct HomeChoiceCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The press: a slight shrink and fade; under Reduce Motion a primary
    /// shade over the card instead; at rest nothing.
    static func pressLook(isPressed: Bool, reduceMotion: Bool) -> (scale: CGFloat, opacity: Double, overlay: Double) {
        guard isPressed else { return (1, 1, 0) }
        if reduceMotion { return (1, 1, ResectaTokens.Opacity.pressOverlay) }
        return (ResectaTokens.HomeEntry.pressScale, ResectaTokens.HomeEntry.pressOpacity, 0)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.card, style: .continuous)
    }

    private var surface: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(Color(.secondarySystemGroupedBackground))
            : AnyShapeStyle(.regularMaterial)
    }

    func makeBody(configuration: Configuration) -> some View {
        let look = Self.pressLook(isPressed: configuration.isPressed, reduceMotion: reduceMotion)
        return configuration.label
            .background(surface, in: cardShape)
            .overlay(Color.primary.opacity(look.overlay), in: cardShape)
            .shadow(
                color: ResectaTokens.Shadow.subtle.color,
                radius: ResectaTokens.Shadow.subtle.radius,
                x: ResectaTokens.Shadow.subtle.x,
                y: ResectaTokens.Shadow.subtle.y
            )
            .scaleEffect(look.scale)
            .opacity(look.opacity)
            .animation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.stateChange, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}

/// The three trust words as one line — `On-device · No tracking · Open
/// source` — in the support text colour, the separators too; when the line
/// does not fit, the words stack with no separator. One spoken element.
/// Shared by the home screen and the verification progress screen.
struct TrustLine: View {
    static let words = ["On-device", "No tracking", "Open source"]
    /// What VoiceOver reads: the words, comma-separated, no glyph.
    static let spokenLabel = "On-device, No tracking, Open source"

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ResectaTokens.Spacing.xs) {
                ForEach(Array(Self.words.enumerated()), id: \.offset) { index, word in
                    if index > 0 {
                        Text("·")
                    }
                    Text(word)
                }
            }
            VStack(spacing: ResectaTokens.Spacing.xxs) {
                ForEach(Self.words, id: \.self) { word in
                    Text(word)
                }
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel)
    }
}

/// Single check-glyph + label item: the trust strip the verification
/// results screen still draws. Co-located with `HomeChoiceCard`.
struct TrustItem: View {
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(ResectaTokens.BrandTeal.text)
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
        }
    }
}
