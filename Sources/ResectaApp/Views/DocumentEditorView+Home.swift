import SwiftUI
import RedactionEngine

// The Home / Done close path, moved out of `DocumentEditorView.swift`
// (the hub) along its `// MARK: - Verification Done` and
// `// MARK: - Home` seams: the shared session teardown
// (`performDoneCloseSession`), the Home tap's route, the park-then-dialog
// hand-off, the parked-review restore and the dialog's presenting
// binding. The hub's `body` keeps the dialog itself and the sheet slot's
// `onDismiss` hand-off; the hub's `@State showDoneConfirmation` /
// `homeCloseAwaitsSheetDismissal` / `homeCloseParkedReview` stay stored
// on the hub (an extension adds no storage) and are read from here.

extension DocumentEditorView {
    // MARK: - Verification Done (lifted from VerificationActionBar)

    /// True when the session carries at least one drawn region. Gates
    /// the Done confirmation dialog on the verification-results screen —
    /// empty sessions close directly. Lifted verbatim from
    /// `VerificationActionBar.hasDrawnRegions` when Done moved into the
    /// top-left toolbar.
    var hasDrawnRegions: Bool {
        redactionState.regions.values.contains { !$0.isEmpty }
    }

    /// Tear down the verified session. Lifted verbatim from
    /// `VerificationActionBar.performDoneCloseSession()` — the bar is
    /// gone; the close path now hangs off the top-left Done button.
    /// Extracted so the empty-regions direct path and the
    /// confirmed-with-regions path share one implementation. The
    /// editing-phase Home entry (`handleHomeTap()`) shares this exact path.
    func performDoneCloseSession() {
        // A sheet parked for the close dialog goes down with the
        // session — nothing is re-presented after the teardown.
        homeCloseAwaitsSheetDismissal = false
        homeCloseParkedReview = false
        // Downgrade temp-file protection before tearing down
        // the session state. Done before clearAll() so the path
        // walked still matches the live session's outputURL.
        coordinator.downgradeTempProtectionOnSessionClose()
        redactionState.clearAll()
        documentState.sourceDocument = nil
        documentState.textLayerStatus = [:]
        documentState.sourceAnnotationFindings = []
        documentState.annotationNoticeDismissed = false
        documentState.currentPageIndex = 0
        documentState.lastUsedPipelineMode = nil
        documentState.wasPausedByBackground = false
        documentState.pausedFromPhase = nil
        documentState.transition(to: .empty)
    }

    // MARK: - Home (1.1.0 Home swap — shares the Done close path)

    /// Editing-phase Home: confirm through the shared close dialog when
    /// the session carries work, else tear down directly — the same
    /// two-way split the verification-screen Done button makes, on Done's
    /// own teardown (`performDoneCloseSession()`). The return to HomeView
    /// is the existing `.empty` auto-return; nothing here calls
    /// `appCoordinator.returnHome()` directly. While the
    /// sheet slot is presenting, the confirm route parks the sheet first
    /// (`parkEditorSheetForHomeClose()`) and the dialog presents from the
    /// slot's `onDismiss`.
    func handleHomeTap() {
        guard !homeCloseAwaitsSheetDismissal else { return }
        let needsConfirm = Self.homeNeedsCloseConfirm(
            hasDrawnRegions: hasDrawnRegions,
            hasPendingTriage: redactionState.pendingTriage != nil
        )
        switch Self.homeCloseRoute(needsConfirm: needsConfirm,
                                   sheetPresented: editorSheetIsPresented) {
        case .closeDirectly:
            performDoneCloseSession()
        case .presentDialog:
            showDoneConfirmation = true
        case .parkSheetThenDialog:
            homeCloseAwaitsSheetDismissal = true
            parkEditorSheetForHomeClose()
        }
    }

    /// How a Home tap reaches the teardown. No confirm
    /// owed → the direct teardown, sheet or not (a presented sheet drops
    /// with it — the idle path already proven). Confirm owed with the
    /// sheet slot idle → the dialog. Confirm owed while the slot is
    /// presenting → park the sheet first; the dialog presents from the
    /// slot's `onDismiss`, since UIKit refuses two presentations on one
    /// host.
    enum HomeCloseRoute: Equatable {
        case closeDirectly
        case presentDialog
        case parkSheetThenDialog
    }

    /// Pure route for the Home tap (mirrors `homeNeedsCloseConfirm`).
    static func homeCloseRoute(needsConfirm: Bool, sheetPresented: Bool) -> HomeCloseRoute {
        guard needsConfirm else { return .closeDirectly }
        return sheetPresented ? .parkSheetThenDialog : .presentDialog
    }

    /// Pure gate for re-presenting a parked review after the close dialog
    /// went down without Close: only when a review was parked, the staged
    /// set is still pending, the sheet slot is idle and the session is
    /// still editing (Close clears the parked flag before this can run).
    static func homeCloseShouldRepresentReview(
        parkedReview: Bool, hasPendingTriage: Bool,
        sheetPresented: Bool, phaseKind: DocumentState.PhaseKind
    ) -> Bool {
        parkedReview && hasPendingTriage && !sheetPresented && phaseKind == .editing
    }

    /// Mirrors the `.sheet(item:)` getter: the slot is presenting whenever
    /// either source is live.
    private var editorSheetIsPresented: Bool {
        redactionState.activeSearch != nil
            || redactionState.pendingCanvasRationaleRequest != nil
    }

    /// Take the presenting sheet down without touching the work behind it.
    /// Only `activeSearch` is cleared — a staged review stays in
    /// `pendingTriage` (the presentation bridge observes the pending set's
    /// arrival, not its persistence, so nothing re-presents meanwhile); a
    /// rationale sheet is simply dropped.
    private func parkEditorSheetForHomeClose() {
        if redactionState.activeSearch != nil {
            homeCloseParkedReview = redactionState.pendingTriage != nil
            redactionState.activeSearch = nil
        } else if redactionState.pendingCanvasRationaleRequest != nil {
            redactionState.pendingCanvasRationaleRequest = nil
        }
    }

    /// Re-present a parked review after the dialog went down without
    /// Close, through the same bridge every review arrival uses
    /// (`presentReviewInScanInterface()` — fresh Scan interface, medium
    /// detent, the staged set untouched).
    private func restoreParkedReviewIfNeeded() {
        let shouldRepresent = Self.homeCloseShouldRepresentReview(
            parkedReview: homeCloseParkedReview,
            hasPendingTriage: redactionState.pendingTriage != nil,
            sheetPresented: editorSheetIsPresented,
            phaseKind: documentState.phaseKind
        )
        homeCloseParkedReview = false
        guard shouldRepresent else { return }
        presentReviewInScanInterface()
    }

    /// `$showDoneConfirmation` with one hook: when the dialog goes
    /// down without Close — the Cancel row, or the tap-outside dismissal
    /// of the iOS 26 popover — a parked review comes back. Deferred one
    /// runloop turn: the setter runs inside SwiftUI's dismiss transaction,
    /// where re-presenting a sheet is the re-entrant write class the sheet
    /// slot's own setter defers (see its comment). Close clears the parked
    /// flag first, so the restore is a no-op on that path.
    var doneConfirmationPresented: Binding<Bool> {
        Binding(
            get: { showDoneConfirmation },
            set: { presented in
                showDoneConfirmation = presented
                guard !presented else { return }
                Task { @MainActor in restoreParkedReviewIfNeeded() }
            }
        )
    }

    /// Pure gate for the Home close confirm (mirrors
    /// `batchOpsMenuShouldShow` / `shareNeedsFailConfirm`): drawn or
    /// applied regions — the gate Done uses — or a staged Scan review
    /// awaiting the user (`pendingTriage`), the one editing-only work
    /// state Done never sees. An active search session with nothing
    /// applied is transient, not work — no confirm.
    static func homeNeedsCloseConfirm(hasDrawnRegions: Bool, hasPendingTriage: Bool) -> Bool {
        hasDrawnRegions || hasPendingTriage
    }

    /// Message for the shared close dialog, switched on phase. The
    /// verification screen names verification results (the literal pinned
    /// by `VerificationActionBarDoneConfirmationTests`); every other
    /// phase — the editing-phase Home entry — names detection results,
    /// the sentence the Replace dialog already uses
    /// (`RedactWorkspaceView`; byte-identity pinned by
    /// `DocumentEditorHomeCloseTests`).
    static func closeDialogMessage(phaseKind: DocumentState.PhaseKind) -> String {
        switch phaseKind {
        case .verified:
            "Drawn regions and verification results will be cleared."
        default:
            "Drawn regions and detection results will be cleared."
        }
    }
}
