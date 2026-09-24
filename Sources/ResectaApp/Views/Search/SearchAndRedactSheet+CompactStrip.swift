import SwiftUI

// The compact detent's WHOLE composition — split from
// `SearchAndRedactSheet.swift` under the M-6 hub cap (the `+CompactApply`
// pattern). Internal, not private: the hub's `body` mounts the strip at
// the compact float. The cluster builder and its gate stay on the hub —
// the medium+ search bar mounts the same builder, and the ids ride it.

extension SearchAndRedactSheet {

    // MARK: - compactFloat Strip

    /// The compact detent's WHOLE composition: one row — per-item Apply
    /// leading, centred interface title, result-nav cluster (‹ › + k/N)
    /// trailing. Compact is a glanceable handle — title + cluster +
    /// per-item Apply; every OTHER control lives at medium+; the canvas
    /// owns interaction below the sheet. The cluster is the medium+
    /// search bar's builder (`resultNavCluster`; never co-mounted, ids
    /// unique); cluster and Apply render only with results and no
    /// review pending (`showsResultNavCluster`). The counter hides from
    /// XXXL up; at accessibility sizes the row is a plain HStack
    /// (Apply · title · chevrons) so the headline never collides.
    /// Identifier kept for the detent-layout pins; `children: .contain`
    /// keeps the inner ids. The Apply's contract: `+CompactApply.swift`.
    var compactFloatStrip: some View {
        VStack(spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: ResectaTokens.Spacing.sm) {
                        if showsResultNavCluster {
                            applyCurrentResultButton
                        }
                        Spacer(minLength: 0)
                        compactStripTitle
                        Spacer(minLength: 0)
                        if showsResultNavCluster {
                            resultNavCluster(hidesCounterAtLargeTypeSizes: true)
                                .padding(.trailing, ResectaTokens.Spacing.md)
                        }
                    }
                } else {
                    // Overlays: title centred full-width, Apply leading, cluster trailing.
                    ZStack {
                        compactStripTitle
                            .frame(maxWidth: .infinity)
                        if showsResultNavCluster {
                            applyCurrentResultButton
                                .frame(maxWidth: .infinity, alignment: .leading)
                            resultNavCluster(hidesCounterAtLargeTypeSizes: true)
                                .padding(.trailing, ResectaTokens.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
            // The row is always the 46-pt layout height of its controls
            // so the title sits on the same line whether or not the
            // cluster and the Apply render (no jump between results /
            // no results / review; measured on-sim).
            .frame(minHeight: ResectaTokens.TouchTarget.minimum)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compactFloatStrip")
    }

    /// The compact handle's title — the centred headline, unchanged.
    var compactStripTitle: some View {
        Text(searchState.searchModeType.interface.displayName)
            .font(.headline)
            .lineLimit(1)
    }
}
