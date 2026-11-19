import RedactionEngine

// One table of every brief message the app raises through the toast queue.
// A call site names its message by one case of `MessageID`; the table
// (`MessageCatalog.row(for:)`) holds the message's words and how it is
// shown today. `ToastQueueManager.post(_:event:action:stillValid:)` reads
// the row's text, today's severity (so today's edge and tint), its action
// label, tone, phases, must-be-seen, whether a repeat is the same message,
// and the layer it belongs to. The kind is recorded here and read by
// nothing in the app yet.

/// Every message the toast queue shows, one case each.
enum MessageID: Equatable {
    case textLayerDetected
    case imagePagesNote
    case encryptedSource(hadRestrictions: Bool)
    case droppedFilesFirstOpened(count: Int)
    case unsupportedFormatDropped
    case importBlockedDuringRun
    case importBlockedOnThisScreen(wayBack: String)
    case outputReclaimed
    case shared
    case shareSheetUnavailable
    case applyOrClearSelectedMatchesBeforeRedact
    case applyOrClearSelectedMatchesBeforeVerify
    case drawOrApplyFirst
    case boxTooSmall
    case deletedBoxes(count: Int)
    case selectionLimit
    case nearbyMatch
    case marked(applied: Int, alreadyCovered: Int)
    case searchClosedCleared(count: Int, interface: SearchInterface)
    case searchRerunCleared(count: Int, interface: SearchInterface)
    case modeSwitchCleared(unappliedCount: Int)
    case modeSwitchClearedAllApplied(count: Int)
    case recallCleared(count: Int)
    case searchResultsTruncated
    case savedRegexSaved
    case detectionDegraded(failedGazetteers: [String])
    case customTermTimeout
    case scannedRegionsNotAnalyzed
    case searchPreparationFailed

    /// The cases without their values: the names `--showToast=<name>` takes
    /// and the tests walk. The raw value is the case's name.
    enum Name: String, CaseIterable {
        case textLayerDetected
        case imagePagesNote
        case encryptedSource
        case droppedFilesFirstOpened
        case unsupportedFormatDropped
        case importBlockedDuringRun
        case importBlockedOnThisScreen
        case outputReclaimed
        case shared
        case shareSheetUnavailable
        case applyOrClearSelectedMatchesBeforeRedact
        case applyOrClearSelectedMatchesBeforeVerify
        case drawOrApplyFirst
        case boxTooSmall
        case deletedBoxes
        case selectionLimit
        case nearbyMatch
        case marked
        case searchClosedCleared
        case searchRerunCleared
        case modeSwitchCleared
        case modeSwitchClearedAllApplied
        case recallCleared
        case searchResultsTruncated
        case savedRegexSaved
        case detectionDegraded
        case customTermTimeout
        case scannedRegionsNotAnalyzed
        case searchPreparationFailed
    }

    var name: Name {
        switch self {
        case .textLayerDetected: .textLayerDetected
        case .imagePagesNote: .imagePagesNote
        case .encryptedSource: .encryptedSource
        case .droppedFilesFirstOpened: .droppedFilesFirstOpened
        case .unsupportedFormatDropped: .unsupportedFormatDropped
        case .importBlockedDuringRun: .importBlockedDuringRun
        case .importBlockedOnThisScreen: .importBlockedOnThisScreen
        case .outputReclaimed: .outputReclaimed
        case .shared: .shared
        case .shareSheetUnavailable: .shareSheetUnavailable
        case .applyOrClearSelectedMatchesBeforeRedact: .applyOrClearSelectedMatchesBeforeRedact
        case .applyOrClearSelectedMatchesBeforeVerify: .applyOrClearSelectedMatchesBeforeVerify
        case .drawOrApplyFirst: .drawOrApplyFirst
        case .boxTooSmall: .boxTooSmall
        case .deletedBoxes: .deletedBoxes
        case .selectionLimit: .selectionLimit
        case .nearbyMatch: .nearbyMatch
        case .marked: .marked
        case .searchClosedCleared: .searchClosedCleared
        case .searchRerunCleared: .searchRerunCleared
        case .modeSwitchCleared: .modeSwitchCleared
        case .modeSwitchClearedAllApplied: .modeSwitchClearedAllApplied
        case .recallCleared: .recallCleared
        case .searchResultsTruncated: .searchResultsTruncated
        case .savedRegexSaved: .savedRegexSaved
        case .detectionDegraded: .detectionDegraded
        case .customTermTimeout: .customTermTimeout
        case .scannedRegionsNotAnalyzed: .scannedRegionsNotAnalyzed
        case .searchPreparationFailed: .searchPreparationFailed
        }
    }

    /// One message of each name, with typical values: what the DEBUG
    /// `--showToast=<name>` hook shows.
    static func example(named name: Name) -> MessageID {
        switch name {
        case .textLayerDetected: .textLayerDetected
        case .imagePagesNote: .imagePagesNote
        case .encryptedSource: .encryptedSource(hadRestrictions: false)
        case .droppedFilesFirstOpened: .droppedFilesFirstOpened(count: 2)
        case .unsupportedFormatDropped: .unsupportedFormatDropped
        case .importBlockedDuringRun: .importBlockedDuringRun
        case .importBlockedOnThisScreen: .importBlockedOnThisScreen(wayBack: DocumentState.keepEditingTitle)
        case .outputReclaimed: .outputReclaimed
        case .shared: .shared
        case .shareSheetUnavailable: .shareSheetUnavailable
        case .applyOrClearSelectedMatchesBeforeRedact: .applyOrClearSelectedMatchesBeforeRedact
        case .applyOrClearSelectedMatchesBeforeVerify: .applyOrClearSelectedMatchesBeforeVerify
        case .drawOrApplyFirst: .drawOrApplyFirst
        case .boxTooSmall: .boxTooSmall
        case .deletedBoxes: .deletedBoxes(count: 2)
        case .selectionLimit: .selectionLimit
        case .nearbyMatch: .nearbyMatch
        case .marked: .marked(applied: 3, alreadyCovered: 0)
        case .searchClosedCleared: .searchClosedCleared(count: 2, interface: .search)
        case .searchRerunCleared: .searchRerunCleared(count: 2, interface: .search)
        case .modeSwitchCleared: .modeSwitchCleared(unappliedCount: 2)
        case .modeSwitchClearedAllApplied: .modeSwitchClearedAllApplied(count: 2)
        case .recallCleared: .recallCleared(count: 2)
        case .searchResultsTruncated: .searchResultsTruncated
        case .savedRegexSaved: .savedRegexSaved
        case .detectionDegraded:
            .detectionDegraded(failedGazetteers: [GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue])
        case .customTermTimeout: .customTermTimeout
        case .scannedRegionsNotAnalyzed: .scannedRegionsNotAnalyzed
        case .searchPreparationFailed: .searchPreparationFailed
        }
    }

    /// Every name at least once, written out (not derived from `Name`), plus
    /// the variants the table's tests read: both encrypted forms, one and
    /// many, each way back a refused drop names, both interfaces, and the
    /// other corpus failure.
    static let examples: [MessageID] = {
        var all: [MessageID] = [
            .textLayerDetected,
            .imagePagesNote,
            .encryptedSource(hadRestrictions: false),
            .encryptedSource(hadRestrictions: true),
            .droppedFilesFirstOpened(count: 2),
            .droppedFilesFirstOpened(count: 1000),
            .unsupportedFormatDropped,
            .importBlockedDuringRun,
            .importBlockedOnThisScreen(wayBack: DocumentState.keepEditingTitle),
            RedactWorkspaceView.dropOverSheetRefusal,
            .outputReclaimed,
            .shared,
            .shareSheetUnavailable,
            .applyOrClearSelectedMatchesBeforeRedact,
            .applyOrClearSelectedMatchesBeforeVerify,
            .drawOrApplyFirst,
            .boxTooSmall,
            .deletedBoxes(count: 2),
            .deletedBoxes(count: 1000),
            .selectionLimit,
            .nearbyMatch,
            .marked(applied: 3, alreadyCovered: 0),
            .marked(applied: 19, alreadyCovered: 9),
            .marked(applied: 0, alreadyCovered: 4),
            .marked(applied: 1000, alreadyCovered: 999),
            .searchClosedCleared(count: 1, interface: .search),
            .searchClosedCleared(count: 2, interface: .search),
            .searchClosedCleared(count: 1000, interface: .search),
            .searchClosedCleared(count: 2, interface: .scan),
            .searchRerunCleared(count: 1, interface: .search),
            .searchRerunCleared(count: 2, interface: .search),
            .searchRerunCleared(count: 1000, interface: .search),
            .searchRerunCleared(count: 2, interface: .scan),
            .modeSwitchCleared(unappliedCount: 1),
            .modeSwitchCleared(unappliedCount: 2),
            .modeSwitchCleared(unappliedCount: 1000),
            .modeSwitchClearedAllApplied(count: 1),
            .modeSwitchClearedAllApplied(count: 2),
            .modeSwitchClearedAllApplied(count: 1000),
            .recallCleared(count: 1),
            .recallCleared(count: 2),
            .recallCleared(count: 1000),
            .searchResultsTruncated,
            .savedRegexSaved,
            .detectionDegraded(failedGazetteers: [GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue]),
            .detectionDegraded(failedGazetteers: [GazetteerLoadDiagnostics.Gazetteer.nameGazetteer.rawValue]),
            .customTermTimeout,
            .scannedRegionsNotAnalyzed,
            .searchPreparationFailed,
        ]
        let waysBack: [FailedStateView.PrimaryAction] = [
            .reopenDocument, .chooseAnotherFile, .returnToEditor, .returnToResults,
        ]
        for action in waysBack {
            all.append(.importBlockedOnThisScreen(wayBack: FailedStateView.primaryActionLabel(action)))
        }
        all.append(.importBlockedOnThisScreen(
            wayBack: FailedStateView.primaryActionLabel(.chooseAnotherFile, door: .photos)))
        return all
    }()
}

/// A receipt answers the person's own act; a notice states a fact about the
/// document or the run.
enum MessageKind: Equatable, CaseIterable {
    case receipt, notice
}

/// The message's voice: done (it happened), note (worth knowing), caution
/// (something was held back or dropped), stop (it could not be done).
enum MessageTone: Equatable, CaseIterable {
    case done, note, caution, stop
}

/// One message's row. `todaySeverity` is the severity its site posted it
/// with before the table, so it appears where, how long and how it did.
struct MessageRow: Equatable {
    let text: String
    let todaySeverity: ToastSeverity
    let kind: MessageKind
    let tone: MessageTone
    /// The toast's button title; nil for a message without one.
    let actionLabel: String?
    /// Whether the button's action changes state; false when there is none.
    let actionChangesState: Bool
    /// The document phases the message can be raised in.
    let phases: Set<DocumentState.PhaseKind>
    let mustBeSeen: Bool
    /// A repeat tells the person nothing they have not just been told (a
    /// refusal of the same act, a limit still in force, a fact about the
    /// document): a post with the same words as a message of this row that
    /// is shown, paused or waiting is that message. False for a row whose
    /// every post reports one thing the person did or lost.
    let coalescesRepeats: Bool
    /// Raised as a layer leaves (or while the layer it is about is still
    /// up): it belongs to the layer that remains, not to the one in front.
    let showsInRemainingLayer: Bool

    init(
        text: String,
        todaySeverity: ToastSeverity,
        kind: MessageKind,
        tone: MessageTone,
        actionLabel: String? = nil,
        actionChangesState: Bool = false,
        phases: Set<DocumentState.PhaseKind>,
        mustBeSeen: Bool,
        coalescesRepeats: Bool = false,
        showsInRemainingLayer: Bool = false
    ) {
        self.text = text
        self.todaySeverity = todaySeverity
        self.kind = kind
        self.tone = tone
        self.actionLabel = actionLabel
        self.actionChangesState = actionChangesState
        self.phases = phases
        self.mustBeSeen = mustBeSeen
        self.coalescesRepeats = coalescesRepeats
        self.showsInRemainingLayer = showsInRemainingLayer
    }
}

enum MessageCatalog {

    static let allPhases: Set<DocumentState.PhaseKind> = [
        .empty, .importing, .editing, .detecting, .redacting,
        .verifying, .verified, .exporting, .failed,
    ]

    /// The row of one message. The texts come from the builders and
    /// constants beside the features that raise them; a builder that returns
    /// nil for nothing to say reads as "", which no site posts (each site
    /// keeps that builder's gate).
    static func row(for id: MessageID) -> MessageRow {
        switch id {
        case .textLayerDetected:
            return MessageRow(
                text: "Text layer detected \u{2014} Scan and Search can match text in this document.",
                todaySeverity: .info, kind: .notice, tone: .note,
                phases: [.editing], mustBeSeen: false, coalescesRepeats: true, showsInRemainingLayer: true)
        case .imagePagesNote:
            return MessageRow(
                text: RedactWorkspaceView.imageSourceMessage,
                todaySeverity: .info, kind: .notice, tone: .caution,
                phases: [.editing], mustBeSeen: true, coalescesRepeats: true, showsInRemainingLayer: true)
        case .encryptedSource(let hadRestrictions):
            return MessageRow(
                text: RedactWorkspaceView.encryptedSourceMessage(hadRestrictions: hadRestrictions),
                todaySeverity: .warning, kind: .notice, tone: .caution,
                phases: [.editing], mustBeSeen: true, coalescesRepeats: true, showsInRemainingLayer: true)
        case .droppedFilesFirstOpened(let count):
            return MessageRow(
                text: ImportService.dropOpenedFirstMessage(droppedCount: count),
                todaySeverity: .info, kind: .notice, tone: .caution,
                phases: [.editing], mustBeSeen: true)
        case .unsupportedFormatDropped:
            // A receipt longer than a receipt's 75 characters: it answers
            // the person's own drop, in every phase.
            return MessageRow(
                text: DocumentState.importRefusedNotPDFMessage,
                todaySeverity: .warning, kind: .receipt, tone: .caution,
                phases: allPhases, mustBeSeen: false, coalescesRepeats: true)
        case .importBlockedDuringRun:
            return MessageRow(
                text: DocumentState.importBlockedDuringPipelineMessage,
                todaySeverity: .warning, kind: .receipt, tone: .caution,
                phases: [.editing, .importing, .detecting, .redacting, .verifying, .exporting],
                mustBeSeen: false, coalescesRepeats: true)
        case .importBlockedOnThisScreen(let wayBack):
            return MessageRow(
                text: DocumentState.importBlockedOnThisScreenMessage(wayBack: wayBack),
                todaySeverity: .warning, kind: .receipt, tone: .caution,
                phases: [.editing, .verified, .failed], mustBeSeen: false, coalescesRepeats: true)
        case .outputReclaimed:
            // The one other receipt over 75 characters.
            return MessageRow(
                text: DocumentEditorView.purgeRerunToastMessage,
                todaySeverity: .warning, kind: .receipt, tone: .caution,
                actionLabel: "Re-run", actionChangesState: true,
                phases: [.verified], mustBeSeen: true, coalescesRepeats: true)
        case .shared:
            return MessageRow(
                text: DocumentEditorView.sharedAcknowledgmentToast,
                todaySeverity: .success, kind: .receipt, tone: .done,
                phases: [.verified], mustBeSeen: false)
        case .shareSheetUnavailable:
            return MessageRow(
                text: DocumentEditorView.shareSheetUnavailableMessage,
                todaySeverity: .warning, kind: .receipt, tone: .stop,
                phases: [.verified], mustBeSeen: true, coalescesRepeats: true)
        case .applyOrClearSelectedMatchesBeforeRedact:
            return MessageRow(
                text: DocumentState.RedactRefusal.selectedMatches.hint,
                todaySeverity: .warning, kind: .receipt, tone: .caution,
                phases: [.editing], mustBeSeen: false, coalescesRepeats: true)
        case .applyOrClearSelectedMatchesBeforeVerify:
            return MessageRow(
                text: DocumentState.RedactRefusal.selectedMatches.hint,
                todaySeverity: .info, kind: .receipt, tone: .caution,
                phases: [.verified], mustBeSeen: false, coalescesRepeats: true)
        case .drawOrApplyFirst:
            return MessageRow(
                text: DocumentState.RedactRefusal.noRegions.hint,
                todaySeverity: .warning, kind: .receipt, tone: .caution,
                phases: [.editing], mustBeSeen: false, coalescesRepeats: true)
        case .boxTooSmall:
            return MessageRow(
                text: RedactionOverlayView.subThresholdRejectionAnnouncement,
                todaySeverity: .info, kind: .receipt, tone: .caution,
                phases: [.editing], mustBeSeen: false, coalescesRepeats: true)
        case .deletedBoxes(let count):
            return MessageRow(
                text: RegionDeleteRule.deletedMessage(count: count),
                todaySeverity: .info, kind: .receipt, tone: .done,
                actionLabel: SearchAndRedactSheet.discardUndoActionLabel, actionChangesState: true,
                phases: [.editing], mustBeSeen: true)
        case .selectionLimit:
            return MessageRow(
                text: RedactionState.lassoSelectionCapToastMessage,
                todaySeverity: .warning, kind: .receipt, tone: .caution,
                phases: [.editing], mustBeSeen: true, coalescesRepeats: true)
        case .nearbyMatch:
            return MessageRow(
                text: EditorAnnouncementObservers.nudgeToastMessage,
                todaySeverity: .info, kind: .receipt, tone: .note,
                actionLabel: EditorAnnouncementObservers.nudgeToastActionLabel, actionChangesState: true,
                phases: [.editing], mustBeSeen: true, coalescesRepeats: true)
        case .marked(let applied, let alreadyCovered):
            return MessageRow(
                text: CommitFeedback.markedMessage(applied: applied, alreadyCovered: alreadyCovered) ?? "",
                todaySeverity: .success, kind: .receipt, tone: .done,
                phases: [.editing], mustBeSeen: false)
        case .searchClosedCleared(let count, let interface):
            return MessageRow(
                text: SearchAndRedactSheet.dismissClearedMessage(unappliedCount: count, interface: interface) ?? "",
                todaySeverity: .info, kind: .receipt, tone: .caution,
                phases: [.editing], mustBeSeen: true, showsInRemainingLayer: true)
        case .searchRerunCleared(let count, let interface):
            return MessageRow(
                text: SearchAndRedactSheet.rerunClearedMessage(selectedCount: count, interface: interface) ?? "",
                todaySeverity: .info, kind: .receipt, tone: .caution,
                phases: [.editing], mustBeSeen: true)
        case .modeSwitchCleared(let unappliedCount):
            // Today's severity is info, the bottom edge: a warning goes to
            // the top edge, which while the Search sheet is presented is the
            // editor's dimming scrim, so tapping its Undo dismissed the whole
            // sheet (observed on the simulator).
            return MessageRow(
                text: modeSwitchClearedText(unappliedCount: unappliedCount, count: 0),
                todaySeverity: .info, kind: .receipt, tone: .caution,
                actionLabel: SearchAndRedactSheet.discardUndoActionLabel, actionChangesState: true,
                phases: [.editing], mustBeSeen: true)
        case .modeSwitchClearedAllApplied(let count):
            // Info for the same reason as the unapplied form above.
            return MessageRow(
                text: modeSwitchClearedText(unappliedCount: 0, count: count),
                todaySeverity: .info, kind: .receipt, tone: .note,
                actionLabel: SearchAndRedactSheet.discardUndoActionLabel, actionChangesState: true,
                phases: [.editing], mustBeSeen: true)
        case .recallCleared(let count):
            return MessageRow(
                text: SearchAndRedactSheet.recallClearedMessage(unappliedCount: count) ?? "",
                todaySeverity: .info, kind: .receipt, tone: .caution,
                phases: [.editing], mustBeSeen: true, showsInRemainingLayer: true)
        case .searchResultsTruncated:
            return MessageRow(
                text: "Search results truncated. Refine your query for more specific matches.",
                todaySeverity: .warning, kind: .notice, tone: .caution,
                phases: [.editing], mustBeSeen: true, coalescesRepeats: true)
        case .savedRegexSaved:
            return MessageRow(
                text: SearchAndRedactSheet.savedRegexSavedToast,
                todaySeverity: .success, kind: .receipt, tone: .done,
                phases: [.editing], mustBeSeen: false)
        case .detectionDegraded(let failedGazetteers):
            return MessageRow(
                text: DetectionDegradeCopy.toast(failedGazetteers: failedGazetteers),
                todaySeverity: .warning, kind: .notice, tone: .caution,
                phases: [.editing], mustBeSeen: true, coalescesRepeats: true)
        case .customTermTimeout:
            return MessageRow(
                text: SearchAndRedactSheet.customTermTimeoutMessage,
                todaySeverity: .warning, kind: .notice, tone: .caution,
                phases: [.editing], mustBeSeen: true, coalescesRepeats: true)
        case .scannedRegionsNotAnalyzed:
            return MessageRow(
                text: "Some pages hold scanned regions that weren't text-analyzed because OCR is off. Turn on Include OCR Pages to search scanned content.",
                todaySeverity: .warning, kind: .notice, tone: .caution,
                phases: [.editing], mustBeSeen: true, coalescesRepeats: true)
        case .searchPreparationFailed:
            return MessageRow(
                text: "Could not prepare the document for search. Try again.",
                todaySeverity: .warning, kind: .receipt, tone: .stop,
                phases: [.editing], mustBeSeen: true, coalescesRepeats: true)
        }
    }

    /// The mode switch's two sentences: the unapplied count when unapplied
    /// matches were lost, else the whole list's count, all already applied.
    private static func modeSwitchClearedText(unappliedCount: Int, count: Int) -> String {
        // Every interface-crossing transition is programmatic (magic
        // wand, review arrival, saved-search recall), and the mode
        // switch's guard skips programmatic transitions — a toast that
        // reaches this point names a Search-side mode change.
        let verb = "Mode switch"
        let message: String
        if unappliedCount > 0 {
            let suffix = unappliedCount == 1 ? "" : "es"
            message = "\(verb) cleared \(unappliedCount) unapplied match\(suffix)."
        } else {
            let suffix = count == 1 ? "" : "es"
            message = "\(verb) cleared \(count) match\(suffix) (all already applied)."
        }
        return message
    }
}

extension DocumentState.RedactRefusal {
    /// The message a refused run start posts; nil for a refusal that says
    /// nothing (another phase, a run in flight or a pending review).
    var message: MessageID? {
        switch self {
        case .selectedMatches: .applyOrClearSelectedMatchesBeforeRedact
        case .noRegions: .drawOrApplyFirst
        case .busy: nil
        }
    }
}
