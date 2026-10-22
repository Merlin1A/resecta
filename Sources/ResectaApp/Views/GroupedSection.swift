import SwiftUI

// One inset-grouped section of the results page: an optional header (its
// count included), the rows on the secondary grouped background inside a
// rounded container, and an optional footer. The page stays a hand-built
// `ScrollView` + `VStack`, not a `List`: the results' scroll view keeps its
// identifier, the masthead is not a row, and the hairlines sit exactly
// where the rows put them.

struct GroupedSection<Content: View>: View {
    /// The drawn header ("Findings · 3"); nil for a headerless section.
    var header: String? = nil
    /// The header's spoken form ("Findings, 3."); the drawn text otherwise.
    var spokenHeader: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Results.headerGap) {
            if let header {
                Text(header)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .padding(.horizontal, ResectaTokens.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(spokenHeader ?? header)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: ResectaTokens.CornerRadius.groupedSection, style: .circular))
        }
    }
}

/// The hairline between two rows of a section, inset to the row titles.
struct GroupedRowDivider: View {
    var inset: CGFloat = ResectaTokens.Results.titleInset

    var body: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: ResectaTokens.Border.subtle)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}
