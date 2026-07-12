import SwiftUI
import UIKit

// ARCH §6.1: First-launch clickwrap. Verbatim legal text — do NOT modify (R9).
// UI_UX §6.4: Full-screen cover, opaque background, no glass interference.
// UI_UX §9.3: ScrollView wrapper for Dynamic Type accessibility (AX5).
// ARCH §6.3: Legal text referenced from Legal.xcstrings catalog.

struct EULAGateView: View {
    // C10/D19: Versioned key — increment to _v2 to force re-acceptance on terms change.
    @AppStorage("disclaimerAccepted_v1") private var disclaimerAccepted = false

    // EULA acceptance-key history. The CURRENT key is
    // "disclaimerAccepted_v1" (above). When the terms change and the key is
    // bumped (e.g. to _v2), move the now-superseded key name into this list so
    // accepting the new terms clears the orphaned UserDefaults entry. _v1 is the
    // first shipped key, so this list is empty today (no _v0 ever existed).
    private static let supersededDisclaimerKeys: [String] = []

    // Mirror HomeView's content-column cap so the gate and the screen it
    // precedes share the same width on regular-width (iPad) layouts.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Which bundled legal document is open read-only over the
    // gate, if any. Viewing is presentation-only — nothing here touches
    // `disclaimerAccepted`, and dismissing the sheet lands back on the
    // still-blocking gate.
    @State private var presentedDocument: LegalDocument?

    // KI-3: doc.text.redact SF Symbol availability unverified for iOS 26.
    private var appSymbolName: String {
        UIImage(systemName: "doc.text.redact") != nil
            ? "doc.text.redact" : "doc.viewfinder"
    }

    // Mirrors HomeView.columnMaxWidth (HomeView.swift:82–86).
    private var columnMaxWidth: CGFloat {
        horizontalSizeClass == .regular
            ? ResectaTokens.BrandedSurface.panelMaxWidthRegular
            : ResectaTokens.BrandedSurface.panelMaxWidthCompact
    }

    var body: some View {
        VStack(spacing: ResectaTokens.Spacing.lg) {
            // UI_UX §9.3: ScrollView activates only when content exceeds the
            // available height (e.g., at AX5 Dynamic Type). The minHeight tied
            // to the scroll viewport centers content vertically when it fits and
            // yields to natural scrolling once content grows taller than the gate.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: ResectaTokens.Spacing.md) {
                        // Monochrome masthead-style glyph — matches HomeView's 56pt
                        // `.primary` hero icon (HomeView.swift:90–92); no system tint.
                        Image(systemName: appSymbolName)
                            .font(.system(size: 56))
                            .foregroundStyle(.primary)
                            .accessibilityHidden(true)

                        // ARCH §6.3: Legal string catalog reference
                        Text("eula_title", tableName: "Legal")
                            .font(.title2.weight(.semibold))

                        // ARCH §6.1: Verbatim clickwrap text (R9 — do NOT modify).
                        // ARCH §6.3: Referenced from Legal.xcstrings.
                        Text("eula_body", tableName: "Legal")
                            .font(.body)
                            .multilineTextAlignment(.center)

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
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, ResectaTokens.Spacing.sm)
                    }
                    .frame(maxWidth: columnMaxWidth)   // cap content column (mirrors Home)
                    // Fill the viewport so the capped column centers both
                    // horizontally and vertically; content taller than the
                    // viewport scrolls instead (minHeight, not height).
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    .padding(.horizontal, ResectaTokens.Spacing.md)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            // UI_UX §9.3: "I Agree" button pinned at bottom, outside scroll.
            // Standard `.borderedProminent` (system accent) — kept identical to the
            // app's other primary buttons (e.g. FailedStateView:80–83). Deliberately
            // NOT re-tinted, so every primary action shares one button language.
            Button(String(localized: "eula_agree", table: "Legal")) {
                disclaimerAccepted = true
                // Drop any superseded EULA keys so a key bump does not
                // orphan stale acceptance flags in UserDefaults.
                for key in Self.supersededDisclaimerKeys {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, ResectaTokens.Spacing.md)
            .accessibilityIdentifier("eulaAccept") // §A8
        }
        // Read-only document sheet OVER the gate. `.sheet(item:)`
        // so each document presents its own copy; dismissal clears the item
        // and the un-accepted gate is what remains underneath.
        .sheet(item: $presentedDocument) { document in
            LegalDocumentView(document: document)
        }
        // UI_UX §6.4: opaque background (systemGroupedBackground is opaque) — keeps
        // legal text readable and matches the HomeView backdrop (HomeView.swift:34)
        // the gate gives way to. `.ignoresSafeArea()` lets the color fill edge-to-edge
        // while content stays within the safe area (prevents a top/bottom seam).
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}
