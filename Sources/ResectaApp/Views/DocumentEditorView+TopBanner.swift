import SwiftUI
import RedactionEngine

// The editor's band under the toolbar. It shows at most one notice: the
// first that holds, in a fixed order of six places (`TopBannerSlot`). A
// notice that is not shown waits its turn; hiding the band, or showing
// another notice in front, ends nothing (each notice ends only when it is
// dismissed or its condition ends). Two places have a notice today, the
// paused notice (a run left unfinished when the app went to the
// background) and the import annotation notice; the other four are kept
// in order for the notices that fill them later.

enum TopBannerSlot: Hashable, CaseIterable {
    // Declared in the band's order: the first that holds is shown.
    case redrawn
    case paused
    case importAnnotations
    case sourceProtection
    case fit
    case imagePages

    /// The band's occupant: the first place, in declared order, whose
    /// notice holds.
    static func occupant(of present: Set<TopBannerSlot>) -> TopBannerSlot? {
        allCases.first { present.contains($0) }
    }

    /// The number drawn on the folded mark: how many notices hold, shown
    /// from two; nil for one or none.
    static func waitingCount(of present: Set<TopBannerSlot>) -> Int? {
        present.count >= 2 ? present.count : nil
    }

    /// The places whose own condition holds, the phase aside: a run that
    /// takes the editing phase away and gives it back hides the band, it
    /// does not end a notice. `widenedOnPage` is the fit notice's input.
    static func holding(documentState: DocumentState, widenedOnPage: Bool = false) -> Set<TopBannerSlot> {
        var present: Set<TopBannerSlot> = []
        if documentState.wasPausedByBackground { present.insert(.paused) }
        if ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing,
            annotationTypeCount: ImportAnnotationNoticeBanner.noticeWorthyCount(
                documentState.sourceAnnotationFindings),
            filledFormFieldCount: documentState.sourceFilledFormFieldCount,
            dismissed: documentState.annotationNoticeDismissed
        ) {
            present.insert(.importAnnotations)
        }
        if widenedOnPage { present.insert(.fit) }
        return present
    }

    /// The editor's read: the occupant of what holds while editing, and
    /// nothing in any other phase.
    static func winner(documentState: DocumentState, widenedOnPage: Bool = false) -> TopBannerSlot? {
        guard documentState.phaseKind == .editing else { return nil }
        return occupant(of: holding(documentState: documentState, widenedOnPage: widenedOnPage))
    }

    /// Whether the band is drawn: only while editing, and only when the
    /// editor's sheet slot presents nothing or presents Search parked at
    /// its compact height. `searchIsTheSheet` is whether the sheet the slot
    /// presents is Search; every other sheet hides the band. Hiding the
    /// band ends nothing.
    static func bandIsShown(
        phase: DocumentState.PhaseKind, slotPresents: Bool,
        searchIsTheSheet: Bool, searchDetent: PresentationDetent
    ) -> Bool {
        phase == .editing && (!slotPresents || (searchIsTheSheet && searchDetent == .compactFloat))
    }

    // MARK: - Speaking a notice once

    /// One step of speech: the place whose notice is spoken now, if any,
    /// and the places marked as spoken after it.
    struct SpeechStep: Equatable {
        let speak: TopBannerSlot?
        let announced: Set<TopBannerSlot>
    }

    /// A place stays marked as spoken only while its notice holds, so a
    /// notice whose condition ends and holds again is spoken again; the
    /// shown notice is spoken when it is not marked. With nothing shown
    /// (the band hidden) nothing is spoken and every place that still
    /// holds stays marked, so the band's return is not spoken again.
    static func announceStep(
        shown: TopBannerSlot?, holding: Set<TopBannerSlot>, announced: Set<TopBannerSlot>
    ) -> SpeechStep {
        var kept = announced.intersection(holding)
        guard let shown, !kept.contains(shown) else {
            return SpeechStep(speak: nil, announced: kept)
        }
        kept.insert(shown)
        return SpeechStep(speak: shown, announced: kept)
    }

    /// The shown notice as speech reads it: nothing while the scene is not
    /// active, so a notice raised as the app leaves is spoken on its return.
    static func shownForSpeech(_ shown: TopBannerSlot?, sceneIsActive: Bool) -> TopBannerSlot? {
        sceneIsActive ? shown : nil
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
        case .importAnnotations?:
            annotationNoticeBanner
        case .redrawn?:
            // The redraw line's place: nothing holds it yet.
            EmptyView()
        case .sourceProtection?:
            // The password-protected source notes' place: nothing holds it yet.
            EmptyView()
        case .fit?:
            // The fit notice's place: the editor passes no fit input yet.
            EmptyView()
        case .imagePages?:
            // The image-pages note's place: nothing holds it yet.
            EmptyView()
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
