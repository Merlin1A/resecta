import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// The message table: every brief message the toast queue shows is one case
// of `MessageID` and one row of `MessageCatalog`. The expectations here are
// a frozen copy of the table, written out by hand, never read from the
// implementation; the sentences are the shipped constants and builders, and
// the sentences that moved into the table are pinned by copies.

@Suite("Message table")
@MainActor
struct MessageCatalogTests {

    // MARK: - The frozen table

    struct Frozen {
        let severity: ToastSeverity
        let kind: MessageKind
        let tone: MessageTone
        let phases: Set<DocumentState.PhaseKind>
        let mustBeSeen: Bool
        let coalescesRepeats: Bool
        let showsInRemainingLayer: Bool
    }

    static let everyPhase: Set<DocumentState.PhaseKind> = [
        .empty, .importing, .editing, .detecting, .redacting, .verifying, .verified, .exporting, .failed,
    ]

    static let frozen: [MessageID.Name: Frozen] = [
        .textLayerDetected: Frozen(
            severity: .info, kind: .notice, tone: .note, phases: [.editing], mustBeSeen: false,
            coalescesRepeats: true, showsInRemainingLayer: true),
        .imagePagesNote: Frozen(
            severity: .info, kind: .notice, tone: .caution, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: true, showsInRemainingLayer: true),
        .encryptedSource: Frozen(
            severity: .warning, kind: .notice, tone: .caution, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: true, showsInRemainingLayer: true),
        .droppedFilesFirstOpened: Frozen(
            severity: .info, kind: .notice, tone: .caution, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: false, showsInRemainingLayer: false),
        .unsupportedFormatDropped: Frozen(
            severity: .warning, kind: .receipt, tone: .caution, phases: everyPhase, mustBeSeen: false,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .importBlockedDuringRun: Frozen(
            severity: .warning, kind: .receipt, tone: .caution,
            phases: [.editing, .importing, .detecting, .redacting, .verifying, .exporting], mustBeSeen: false,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .importBlockedOnThisScreen: Frozen(
            severity: .warning, kind: .receipt, tone: .caution, phases: [.editing, .verified, .failed],
            mustBeSeen: false,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .outputReclaimed: Frozen(
            severity: .warning, kind: .receipt, tone: .caution, phases: [.verified], mustBeSeen: true,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .shared: Frozen(
            severity: .success, kind: .receipt, tone: .done, phases: [.verified], mustBeSeen: false,
            coalescesRepeats: false, showsInRemainingLayer: false),
        .shareSheetUnavailable: Frozen(
            severity: .warning, kind: .receipt, tone: .stop, phases: [.verified], mustBeSeen: true,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .applyOrClearSelectedMatchesBeforeRedact: Frozen(
            severity: .warning, kind: .receipt, tone: .caution, phases: [.editing], mustBeSeen: false,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .applyOrClearSelectedMatchesBeforeVerify: Frozen(
            severity: .info, kind: .receipt, tone: .caution, phases: [.verified], mustBeSeen: false,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .drawOrApplyFirst: Frozen(
            severity: .warning, kind: .receipt, tone: .caution, phases: [.editing], mustBeSeen: false,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .boxTooSmall: Frozen(
            severity: .info, kind: .receipt, tone: .caution, phases: [.editing], mustBeSeen: false,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .deletedBoxes: Frozen(
            severity: .info, kind: .receipt, tone: .done, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: false, showsInRemainingLayer: false),
        .selectionLimit: Frozen(
            severity: .warning, kind: .receipt, tone: .caution, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .nearbyMatch: Frozen(
            severity: .info, kind: .receipt, tone: .note, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .marked: Frozen(
            severity: .success, kind: .receipt, tone: .done, phases: [.editing], mustBeSeen: false,
            coalescesRepeats: false, showsInRemainingLayer: false),
        .searchClosedCleared: Frozen(
            severity: .info, kind: .receipt, tone: .caution, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: false, showsInRemainingLayer: true),
        .searchRerunCleared: Frozen(
            severity: .info, kind: .receipt, tone: .caution, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: false, showsInRemainingLayer: false),
        .modeSwitchCleared: Frozen(
            severity: .info, kind: .receipt, tone: .caution, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: false, showsInRemainingLayer: false),
        .modeSwitchClearedAllApplied: Frozen(
            severity: .info, kind: .receipt, tone: .note, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: false, showsInRemainingLayer: false),
        .recallCleared: Frozen(
            severity: .info, kind: .receipt, tone: .caution, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: false, showsInRemainingLayer: true),
        .searchResultsTruncated: Frozen(
            severity: .warning, kind: .notice, tone: .caution, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .savedRegexSaved: Frozen(
            severity: .success, kind: .receipt, tone: .done, phases: [.editing], mustBeSeen: false,
            coalescesRepeats: false, showsInRemainingLayer: false),
        .detectionDegraded: Frozen(
            severity: .warning, kind: .notice, tone: .caution, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .customTermTimeout: Frozen(
            severity: .warning, kind: .notice, tone: .caution, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .scannedRegionsNotAnalyzed: Frozen(
            severity: .warning, kind: .notice, tone: .caution, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: true, showsInRemainingLayer: false),
        .searchPreparationFailed: Frozen(
            severity: .warning, kind: .receipt, tone: .stop, phases: [.editing], mustBeSeen: true,
            coalescesRepeats: true, showsInRemainingLayer: false),
    ]

    /// The 29 names, in the table's order: what `--showToast=<name>` takes.
    nonisolated static let messageNames: [String] = [
        "textLayerDetected", "imagePagesNote", "encryptedSource", "droppedFilesFirstOpened",
        "unsupportedFormatDropped", "importBlockedDuringRun", "importBlockedOnThisScreen", "outputReclaimed",
        "shared", "shareSheetUnavailable", "applyOrClearSelectedMatchesBeforeRedact",
        "applyOrClearSelectedMatchesBeforeVerify", "drawOrApplyFirst", "boxTooSmall", "deletedBoxes",
        "selectionLimit", "nearbyMatch", "marked", "searchClosedCleared", "searchRerunCleared",
        "modeSwitchCleared", "modeSwitchClearedAllApplied", "recallCleared", "searchResultsTruncated",
        "savedRegexSaved", "detectionDegraded", "customTermTimeout", "scannedRegionsNotAnalyzed",
        "searchPreparationFailed",
    ]

    /// The shipped sentence for a message: the constant or builder beside
    /// the feature, called on the message's own values; for a sentence that
    /// moved into the table, a copy of it.
    static func shippedText(_ id: MessageID) -> String? {
        switch id {
        case .textLayerDetected:
            return "Text layer detected \u{2014} Scan and Search can match text in this document."
        case .imagePagesNote:
            return RedactWorkspaceView.imageSourceMessage
        case .encryptedSource(let hadRestrictions):
            return RedactWorkspaceView.encryptedSourceMessage(hadRestrictions: hadRestrictions)
        case .droppedFilesFirstOpened(let count):
            return ImportService.dropOpenedFirstMessage(droppedCount: count)
        case .unsupportedFormatDropped:
            return DocumentState.importRefusedNotPDFMessage
        case .importBlockedDuringRun:
            return DocumentState.importBlockedDuringPipelineMessage
        case .importBlockedOnThisScreen(let wayBack):
            return DocumentState.importBlockedOnThisScreenMessage(wayBack: wayBack)
        case .outputReclaimed:
            return DocumentEditorView.purgeRerunToastMessage
        case .shared:
            return DocumentEditorView.sharedAcknowledgmentToast
        case .shareSheetUnavailable:
            return DocumentEditorView.shareSheetUnavailableMessage
        case .applyOrClearSelectedMatchesBeforeRedact, .applyOrClearSelectedMatchesBeforeVerify:
            return DocumentState.RedactRefusal.selectedMatches.hint
        case .drawOrApplyFirst:
            return DocumentState.RedactRefusal.noRegions.hint
        case .boxTooSmall:
            return RedactionOverlayView.subThresholdRejectionAnnouncement
        case .deletedBoxes(let count):
            return RegionDeleteRule.deletedMessage(count: count)
        case .selectionLimit:
            return RedactionState.lassoSelectionCapToastMessage
        case .nearbyMatch:
            return EditorAnnouncementObservers.nudgeToastMessage
        case .marked(let applied, let alreadyCovered):
            return CommitFeedback.markedMessage(applied: applied, alreadyCovered: alreadyCovered)
        case .searchClosedCleared(let count, let interface):
            return SearchAndRedactSheet.dismissClearedMessage(unappliedCount: count, interface: interface)
        case .searchRerunCleared(let count, let interface):
            return SearchAndRedactSheet.rerunClearedMessage(selectedCount: count, interface: interface)
        case .modeSwitchCleared(let unappliedCount):
            let verb = "Mode switch"
            let suffix = unappliedCount == 1 ? "" : "es"
            return "\(verb) cleared \(unappliedCount) unapplied match\(suffix)."
        case .modeSwitchClearedAllApplied(let count):
            let verb = "Mode switch"
            let suffix = count == 1 ? "" : "es"
            return "\(verb) cleared \(count) match\(suffix) (all already applied)."
        case .recallCleared(let count):
            return SearchAndRedactSheet.recallClearedMessage(unappliedCount: count)
        case .searchResultsTruncated:
            return "Search results truncated. Refine your query for more specific matches."
        case .savedRegexSaved:
            return SearchAndRedactSheet.savedRegexSavedToast
        case .detectionDegraded(let failedGazetteers):
            return DetectionDegradeCopy.toast(failedGazetteers: failedGazetteers)
        case .customTermTimeout:
            return SearchAndRedactSheet.customTermTimeoutMessage
        case .scannedRegionsNotAnalyzed:
            return "Some pages hold scanned regions that weren't text-analyzed because OCR is off. Turn on Include OCR Pages to search scanned content."
        case .searchPreparationFailed:
            return "Could not prepare the document for search. Try again."
        }
    }

    // MARK: - The table

    @Test("Every message has an example, and there are 29")
    func everyMessageHasAnExample() {
        #expect(MessageID.Name.allCases.count == 29)
        #expect(Set(MessageID.examples.map(\.name)) == Set(MessageID.Name.allCases))
        for name in MessageID.Name.allCases {
            #expect(MessageID.example(named: name).name == name)
        }
    }

    @Test("Each row has the kind, tone, today's severity, phases and must-be-seen of the frozen table")
    func rowsMatchTheFrozenTable() {
        #expect(Self.frozen.count == 29)
        for id in MessageID.examples {
            guard let want = Self.frozen[id.name] else {
                Issue.record("\(id.name) is not in the frozen table")
                continue
            }
            let row = MessageCatalog.row(for: id)
            #expect(row.todaySeverity == want.severity, "\(id)")
            #expect(row.kind == want.kind, "\(id)")
            #expect(row.tone == want.tone, "\(id)")
            #expect(row.phases == want.phases, "\(id)")
            #expect(row.mustBeSeen == want.mustBeSeen, "\(id)")
            #expect(row.coalescesRepeats == want.coalescesRepeats, "\(id)")
            #expect(row.showsInRemainingLayer == want.showsInRemainingLayer, "\(id)")
        }
        let rows = MessageID.Name.allCases.map { MessageCatalog.row(for: .example(named: $0)) }
        #expect(rows.filter { $0.todaySeverity == .info }.count == 12)
        #expect(rows.filter { $0.todaySeverity == .warning }.count == 14)
        #expect(rows.filter { $0.todaySeverity == .success }.count == 3)
        #expect(rows.filter { $0.kind == .receipt }.count == 21)
        #expect(rows.filter { $0.kind == .notice }.count == 8)
        #expect(rows.filter { $0.tone == .caution }.count == 20)
        #expect(rows.filter { $0.tone == .done }.count == 4)
        #expect(rows.filter { $0.tone == .note }.count == 3)
        #expect(rows.filter { $0.tone == .stop }.count == 2)
        #expect(rows.filter(\.mustBeSeen).count == 18)
        #expect(rows.filter(\.showsInRemainingLayer).count == 5)
    }

    @Test("Every row is either one message while it is up or a new event each time, and the split is 19 and 10")
    func everyRowCoalescesOrNot() {
        let rows = MessageID.Name.allCases.map { (name: $0, row: MessageCatalog.row(for: .example(named: $0))) }
        let oneWhileUp = Set(rows.filter { $0.row.coalescesRepeats }.map { $0.name })
        let newEachTime = Set(rows.filter { !$0.row.coalescesRepeats }.map { $0.name })
        #expect(oneWhileUp.count == 19)
        #expect(newEachTime.count == 10)
        // Each post of these reports one thing the person did or lost.
        #expect(newEachTime == [
            .droppedFilesFirstOpened, .shared, .deletedBoxes, .marked, .searchClosedCleared,
            .searchRerunCleared, .modeSwitchCleared, .modeSwitchClearedAllApplied, .recallCleared, .savedRegexSaved,
        ])
        // Every variant of a row agrees with its row.
        for id in MessageID.examples {
            #expect(MessageCatalog.row(for: id).coalescesRepeats == oneWhileUp.contains(id.name), "\(id)")
        }
    }

    @Test("Only the three shipped confirmations use the success severity")
    func onlyThreeConfirmationsAreSuccess() {
        let success = Set(MessageID.examples
            .filter { MessageCatalog.row(for: $0).todaySeverity == .success }
            .map(\.name))
        #expect(success == [.shared, .marked, .savedRegexSaved])
        #expect(!MessageID.examples.contains { MessageCatalog.row(for: $0).todaySeverity == .error })
    }

    @Test("Every row with an action says its action changes state")
    func everyActionChangesState() {
        let labels: [MessageID.Name: String] = [
            .outputReclaimed: "Re-run",
            .deletedBoxes: SearchAndRedactSheet.discardUndoActionLabel,
            .nearbyMatch: EditorAnnouncementObservers.nudgeToastActionLabel,
            .modeSwitchCleared: SearchAndRedactSheet.discardUndoActionLabel,
            .modeSwitchClearedAllApplied: SearchAndRedactSheet.discardUndoActionLabel,
        ]
        for id in MessageID.examples {
            let row = MessageCatalog.row(for: id)
            #expect(row.actionLabel == labels[id.name], "\(id)")
            #expect(row.actionChangesState == (labels[id.name] != nil), "\(id)")
        }
    }

    @Test("Every text is the shipped sentence")
    func everyTextIsTheShippedSentence() {
        for id in MessageID.examples {
            let text = MessageCatalog.row(for: id).text
            #expect(!text.isEmpty, "\(id)")
            #expect(text == Self.shippedText(id), "\(id)")
        }
        // The variants the examples carry.
        let examples = MessageID.examples
        #expect(examples.contains(.encryptedSource(hadRestrictions: true)))
        #expect(examples.contains(.encryptedSource(hadRestrictions: false)))
        #expect(examples.contains(.detectionDegraded(
            failedGazetteers: [GazetteerLoadDiagnostics.Gazetteer.nameGazetteer.rawValue])))
        for count in [2, 1000] {
            #expect(examples.contains(.droppedFilesFirstOpened(count: count)))
            #expect(examples.contains(.deletedBoxes(count: count)))
        }
        for count in [1, 2, 1000] {
            #expect(examples.contains(.searchClosedCleared(count: count, interface: .search)))
            #expect(examples.contains(.searchRerunCleared(count: count, interface: .search)))
            #expect(examples.contains(.modeSwitchCleared(unappliedCount: count)))
            #expect(examples.contains(.modeSwitchClearedAllApplied(count: count)))
            #expect(examples.contains(.recallCleared(count: count)))
        }
        #expect(examples.contains(.searchClosedCleared(count: 2, interface: .scan)))
        #expect(examples.contains(.searchRerunCleared(count: 2, interface: .scan)))
        #expect(examples.contains(.marked(applied: 19, alreadyCovered: 9)))
        #expect(examples.contains(.marked(applied: 0, alreadyCovered: 4)))
        #expect(examples.contains(.marked(applied: 1000, alreadyCovered: 999)))
        let waysBack = [
            "Dismiss",
            FailedStateView.primaryActionLabel(.reopenDocument),
            FailedStateView.primaryActionLabel(.chooseAnotherFile),
            FailedStateView.primaryActionLabel(.chooseAnotherFile, door: .photos),
            FailedStateView.primaryActionLabel(.returnToEditor),
            FailedStateView.primaryActionLabel(.returnToResults),
        ]
        for wayBack in waysBack {
            #expect(examples.contains(.importBlockedOnThisScreen(wayBack: wayBack)), "\(wayBack)")
        }
    }

    @Test("No two messages share a sentence, except the refusal raised from two screens")
    func noTwoMessagesShareASentence() {
        var byText: [String: [MessageID]] = [:]
        for id in MessageID.examples {
            byText[MessageCatalog.row(for: id).text, default: []].append(id)
        }
        let shared = byText.values.filter { $0.count > 1 }
        #expect(shared.count == 1)
        #expect(shared.first?.count == 2)
        let pair: Set<MessageID.Name> = Set((shared.first ?? []).map(\.name))
        #expect(pair == [.applyOrClearSelectedMatchesBeforeRedact, .applyOrClearSelectedMatchesBeforeVerify])
    }

    @Test("A receipt is at most 75 characters, except the reclaimed-output message and the unsupported-format refusal")
    func receiptsAreShort() {
        let exceptions: Set<MessageID.Name> = [.outputReclaimed, .unsupportedFormatDropped]
        for id in MessageID.examples where MessageCatalog.row(for: id).kind == .receipt {
            let length = MessageCatalog.row(for: id).text.count
            if exceptions.contains(id.name) {
                #expect(length > 75, "\(id) is no longer an exception")
            } else {
                #expect(length <= 75, "\(id) is \(length) characters")
            }
        }
    }

    // MARK: - Posting

    @Test("Posting a row shows today's toast")
    func postingShowsTodaysToast() {
        for id in MessageID.examples {
            let row = MessageCatalog.row(for: id)
            let queue = ToastQueueManager()
            var action: (@MainActor () -> Void)?
            if row.actionLabel != nil { action = {} }
            queue.post(id, action: action)
            #expect(queue.activeToasts.count == 1, "\(id)")
            guard let toast = queue.activeToasts.first else { continue }
            #expect(toast.message == row.text, "\(id)")
            #expect(toast.severity == row.todaySeverity, "\(id)")
            #expect(queue.activeToasts.map(\.id) == [toast.id], "\(id)")
            #expect(toast.actionLabel == row.actionLabel, "\(id)")
            #expect((toast.actionHandler != nil) == (row.actionLabel != nil), "\(id)")
            queue.clearAll()
        }
    }

    @Test("Posting an action row with no action shows today's bare hook")
    func actionRowWithoutAction() throws {
        let queue = ToastQueueManager()
        queue.post(.outputReclaimed)
        let toast = try #require(queue.activeToasts.first)
        #expect(queue.activeToasts.count == 1)
        #expect(toast.message == DocumentEditorView.purgeRerunToastMessage)
        #expect(toast.severity == .warning)
        #expect(toast.actionLabel == nil)
        #expect(toast.actionHandler == nil)
        queue.clearAll()
    }

    @Test("An action given to a row without a label adds no button")
    func actionOnARowWithoutALabel() throws {
        let queue = ToastQueueManager()
        queue.post(.shared, action: {})
        let toast = try #require(queue.activeToasts.first)
        #expect(toast.message == DocumentEditorView.sharedAcknowledgmentToast)
        #expect(toast.actionLabel == nil)
        #expect(toast.actionHandler == nil)
        queue.clearAll()
    }

    // MARK: - The sources

    @Test("Only the queue builds toasts")
    func onlyTheQueueBuildsToasts() throws {
        let sources = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
        let files = try #require(FileManager.default.enumerator(atPath: sources.path))
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
        #expect(files.count > 100, "the source tree was not found")
        var builders: [String] = []
        for file in files where (file as NSString).lastPathComponent != "ToastQueueManager.swift" {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if code.contains(".enqueue(") || code.contains("ToastItem(") {
                    builders.append("\(file):\(index + 1)")
                }
            }
        }
        #expect(builders.isEmpty, "a toast built outside the queue: \(builders)")
    }

    // MARK: - The DEBUG hook

    @Test("Each message name parses from --showToast=", arguments: MessageCatalogTests.messageNames)
    func messageNameParses(name: String) {
        guard case .named(let parsed) = ResectaApp.toastHook(for: ["--showToast=\(name)"]) else {
            Issue.record("\(name) did not parse")
            return
        }
        #expect(parsed.rawValue == name)
        #expect(MessageID.example(named: parsed).name == parsed)
    }

    @Test("The hook takes the table's 29 names")
    func hookTakesEveryName() {
        #expect(Self.messageNames.count == 29)
        #expect(Set(Self.messageNames) == Set(MessageID.Name.allCases.map(\.rawValue)))
    }
}
