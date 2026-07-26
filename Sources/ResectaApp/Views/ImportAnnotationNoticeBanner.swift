import SwiftUI
import RedactionEngine

// Import-time notice for source annotations. The on-screen PDFKit view
// draws a document's annotations; the export raster is built from the
// page content stream, which does not include them. When the imported
// source carries a non-Widget annotation whose subtype can sit over
// page content, this banner names that mechanism so the user can check
// the preview before sharing.
//
// A sibling of `InlineWarningBanner` rather than a reuse: the mechanism
// copy is a full paragraph, and the shared banner's 2-line cap (3 at
// AX5) would truncate it. Same visual grammar — warning triangle,
// tinted card, icon-only dismiss.
//
// Copy is mechanism-description only (I6 / ARCH §1.3): it states what
// the app builds and what the export contains, never an outcome promise.

struct ImportAnnotationNoticeBanner: View {
    let onDismiss: () -> Void

    /// Mechanism copy, exposed for the unit pin. One static string —
    /// the banner does not enumerate annotation subtypes; the count and
    /// kinds do not change what the user should do (check the preview).
    static let noticeMessage = "This document contains annotations such as boxes, stamps, or notes. Annotations are not part of the page image, so the exported file is built without them, and page content beneath them is included in the export. Check the preview before sharing."

    /// Finding ids for annotation subtypes that draw nothing over page
    /// content, so their presence says nothing about what the export
    /// contains. A deny-list, not an allow-list: an unlisted subtype
    /// keeps firing (the posture fails toward warning — `Text` notes and
    /// `Highlight` can sit over page content, so they stay in).
    /// `AnnotationAnalyzer` ids are "annotation-<subtype.lowercased()>".
    static let nonConcealingFindingIDs: Set<String> = ["annotation-link", "annotation-popup"]

    /// The banner owns this policy; `DocumentState.sourceAnnotationFindings`
    /// stays the faithful record of everything the analyzer saw.
    static func noticeWorthyCount(_ findings: [PDFFinding]) -> Int {
        findings.filter { !nonConcealingFindingIDs.contains($0.id) }.count
    }

    /// Visibility contract, exposed as a static so unit tests can pin
    /// it without rendering the view: the notice shows while editing a
    /// document whose source carries annotations, until the user
    /// dismisses it, and yields to the two sibling top-edge banners
    /// (background-resume and detection-summary) rather than stacking
    /// over them — it returns once they clear because dismissal is the
    /// only terminal state.
    static func isVisible(
        phaseKind: DocumentState.PhaseKind,
        annotationTypeCount: Int,
        dismissed: Bool,
        pausedBannerActive: Bool,
        detectionBannerActive: Bool
    ) -> Bool {
        phaseKind == .editing
            && annotationTypeCount > 0
            && !dismissed
            && !pausedBannerActive
            && !detectionBannerActive
    }

    var body: some View {
        HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(Self.noticeMessage)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("Dismiss", systemImage: "xmark.circle.fill") {
                onDismiss()
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
        }
        .padding(ResectaTokens.Spacing.sm)
        // Chained backgrounds stack behind what precedes them: the tint
        // stays on top of an opaque base so the document under the
        // banner cannot show through the card and overprint the copy.
        .background(ResectaTokens.SemanticColor.warningTint.opacity(0.12),
                    in: .rect(cornerRadius: ResectaTokens.CornerRadius.medium))
        .background(Color(.systemBackground),
                    in: .rect(cornerRadius: ResectaTokens.CornerRadius.medium))
        .padding(.horizontal, ResectaTokens.Spacing.md)
        // Container id + header trait mirror `InlineWarningBanner`; the
        // dismiss Button stays its own accessibility element so it is
        // individually hittable.
        .accessibilityIdentifier("importAnnotationNotice")
        .accessibilityAddTraits(.isHeader) // §A8: VoiceOver announces on appearance
    }
}
