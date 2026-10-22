import SwiftUI

// First-launch clickwrap. Verbatim legal text — do NOT modify.
// A root view swap (the app's window shows this view until the terms are
// accepted), opaque background, no glass interference.
// ScrollView wrapper for Dynamic Type accessibility (AX5); I Agree stays
// pinned beneath the scrolling text.
// Legal text referenced from Legal.xcstrings catalog.

struct EULAGateView: View {
    // Versioned key — increment to _v2 to force re-acceptance on terms change.
    @AppStorage("disclaimerAccepted_v1") private var disclaimerAccepted = false

    // EULA acceptance-key history. The CURRENT key is
    // "disclaimerAccepted_v1" (above). When the terms change and the key is
    // bumped (e.g. to _v2), move the now-superseded key name into this list so
    // accepting the new terms clears the orphaned UserDefaults entry. _v1 is the
    // first shipped key, so this list is empty today (no _v0 ever existed).
    private static let supersededDisclaimerKeys: [String] = []

    // Mirror HomeView's content-column cap so the gate and the screen it
    // precedes share the same width on regular-width layouts.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Which bundled legal document is open read-only over the
    // gate, if any. Viewing is presentation-only — nothing here touches
    // `disclaimerAccepted`, and dismissing the sheet lands back on the
    // still-blocking gate.
    @State private var presentedDocument: LegalDocument?

    /// The scroll view's visible height; the column takes it as a minimum
    /// height so it centres when it fits and scrolls when it does not.
    @State private var viewportHeight: CGFloat = 0

    // Mirrors HomeView's `columnMaxWidth`.
    private var columnMaxWidth: CGFloat {
        horizontalSizeClass == .regular
            ? ResectaTokens.BrandedSurface.panelMaxWidthRegular
            : ResectaTokens.BrandedSurface.panelMaxWidthCompact
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ResectaTokens.Spacing.md) {
                // The app's mark, as the home screen draws it; hidden at
                // the accessibility sizes, as there.
                if !dynamicTypeSize.isAccessibilitySize {
                    HomeMark(height: ResectaTokens.HomeEntry.markHeight)
                        .padding(.bottom, ResectaTokens.Spacing.xs)
                }

                // Legal string catalog reference
                Text("eula_title", tableName: "Legal")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                // Verbatim clickwrap text (do NOT modify).
                // Referenced from Legal.xcstrings.
                Text("eula_body", tableName: "Legal")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // View-only access to the documents the
                // body asks agreement to, readable from the gate
                // itself. Plain borderless buttons — link
                // affordance without competing with "I Agree".
                VStack(spacing: ResectaTokens.Spacing.sm) {
                    Button(String(localized: "eula_view_eula", table: "Legal")) {
                        presentedDocument = .eula
                    }
                    .accessibilityIdentifier("eulaViewEULA")

                    Button(String(localized: "eula_view_privacy", table: "Legal")) {
                        presentedDocument = .privacyPolicy
                    }
                    .accessibilityIdentifier("eulaViewPrivacy")

                    Button(String(localized: "eula_view_acknowledgements", table: "Legal")) {
                        presentedDocument = .acknowledgements
                    }
                    .accessibilityIdentifier("eulaViewAcknowledgements")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ResectaTokens.BrandTeal.text)
                .padding(.top, ResectaTokens.Spacing.sm)
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
            // containerSize is already inset by the status bar and the I Agree inset.
            geometry.containerSize.height
        } action: { _, height in
            viewportHeight = max(0, height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        // "I Agree" pinned beneath the scrolling text as a bottom bar: the
        // text scrolls under it and fades at the soft scroll edge (a bar
        // gets the edge effect; a plain inset does not). The filled brand
        // tier (the home screen's primary tile), so the capsule reads the
        // same in both themes.
        .safeAreaBar(edge: .bottom) {
            Button {
                disclaimerAccepted = true
                // Drop any superseded EULA keys so a key bump does not
                // orphan stale acceptance flags in UserDefaults.
                for key in Self.supersededDisclaimerKeys {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            } label: {
                Text(String(localized: "eula_agree", table: "Legal"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(ResectaTokens.BrandTeal.fill)
            .frame(maxWidth: columnMaxWidth)
            .padding(.horizontal, ResectaTokens.Spacing.md)
            .padding(.vertical, ResectaTokens.Spacing.md)
            .accessibilityIdentifier("eulaAccept")
        }
        // Read-only document sheet OVER the gate. `.sheet(item:)`
        // so each document presents its own copy; dismissal clears the item
        // and the un-accepted gate is what remains underneath.
        .sheet(item: $presentedDocument) { document in
            LegalDocumentView(document: document)
        }
        // Opaque background (systemGroupedBackground is opaque) — keeps
        // legal text readable and matches the home screen's backdrop the
        // gate gives way to. `.ignoresSafeArea()` lets the color fill
        // edge-to-edge while content stays within the safe area.
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}
