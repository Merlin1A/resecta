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
//
// The band floats 8 points under the toolbar's foot and never moves or
// resizes the page. A notice that meets a visible page folds to its mark
// after its reading time, and at once when a zoom, a scroll or a page
// change brings a page under it; a tap on the mark opens it. Each notice
// is spoken once when it is shown, and again when its condition has ended
// and holds again.

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

    // MARK: - The band

    /// The name of the canvas's own space: the page frames the canvas
    /// publishes and the notice's frame are both read in it.
    nonisolated static let noticeCanvasSpace = "noticeCanvas"

    /// Whether the sheet the editor's slot presents is Search (the slot's
    /// getter gives Search first, in the phases it presents Search in).
    var editorSlotPresentsSearch: Bool {
        redactionState.activeSearch != nil && Self.sheetSlotMayPresentSearch(in: documentState.phaseKind)
    }

    /// The band's occupant while the band is drawn; nil while it hides.
    var shownNotice: TopBannerSlot? {
        let shown = TopBannerSlot.bandIsShown(
            phase: documentState.phaseKind, slotPresents: editorSheetIsPresented,
            searchIsTheSheet: editorSlotPresentsSearch, searchDetent: searchSheetDetent)
        // The fit notice's own change feeds `widenedOnPage`; nothing does yet.
        return shown ? TopBannerSlot.winner(documentState: documentState, widenedOnPage: false) : nil
    }

    /// The band: the shown notice, open or folded, or nothing.
    @ViewBuilder
    var topBannerSlot: some View {
        let holding = TopBannerSlot.holding(documentState: documentState, widenedOnPage: false)
        ZStack(alignment: .top) {
            if let slot = shownNotice, let content = noticeContent(for: slot) {
                NoticeBand(
                    content: content,
                    count: TopBannerSlot.waitingCount(of: holding),
                    toolOn: activeTool != nil,
                    pageFrames: documentState.canvasPageFrames
                ) {
                    openNotice(for: slot)
                }
                .id(slot)
                // Routed through the resolver so Reduce Motion swaps the
                // slide for an opacity-only crossfade.
                .transition(ResectaTokens.Anim.resolvedTransition(
                    standard: .move(edge: .top).combined(with: .opacity),
                    reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The canvas publishes its page frames only while the band has a
        // notice: an occupant, shown or hidden behind a sheet.
        .onChange(of: TopBannerSlot.winner(documentState: documentState) != nil, initial: true) { _, wanted in
            documentState.canvasPageFramesWanted = wanted
        }
    }

    /// The words of the notice in `slot`; nil for a place nothing fills yet.
    func noticeContent(for slot: TopBannerSlot) -> NoticeContent? {
        switch slot {
        case .paused:
            return pausedNoticeContent
        case .importAnnotations:
            return annotationNoticeContent
        case .redrawn, .sourceProtection, .fit, .imagePages:
            // The redraw line, the password-protected source notes, the fit
            // notice and the image-pages note: their packages fill these.
            return nil
        }
    }

    /// The open notice of `slot`, with its action and close.
    @ViewBuilder
    func openNotice(for slot: TopBannerSlot) -> some View {
        switch slot {
        case .paused:
            resumeBannerOverlay
        case .importAnnotations:
            annotationNoticeBanner
        case .redrawn, .sourceProtection, .fit, .imagePages:
            EmptyView()
        }
    }

    /// The import annotation notice: the imported source carries
    /// annotations or filled form fields, which the on-screen view draws
    /// but the export raster (built from the page content stream) does not
    /// include. It stays until the user dismisses it.
    var annotationNoticeContent: NoticeContent {
        NoticeContent(
            id: ImportAnnotationNoticeBanner.messageID(
                findings: documentState.sourceAnnotationFindings,
                filledFormFieldCount: documentState.sourceFilledFormFieldCount),
            closes: true, identifier: "importAnnotationNotice")
    }

    private var annotationNoticeBanner: some View {
        NoticeView(content: annotationNoticeContent, onClose: {
            withAnimation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.overlayDismiss, reduceMotion: reduceMotion)) {
                documentState.annotationNoticeDismissed = true
            }
        }, placement: .band)
    }

    // MARK: - Speech

    /// What the band's speech reads: the notice shown for speech (none
    /// while the scene is not active) and the places that hold.
    struct NoticeSpeechInput: Equatable {
        let shown: TopBannerSlot?
        let holding: Set<TopBannerSlot>
    }

    var noticeSpeechInput: NoticeSpeechInput {
        NoticeSpeechInput(
            shown: TopBannerSlot.shownForSpeech(shownNotice, sceneIsActive: scenePhase == .active),
            holding: TopBannerSlot.holding(documentState: documentState, widenedOnPage: false))
    }

    /// One step of the band's speech: speaks the shown notice when it is
    /// not marked as spoken, and keeps the marks of what still holds.
    func speakNotice(_ input: NoticeSpeechInput) {
        let step = TopBannerSlot.announceStep(shown: input.shown, holding: input.holding, announced: announcedNotices)
        announcedNotices = step.announced
        if let slot = step.speak, let content = noticeContent(for: slot) {
            toastManager.announce(content.spokenLine)
        }
    }
}

/// The band's one notice: open, or folded to its mark, by the rules of
/// `NoticeRules`. The fold is how the notice is drawn, not something the
/// person has: when the band's view returns, the notice is open again and
/// folds again by the same rules. Only the notice and its mark take
/// touches; the rest of the band passes them to the canvas.
struct NoticeBand<Open: View>: View {
    let content: NoticeContent
    let count: Int?
    let toolOn: Bool
    let pageFrames: [CanvasRect]
    @ViewBuilder let open: () -> Open

    @State private var fold: BandFold = .open(timed: false)
    /// The open notice's frame in the canvas's space, rounded outward.
    @State private var noticeRect: CanvasRect?
    /// Until the first frames and the notice's frame are both known, the
    /// notice has not arrived: the first change after is its arrival.
    @State private var arrivalPending = true

    @Environment(\.dynamicTypeSize) private var personSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverRunning

    var body: some View {
        GeometryReader { canvas in
            let size = MessageSizing.drawSize(
                person: personSize, limit: MessageSizing.limit(space: canvas.size.height)
            ) { NoticeView.height(of: content, size: $0, width: canvas.size.width) }
            Group {
                switch fold {
                case .open:
                    open()
                        .environment(\.dynamicTypeSize, size)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named(DocumentEditorView.noticeCanvasSpace))
                        } action: { rect in
                            noticeRect = CanvasRect(outward: rect)
                        }
                        .transition(.opacity)
                case .folded:
                    if NoticeRules.foldedMarkIsShown(fold: fold, toolOn: toolOn) {
                        NoticeFoldedMark(content: content, count: count) { step(.tapped) }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            // The 44 circle 16 from the canvas's edge, in its 46 frame.
                            .padding(.trailing, NoticeView.Metrics.sideInset
                                     - (NoticeView.touchSide - NoticeView.Metrics.foldedSide) / 2)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.top, NoticeView.Metrics.gapUnderToolbar)
        }
        .onChange(of: pageFrames, initial: true) { _, _ in measureChanged(framesMoved: true) }
        .onChange(of: noticeRect) { _, _ in measureChanged(framesMoved: false) }
        .task(id: fold) {
            guard NoticeRules.readingClockRuns(fold: fold, voiceOverRunning: voiceOverRunning) else { return }
            let seconds = NoticeRules.readingTime(words: content.wordCount, hasAction: content.actionLabel != nil)
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            step(.readingTimeElapsed)
        }
    }

    private var meetsAPage: Bool {
        guard let noticeRect else { return false }
        return NoticeRules.meetsAnyPage(noticeRect, pages: pageFrames)
    }

    /// The first moment the frames and the notice are both known is the
    /// notice's arrival; after it, only a move of the pages is a page move
    /// (the notice's own frame changing is neither).
    private func measureChanged(framesMoved: Bool) {
        if arrivalPending {
            guard noticeRect != nil, !pageFrames.isEmpty else { return }
            arrivalPending = false
            step(NoticeRules.frameEvent(firstSinceWanted: true))
        } else if framesMoved {
            step(NoticeRules.frameEvent(firstSinceWanted: false))
        }
    }

    private func step(_ event: BandEvent) {
        let next = NoticeRules.next(fold, event, meets: meetsAPage)
        guard next != fold else { return }
        withAnimation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.stateChange, reduceMotion: reduceMotion)) {
            fold = next
        }
    }
}
