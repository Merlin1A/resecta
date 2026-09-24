import SwiftUI

/// The one disclosure chevron: `chevron.right`, turning to point down when
/// its content is open. Used by the Verification Details header, every
/// expandable layer row and the Page Modes header, so the three
/// disclosures on the results screen share one glyph, one weight and one
/// motion. The caller's `withAnimation(Anim.stateChange)` drives the turn;
/// a rotation is not spatial travel, so it stays under Reduce Motion.
/// Hidden from VoiceOver — the disclosure's label and hint carry the state.
struct DisclosureChevron: View {
    let isExpanded: Bool
    var tint: Color = ResectaTokens.SemanticColor.supportText

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
    }
}
