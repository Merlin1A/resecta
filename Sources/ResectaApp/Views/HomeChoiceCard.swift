import SwiftUI

/// Full-card-tappable choice tile used on the home screen.
///
/// The entire card is the hit target — the trailing "affordance" line
/// (e.g. "Choose File →") is decorative; the wrapping `Button` is what
/// receives taps. VoiceOver reads the title + body as one combined
/// element via `.accessibilityElement(children: .combine)`.
///
/// Two visual styles share the same outer chrome (regular-material
/// background, `CornerRadius.card`, `Shadow.subtle`); only the
/// 56×56 leading icon tile differs:
///   * `.primary` — filled `BrandTeal.tint` tile, white glyph.
///   * `.subtle`  — tinted `BrandTeal.tint` tile, accent glyph.
struct HomeChoiceCard: View {

    enum Style {
        /// Filled accent tile, white glyph. Visually leads despite being a
        /// peer card — used for the "Open a Document" path on the home screen.
        case primary
        /// Tinted accent tile, accent glyph. Used for secondary affordances
        /// (e.g. the bundled-sample path).
        case subtle
    }

    let symbol: String
    let style: Style
    let title: LocalizedStringKey
    let bodyText: LocalizedStringKey
    let affordance: LocalizedStringKey
    /// When non-nil, replaces the default `BrandTeal.tint` in the leading
    /// 56pt symbol tile. Phase 2 of the verification/export redesign adds this
    /// so the FAIL-pre-override Share card can paint its tile red without
    /// forking `Style`. Default-nil keeps every existing call site unchanged.
    let tintOverride: Color?
    let action: () -> Void

    init(
        symbol: String,
        style: Style,
        title: LocalizedStringKey,
        bodyText: LocalizedStringKey,
        affordance: LocalizedStringKey,
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

/// The visual chrome of a choice card — a leading 56pt icon tile plus the
/// title / body / affordance stack — with **no control of its own**.
///
/// Extracted from `HomeChoiceCard` so a card's appearance can be hosted by
/// whatever single activatable control a surface needs: the `Button` inside
/// the `HomeChoiceCard` convenience wrapper, or a `NavigationLink` (e.g. the
/// "Preview Redacted Document" card on `VerificationResultsView`). SwiftUI
/// does not support an activatable control whose label is *itself* a
/// `Button`; the earlier "card nested inside a Button/NavigationLink with
/// `.allowsHitTesting(false)`" structure left the outer control with a dead
/// tap target. Keeping the chrome control-free lets each card carry exactly
/// one control.
///
/// VoiceOver reads the title + body as one combined element via
/// `.accessibilityElement(children: .combine)` here, so the hosting control
/// surfaces as a single button/link (the host may override the spoken label
/// with its own `.accessibilityLabel`).
struct HomeChoiceCardContent: View {
    let symbol: String
    let style: HomeChoiceCard.Style
    let title: LocalizedStringKey
    let bodyText: LocalizedStringKey
    let affordance: LocalizedStringKey
    /// See `HomeChoiceCard.tintOverride` — when non-nil, repaints the leading
    /// 56pt tile (the FAIL-pre-override Share card paints it red).
    let tintOverride: Color?

    init(
        symbol: String,
        style: HomeChoiceCard.Style,
        title: LocalizedStringKey,
        bodyText: LocalizedStringKey,
        affordance: LocalizedStringKey,
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

    private var tileTint: Color {
        tintOverride ?? ResectaTokens.BrandTeal.tint
    }

    private var tileBackground: Color {
        switch style {
        case .primary:
            return tileTint
        case .subtle:
            return tileTint
                .opacity(colorScheme == .dark ? 0.18 : 0.10)
        }
    }

    private var tileForeground: Color {
        switch style {
        case .primary: return .white
        case .subtle:  return tileTint
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: ResectaTokens.Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(tileForeground)
                .frame(width: 56, height: 56)
                .background(
                    tileBackground,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(bodyText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(affordance)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ResectaTokens.BrandTeal.text)
                    .padding(.top, ResectaTokens.Spacing.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ResectaTokens.Spacing.md)
        .accessibilityElement(children: .combine)
    }
}

/// Internal (not `private`) so the verification-results Share / Preview
/// cards can host `HomeChoiceCardContent` in their own `Button` /
/// `NavigationLink` and still get the card's material chrome, shadow, and
/// press-state scale/opacity animation. Reuse keeps a single source of
/// truth for the card's pressed appearance.
struct HomeChoiceCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                .regularMaterial,
                in: RoundedRectangle(
                    cornerRadius: ResectaTokens.CornerRadius.card,
                    style: .continuous
                )
            )
            .shadow(
                color: ResectaTokens.Shadow.subtle.color,
                radius: ResectaTokens.Shadow.subtle.radius,
                x: ResectaTokens.Shadow.subtle.x,
                y: ResectaTokens.Shadow.subtle.y
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(ResectaTokens.Anim.stateChange, value: configuration.isPressed)
    }
}

/// Single check-glyph + label item used by the home-screen trust strip
/// (e.g. "✓ On-device"). Co-located with `HomeChoiceCard` so Session 2's
/// `HomeView` rewrite doesn't need a second new file.
struct TrustItem: View {
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(ResectaTokens.BrandTeal.text)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
