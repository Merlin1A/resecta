import SwiftUI
import RedactionEngine

// The Home / Done close path, moved out of `DocumentEditorView.swift`
// (the hub) along its `// MARK: - Verification Done` and
// `// MARK: - Home` seams: the shared session teardown
// (`performDoneCloseSession`), the Home tap's route, the park-then-dialog
// hand-off and the dialog's presenting binding (the park and the restore
// live in `DocumentEditorView+SheetParking.swift`). The hub's `body` keeps the dialog itself and the sheet slot's
// `onDismiss` hand-off; the hub's `@State showDoneConfirmation` /
// `homeCloseAwaitsSheetDismissal` stay stored
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
        // A run pending in the run-entry window — the phase still
        // `.editing`, `activePipelineTask` set while the manual-term
        // capture works — is cancelled FIRST, the order
        // `RedactWorkspace.tearDown()` keeps: the run surrenders at its
        // next cancellation check instead of redacting a torn-down
        // session. A no-op when nothing is pending.
        documentState.cancelActivePipeline(redactionState: redactionState)
        // A sheet parked for the close dialog goes down with the
        // session — nothing is re-presented after the teardown.
        homeCloseAwaitsSheetDismissal = false
        parkedEditorSearch?.cancelSearchWithoutAwait()
        parkedEditorSearch = nil
        // The one reset Start Over runs — the same fields in the same
        // order, nothing hand-copied; it ends in `.empty`.
        documentState.resetForStartOver(redactionState: redactionState, coordinator: coordinator)
    }

    // MARK: - Home (1.1.0 Home swap — shares the Done close path)

    /// Editing-phase Home: confirm through the shared close dialog when
    /// the session carries work, else tear down directly — the same
    /// two-way split the verification-screen Done button makes, on Done's
    /// own teardown (`performDoneCloseSession()`). The return to HomeView
    /// is the existing `.empty` auto-return; nothing here calls
    /// `appCoordinator.returnHome()` directly. While the
    /// sheet slot is presenting, the confirm route parks the sheet first
    /// (`parkEditorSheet()`) and the dialog presents from the
    /// slot's `onDismiss`.
    func handleHomeTap() {
        guard !homeCloseAwaitsSheetDismissal else { return }
        let needsConfirm = Self.homeNeedsCloseConfirm(
            hasDrawnRegions: hasDrawnRegions,
            hasUnappliedSelections: DocumentState.hasUnappliedSelections(redactionState)
        )
        switch Self.homeCloseRoute(needsConfirm: needsConfirm,
                                   sheetPresented: editorSheetIsPresented) {
        case .closeDirectly:
            performDoneCloseSession()
        case .presentDialog:
            showDoneConfirmation = true
        case .parkSheetThenDialog:
            homeCloseAwaitsSheetDismissal = true
            parkEditorSheet()
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

    /// `$showDoneConfirmation` with one hook: when the dialog goes
    /// down without Close — the Cancel row, or the tap-outside dismissal
    /// of the iOS 26 popover — a parked search comes back. Deferred one
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
                Task { @MainActor in
                    restoreParkedSearchIfNeeded()
                }
            }
        )
    }

    /// Pure gate for the Home close confirm (mirrors
    /// `batchOpsMenuShouldShow` / `shareNeedsFailConfirm`): drawn or
    /// applied regions — the gate Done uses — or search selections not yet
    /// applied (`DocumentState.hasUnappliedSelections`, the rule Redact
    /// and the sheet's own Dismiss read). An untouched search session with
    /// nothing selected is transient, not work — no confirm.
    static func homeNeedsCloseConfirm(
        hasDrawnRegions: Bool, hasUnappliedSelections: Bool
    ) -> Bool {
        hasDrawnRegions || hasUnappliedSelections
    }

    /// Message for the shared close dialog, switched on phase — one
    /// teardown family with the failed screen's Start Over: every phase
    /// but verification reads Start Over's own sentence
    /// (`FailedStateView.startOverMessage`); the verification screen adds
    /// its results (the literal pinned by
    /// `VerificationActionBarDoneConfirmationTests` and
    /// `DocumentEditorHomeCloseTests`).
    static func closeDialogMessage(phaseKind: DocumentState.PhaseKind) -> String {
        switch phaseKind {
        case .verified:
            "The document, drawn regions, and verification results will be cleared."
        default:
            FailedStateView.startOverMessage
        }
    }
}
