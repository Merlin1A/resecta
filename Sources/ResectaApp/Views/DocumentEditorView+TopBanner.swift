import SwiftUI
import RedactionEngine

// The editor's one top-banner slot. Two notices share the top edge of
// the canvas: the paused notice (a run left unfinished when the app went
// to the background) and the import annotation notice. The hub's body
// mounts this one slot; it shows one notice at a time, paused first, and
// a notice that is not shown waits its turn (each one ends only when it
// is dismissed or replaced).

enum TopBannerSlot: Equatable {
    case paused
    case annotation

    /// The precedence: paused beats the annotation notice.
    static func winner(paused: Bool, annotation: Bool) -> TopBannerSlot? {
        if paused { return .paused }
        if annotation { return .annotation }
        return nil
    }

    /// The editor's read of the two notices: the paused notice shows only
    /// while editing; the annotation notice's own visibility
    /// (`ImportAnnotationNoticeBanner.isVisible`) says when it is owed.
    static func winner(documentState: DocumentState) -> TopBannerSlot? {
        let editing = documentState.phaseKind == .editing
        return winner(
            paused: editing && documentState.wasPausedByBackground,
            annotation: ImportAnnotationNoticeBanner.isVisible(
                phaseKind: documentState.phaseKind,
                annotationTypeCount: ImportAnnotationNoticeBanner.noticeWorthyCount(
                    documentState.sourceAnnotationFindings),
                filledFormFieldCount: documentState.sourceFilledFormFieldCount,
                dismissed: documentState.annotationNoticeDismissed
            )
        )
    }
}

extension DocumentEditorView {

    // MARK: - Top-banner slot

    /// The slot's content: the winning notice, or nothing.
    @ViewBuilder
    var topBannerSlot: some View {
        switch TopBannerSlot.winner(documentState: documentState) {
        case .paused?:
            resumeBannerOverlay
        case .annotation?:
            annotationNoticeBanner
        case nil:
            EmptyView()
        }
    }

    /// The import annotation notice: the imported source carries
    /// annotations or filled form fields, which the on-screen view draws
    /// but the export raster (built from the page content stream) does not
    /// include. It stays until the user dismisses it.
    private var annotationNoticeBanner: some View {
        ImportAnnotationNoticeBanner(
            annotationCount: ImportAnnotationNoticeBanner.noticeWorthyCount(
                documentState.sourceAnnotationFindings),
            filledFormFieldCount: documentState.sourceFilledFormFieldCount
        ) {
            withAnimation(ResectaTokens.Anim.overlayDismiss) {
                documentState.annotationNoticeDismissed = true
            }
        }
        // Routed through the resolver so Reduce Motion swaps the slide
        // for an opacity-only crossfade.
        .transition(ResectaTokens.Anim.resolvedTransition(
            standard: .move(edge: .top).combined(with: .opacity),
            reduceMotion: reduceMotion))
        .padding(.top, ResectaTokens.Spacing.toolbarClearance)
    }
}
