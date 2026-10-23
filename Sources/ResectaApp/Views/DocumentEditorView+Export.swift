import SwiftUI
import UIKit
import StoreKit
import RedactionEngine

// The export flow, moved out of `DocumentEditorView.swift` (the hub) along
// its `// MARK: - Export` and `// MARK: - Post-share acknowledgment` seams:
// the Share gate and the two facts behind it, the Share tap's route through
// the share-risk confirm, and the export itself (the share copy, the share
// sheet and its completion). The flow is a type the hub builds with its
// environment and two bindings, the confirm's kind and the concealed pages
// read at the Share tap; the hub's results screen and the confirm
// presentation call it. The post-share statics stay on `DocumentEditorView`,
// where the tests read them.

extension DocumentEditorView {

    // MARK: - Post-share acknowledgment + re-arm

    /// Toast enqueued when the share sheet reports the document was
    /// actually sent (`completed == true`) — confirms the app's own action
    /// (handing the file to the share sheet) went through, without naming
    /// which destination the user chose. Never enqueued on cancel — see
    /// `handleShareSheetCompletion`.
    static let sharedAcknowledgmentToast = "Shared."

    /// The share sheet's `completionWithItemsHandler`
    /// routes through this pure static so the re-arm / announce /
    /// record-export decision is unit-testable without
    /// `UIActivityViewController`. `completed == false` means the user
    /// backed out of the sheet without sending — the share-risk confirms
    /// are spent only for a send that actually happened, so a cancelled
    /// attempt re-arms all three (`DocumentState.rearmShareRiskConfirms()`)
    /// for the next Share tap on the same report. `completed ==
    /// true` announces the share and then records it — the App Store
    /// review-request check (`ReviewPromptGate`) — leaving the confirms spent
    /// for this report; a fresh report re-arms via `transition(to:)`'s
    /// reset instead of this function.
    static func handleShareSheetCompletion(
        completed: Bool,
        documentState: DocumentState,
        announceShared: () -> Void,
        recordSuccessfulExport: () -> Void
    ) {
        guard completed else {
            documentState.rearmShareRiskConfirms()
            return
        }
        announceShared()
        recordSuccessfulExport()
    }
}

/// The editor's export flow. Built by `DocumentEditorView.exportFlow` from
/// the hub's environment and its two share-confirm states.
struct DocumentEditorExportFlow {
    let documentState: DocumentState
    let redactionState: RedactionState
    let coordinator: PipelineCoordinator
    let toastManager: ToastQueueManager
    let requestReview: RequestReviewAction
    @Binding var shareRiskConfirmKind: ShareRiskConfirmKind?
    @Binding var shareConcealedPages: [Int]

    // Defense-in-depth export gate. Lifted from
    // VerificationActionBar so the bar and the Phase 2 action card share
    // one source of truth.
    func canExport(report: VerificationReport) -> Bool {
        // FAIL override / "Option B": a standing FAIL no longer disables
        // the Share card — it stays enabled (red-tinted via
        // VerificationResultsView.shouldTintShareRed(report:)) and routes through the
        // one-time "Share Anyway" confirm in handleExportTap. Enablement now
        // depends only on a fresh, valid output existing on disk. (`report` is
        // retained in the signature so the call site and gate seam stay stable.)
        guard let url = redactionState.outputURL,
              FileManager.default.fileExists(atPath: url.path),
              !redactionState.isVerificationStale
        else { return false }
        return true
    }

    /// A redacted output file exists on disk — one of the two facts behind
    /// `canExport`, threaded into VerificationResultsView separately so the
    /// disabled Share card's caption (`shareDisabledReason`) can name the
    /// actual cause.
    var outputFileExists: Bool {
        guard let url = redactionState.outputURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Preview availability for VerificationResultsView: a redacted output file
    /// exists on disk. Deliberately NOT folded into `canExport` (which also
    /// requires !isVerificationStale for the *Share* affordance) — Preview is a
    /// read-only view of whatever output exists, and RedactedPreviewView
    /// re-validates the URL itself (RedactedPreviewView.swift:35-36), so a stale
    /// or absent URL degrades to ContentUnavailableView rather than crashing.
    var previewAvailable: Bool { outputFileExists }

    func handleExportTap(report: VerificationReport) {
        shareConcealedPages = ConcealingAnnotations.pages(in: documentState.sourceDocument, regions: redactionState.regions, textLayerStatus: documentState.textLayerStatus)
        if let kind = DocumentEditorView.shareConfirmKind(report: report, documentState: documentState, concealedPages: shareConcealedPages) {
            shareRiskConfirmKind = kind
            return
        }
        beginExport(report: report)
    }

    // DateFormatter is expensive to create; reuse a static instance.
    private static let exportFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    func beginExport(report: VerificationReport) {
        guard let outputURL = redactionState.outputURL,
              FileManager.default.fileExists(atPath: outputURL.path)
        else {
            // KI-4: File purged while backgrounded
            redactionState.outputURL = nil
            DocumentEditorView.failExportForPurgedOutput(documentState: documentState)
            return
        }

        documentState.transition(to: .exporting)

        // Timestamped filename, no original name (could be sensitive)
        let exportName = "redacted_\(Self.exportFormatter.string(from: Date())).pdf"
        // Place the share-export copy inside the per-session
        // backup-excluded subdirectory so the user-facing filename surfaces
        // in the share sheet from the same protected location as the
        // pipeline output.
        let exportURL: URL
        do {
            exportURL = try coordinator.tempExportDirectory.childURL(named: exportName)
        } catch { // LegalPhrases:safe
            documentState.transition(to: .failed(
                error: .exportError(.writeFailed),
                returnPhase: .verified(report: report)
            ))
            return
        }

        do {
            try FileManager.default.copyItem(at: outputURL, to: exportURL)
        } catch {
            documentState.transition(to: .failed(
                error: .exportError(.writeFailed),
                returnPhase: .verified(report: report)
            ))
            return
        }

        // Apply `.complete` protection to the export copy. The
        // session is still live (user is sharing now). Best-effort —
        // failures are non-fatal but logged via the system trace if any.
        try? TempFileHardening.applyProtection(exportURL, level: .complete)

        let activityVC = UIActivityViewController(
            activityItems: [exportURL],
            applicationActivities: nil
        )

        // Capture report for return transition
        let currentReport = report
        activityVC.completionWithItemsHandler = { _, completed, _, _ in
            try? FileManager.default.removeItem(at: exportURL)
            documentState.transition(to: .verified(report: currentReport))
            // Order matters: the transition above restores the
            // captured report onto `.verified` FIRST, then re-arm/announce
            // reads or mutates that live phase.
            DocumentEditorView.handleShareSheetCompletion(
                completed: completed,
                documentState: documentState,
                announceShared: {
                    toastManager.enqueue(
                        DocumentEditorView.sharedAcknowledgmentToast,
                        severity: .success)
                },
                recordSuccessfulExport: {
                    if ReviewPromptGate.standard.shouldAsk(afterSharing: currentReport.overallStatus) {
                        Task { @MainActor in requestReview() }
                    }
                }
            )
        }

        // `connectedScenes` is an unordered Set; `.first as? UIWindowScene`
        // can resolve to a non-foreground scene whose `keyWindow` is nil,
        // in which case the share sheet never presents and the editor is
        // stranded on `.exporting` (the PipelineProgressCard overlay).
        // Use the same foreground-active filter as the audit/verification-
        // report share paths.
        guard let topVC = MatchExportService.topViewController() else {
            try? FileManager.default.removeItem(at: exportURL)
            documentState.transition(to: .verified(report: currentReport))
            // The share sheet never presented, so no send
            // happened — re-arm exactly as a cancelled share would.
            DocumentEditorView.handleShareSheetCompletion(
                completed: false,
                documentState: documentState,
                announceShared: {},
                recordSuccessfulExport: {}
            )
            toastManager.enqueue(
                "Unable to present the share sheet right now.",
                severity: .warning
            )
            return
        }
        activityVC.popoverPresentationController?.sourceView = topVC.view
        topVC.present(activityVC, animated: true)
    }
}
