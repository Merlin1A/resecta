import SwiftUI

// The compact detent's WHOLE composition — split from
// `SearchAndRedactSheet.swift` under the M-6 hub cap (the `+CompactApply`
// pattern). Internal, not private: the hub's `body` mounts the strip at
// the compact float. The cluster builder and its gate stay on the hub —
// the medium+ search bar mounts the same builder, and the ids ride it.
//
// The strip is one row of full-size controls under the grabber
// (`CompactFloatDetent`, hug 101): the per-item Apply capsule (Select on
// the review origin) and the ‹ › pair with its counter. The page bar
// steps aside beneath it while either walk is live; the canvas ring and
// the k/N counter are the orientation. With no walk the row carries the
// interface title alone. What the current match IS — kind · page · text
// — is VoiceOver's to read, as the Apply / Select button's value
// (`+CompactApply.swift`); nothing is drawn for it. Every id the
// detent-layout pins read is kept (`compactFloatStrip`,
// `applyCurrentResultButton`, `resultNavPrevious`, `resultNavNext`).
//
// The composition is the "Stacked" one of the two finalists the on-sim
// variant study put to the pick (2026-09-24): a match line over the row
// — Apply leading, the cluster trailing — so every existing id and tap
// habit carries over. The line was retired 2026-09-28 (Jesse: the page
// shows the mark; the line said it twice and looked bad) — the row
// alone remains, at the smallest attached hug.

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

    /// The row — Apply leading, the cluster (‹ › + counter) trailing —
    /// hugging the top under the grabber; the title centred in the row
    /// only while no walk is live (it would collide with the full-size
    /// cluster from xLarge). At accessibility sizes the row is a plain
    /// HStack. Identifier kept for the detent-layout pins;
    /// `children: .contain` keeps the inner ids.
    var compactFloatStrip: some View {
        VStack(spacing: 0) {
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

    // MARK: - The review walk's counter

    /// The k/N counter for the review walk — the search counter's plain
    /// form (the walk covers every staged detection; no filter to
    /// respect) with the same label; nothing before the first step.
    /// Mounted by the hub's `resultNavCounter` while the review owns
    /// the Scan interface.
    @ViewBuilder
    func reviewWalkCounter(site: ResultNavSite) -> some View {
        let walk = liveReviewWalk
        if let index = walk.currentIndex {
            Text("\(index + 1)/\(walk.count)")
                .font(site.counterFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("Result \(index + 1) of \(walk.count)")
        }
    }
}
