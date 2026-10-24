import SwiftUI

// The developer's note, shown once after the agreement is accepted. The
// gate's chrome (`EULAGateView`): the mark, a header, the text scrolling
// under a pinned bottom button, the grouped background and Home's column
// cap. Continue records the note as seen (`FirstLaunchFlow.noteSeenKey`)
// and the root swaps in the app.

struct DeveloperNoteView: View {
    @AppStorage(FirstLaunchFlow.noteSeenKey) private var noteSeen = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The scroll view's visible height; the column takes it as a minimum
    /// height so it centres when it fits and scrolls when it does not.
    @State private var viewportHeight: CGFloat = 0

    static let title = "Why I Made Resecta"

    /// One string per paragraph. The address is plain text, not a link: the
    /// note adds no hand-off of its own (Settings keeps Send Feedback).
    static let paragraphs: [String] = [
        "Hi, I\u{2019}m Jesse. Thank you for trying Resecta.",
        "I build and maintain Resecta on my own. There is no company behind it and no team, and every decision in it is mine.",
        "The paperwork that matters most, like a tax form, a lease or a letter from an insurer, carries numbers that tie it to you. Before a copy goes anywhere, those should come off. And redacted has to mean removed: a black box drawn over a PDF can leave the text underneath readable.",
        "On the Mac, Preview can redact. On iPhone and iPad, as far as I can tell, there is still no built-in way to, so I set out to build one: on your device, free, and open to inspection.",
        "Resecta is designed to remove the text in the regions you mark, then it checks the finished file before you share it. It makes no network requests of its own, and there is no account, no ads and no analytics. It is free because a step that costs money gets skipped. The code is open source, so you can check all of this instead of taking my word for it.",
        "It suggests; you decide. Detection can miss things, so the last look is always yours.",
        "If something looks wrong, or you have an idea, write to me at jesse@resecta.app.",
    ]

    static let signature = "\u{2014} Jesse"
    static let signatureName = "Jesse"
    static let continueLabel = "Continue"

    // Mirrors HomeView's `columnMaxWidth`.
    private var columnMaxWidth: CGFloat {
        horizontalSizeClass == .regular
            ? ResectaTokens.BrandedSurface.panelMaxWidthRegular
            : ResectaTokens.BrandedSurface.panelMaxWidthCompact
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ResectaTokens.Spacing.md) {
                // The app's icon tile, as the gate draws it; hidden at the
                // accessibility sizes, as there.
                if !dynamicTypeSize.isAccessibilitySize {
                    HomeMark(size: ResectaTokens.HomeEntry.markTile)
                        .padding(.bottom, ResectaTokens.Spacing.xs)
                }

                Text(verbatim: Self.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
                    ForEach(Self.paragraphs, id: \.self) { paragraph in
                        Text(verbatim: paragraph)
                    }
                    Text(verbatim: Self.signature)
                        .accessibilityLabel(Text(verbatim: Self.signatureName))
                }
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("developerNoteBody")
            }
            .frame(maxWidth: columnMaxWidth)   // cap content column (mirrors Home)
            .padding(.horizontal, ResectaTokens.Spacing.md)
            .padding(.vertical, ResectaTokens.HomeEntry.verticalPad)
            // Fill the viewport so the capped column centres both
            // horizontally and vertically; content taller than the
            // viewport scrolls instead (minHeight, not height).
            .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .center)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // containerSize is already inset by the status bar and the button's bar.
            geometry.containerSize.height
        } action: { _, height in
            viewportHeight = max(0, height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        // Continue pinned beneath the scrolling text as a bottom bar, in the
        // gate's filled brand capsule.
        .safeAreaBar(edge: .bottom) {
            Button {
                noteSeen = true
            } label: {
                Text(verbatim: Self.continueLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(ResectaTokens.BrandTeal.fill)
            .frame(maxWidth: columnMaxWidth)
            .padding(.horizontal, ResectaTokens.Spacing.md)
            .padding(.vertical, ResectaTokens.Spacing.md)
            .accessibilityIdentifier("developerNoteContinue")
        }
        // Opaque, as the gate: the grouped background Home sits on.
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}
