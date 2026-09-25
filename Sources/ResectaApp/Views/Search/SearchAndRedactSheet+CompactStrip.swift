import SwiftUI

// The compact detent's WHOLE composition — split from
// `SearchAndRedactSheet.swift` under the M-6 hub cap (the `+CompactApply`
// pattern). Internal, not private: the hub's `body` mounts the strip at
// the compact float. The cluster builder and its gate stay on the hub —
// the medium+ search bar mounts the same builder, and the ids ride it.
//
// The strip is a taller handle (`CompactFloatDetent`, hug 108 / 120 at
// accessibility sizes): the walk's match line — kind · page · text
// (`SearchState.walkLine`) — over one row of full-size controls: the
// per-item Apply capsule and the ‹ › pair with its counter. The page bar
// steps aside beneath it while the walk is live, so the line's page
// readout is the one page orientation on screen. The line's slot is
// reserved in every state so the layout never jumps between results /
// no results / a pending review; with no walk the row carries the
// interface title alone. Every id the detent-layout pins read is kept
// (`compactFloatStrip`, `applyCurrentResultButton`, `resultNavPrevious`,
// `resultNavNext`); the line adds `walkMatchLine`.
//
// The composition is the "Stacked" one of the two finalists the on-sim
// variant study put to the pick (2026-09-24): the line over the row —
// Apply leading, the cluster trailing — so every existing id and tap
// habit carries over. The alternate ("Centred": an info row over ▲ · a
// wide centred Apply · ▼) was built, shot and not taken.

/// Where the ‹ › cluster is mounted. The medium+ search bar keeps its
/// pinned geometry (Ø44 circles in 46-pt frames, pair spacing 6, a
/// caption counter always shown — `UIFixChromeUITests` measures it); the
/// parked strip draws full-size controls (the circle fills the 46-pt
/// frame, a 20-pt glyph, pair spacing `Spacing.sm`, a subheadline
/// counter that hides from XXXL up).
enum ResultNavSite {
    case searchBar
    case parked

    var diameter: CGFloat {
        self == .parked ? CircularIconButtonStyle.parkedDiameter : CircularIconButtonStyle.diameter
    }
    var glyphPointSize: CGFloat {
        self == .parked ? CircularIconButtonStyle.parkedGlyphPointSize : CircularIconButtonStyle.glyphPointSize
    }
    var pairSpacing: CGFloat {
        self == .parked ? ResectaTokens.Spacing.sm : 6
    }
    var counterFont: Font {
        self == .parked ? .subheadline : .caption
    }
}

extension SearchAndRedactSheet {

    /// The match line over the row — Apply leading, the cluster (‹ › +
    /// counter) trailing; the title centred in the row only while no
    /// walk is live (it would collide with the full-size cluster from
    /// xLarge). At accessibility sizes the row is a plain HStack.
    /// Identifier kept for the detent-layout pins; `children: .contain`
    /// keeps the inner ids.
    var compactFloatStrip: some View {
        VStack(spacing: ResectaTokens.Spacing.xs) {
            walkMatchLine
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ResectaTokens.Spacing.md)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: ResectaTokens.Spacing.sm) {
                        if showsResultNavCluster {
                            applyCurrentResultButton()
                                .padding(.leading, ResectaTokens.Spacing.md)
                            Spacer(minLength: 0)
                            resultNavCluster(site: .parked)
                                .padding(.trailing, ResectaTokens.Spacing.md)
                        } else {
                            Spacer(minLength: 0)
                            compactStripTitle
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    ZStack {
                        if showsResultNavCluster {
                            applyCurrentResultButton()
                                .padding(.leading, ResectaTokens.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            resultNavCluster(site: .parked)
                                .padding(.trailing, ResectaTokens.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            compactStripTitle
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
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

    // MARK: - The match line

    /// The strip's second line (`SearchState.walkLine`): the current
    /// match's kind · "Page k of N" · text, the text under
    /// `.privacySensitive()` (the app-switcher snapshot; the list rows
    /// and the toasts already expose it) and the first thing dropped
    /// at large sizes; the page readout `monospacedDigit` with a numeric
    /// transition and never truncated; the separator is the page bar's
    /// dot. "Hidden by filters" for a current the active filters hide;
    /// the list's own headline with no walk; nothing in the pre-search
    /// contexts and under a pending review. One AX element, one id.
    @ViewBuilder
    var walkMatchLine: some View {
        let line = searchState.walkLine(
            pageCount: documentState.pageCount,
            reviewPending: redactionState.pendingTriage != nil)
        Group {
            switch line {
            case .match(let summary):
                HStack(spacing: ResectaTokens.Spacing.xs) {
                    Text(summary.kind)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    walkLineDot
                    Text(summary.pageLabel)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .contentTransition(.numericText())
                    if let text = summary.text {
                        walkLineDot
                        Text(text)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .privacySensitive()
                    }
                }
                .accessibilityElement(children: .combine)
            case .hiddenByFilters:
                Text(WalkLine.hiddenByFiltersText)
                    .font(.subheadline)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .lineLimit(1)
            case .status(let headline):
                Text(headline)
                    .font(.subheadline)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .lineLimit(1)
            case .empty:
                Color.clear
            }
        }
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize
               ? CompactFloatDetent.accessibilityMatchLineHeight
               : CompactFloatDetent.matchLineHeight)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityIdentifier("walkMatchLine")
    }

    /// The page bar's dot, reused as the line's separator.
    private var walkLineDot: some View {
        Text("\u{B7}")
            .foregroundStyle(.quaternary)
            .padding(.horizontal, ResectaTokens.Spacing.xxs)
    }
}
