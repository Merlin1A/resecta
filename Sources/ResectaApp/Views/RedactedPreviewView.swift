import SwiftUI
import PDFKit
import RedactionEngine

// Post-redaction preview: read-only PDFView of the redacted output.
// Shown in the "Preview" tab of VerificationResultsView.
//
// Package H (BUG-mainactor-pdf-preview). `PDFDocument(url:)` is CPU-bound
// on multi-hundred-page outputs and previously ran inside `makeUIView` on
// MainActor, stuttering the sheet transition. The parse now runs via
// `Task.detached` (mirrors the F-002 / pkg-f shape used by
// `PipelineCoordinator.runVerification`); the inner UIViewRepresentable
// receives the already-loaded `PDFDocument` and renders synchronously.

struct RedactedPreviewView: View {
    @Environment(RedactionState.self) private var redactionState

    /// The live report's overall verdict, threaded in by the
    /// presenting card (VerificationResultsView owns the report; this view
    /// deliberately does not). Preview availability stays decoupled from
    /// the verdict (#217) — reviewing a FAILed output is exactly what the
    /// user should do — but the viewer previously carried no in-context
    /// cue that the document on screen failed or skipped verification.
    /// Drives the nav-bar capsule; nil (the default) renders no capsule.
    var verdict: VerificationStatus? = nil

    @State private var loaded: LoadState = .pending

    private enum LoadState: Equatable {
        case pending
        case ready(PDFDocument)
        case failed

        static func == (lhs: LoadState, rhs: LoadState) -> Bool {
            switch (lhs, rhs) {
            case (.pending, .pending), (.failed, .failed): return true
            case (.ready(let a), .ready(let b)): return a === b
            default: return false
            }
        }
    }

    var body: some View {
        Group {
            if let url = redactionState.outputURL,
               FileManager.default.fileExists(atPath: url.path) {
                content
                    .task(id: url) {
                        loaded = .pending
                        let wrapped = await Task.detached(priority: .userInitiated) {
                            PDFDocument(url: url).map(SendablePDFDocument.init)
                        }.value
                        if let doc = wrapped?.document {
                            loaded = .ready(doc)
                        } else {
                            loaded = .failed
                        }
                    }
            } else {
                unavailable
            }
        }
        .toolbar {
            if let text = Self.verdictCapsuleText(verdict: verdict) {
                ToolbarItem(placement: .principal) {
                    verdictCapsule(text: text)
                }
            }
        }
    }

    // MARK: - Verdict capsule

    /// Capsule copy per verdict. FAIL and SKIPPED only — PASS/WARN/INFO
    /// previews stay chrome-free (nothing to warn about at this surface;
    /// WARN's notes live on the results screen the user just came from).
    /// Static so the verdict → copy mapping is unit-testable without a
    /// SwiftUI host (mirrors `VerificationResultsView.shouldAutoExpand`).
    static func verdictCapsuleText(verdict: VerificationStatus?) -> String? {
        guard let verdict else { return nil }
        if verdict.isFail { return "Issues Found — review before sharing" }
        if verdict.isAttention { return "Attention needed — review before sharing" }
        if verdict.isSkipped { return "Not verified" }
        return nil
    }

    @ViewBuilder
    private func verdictCapsule(text: String) -> some View {
        let tint = verdict?.color ?? .secondary
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, ResectaTokens.Spacing.sm)
            .padding(.vertical, ResectaTokens.Spacing.xxs)
            .background(tint.opacity(0.12), in: Capsule())
            .accessibilityIdentifier("previewVerdictCapsule")
    }

    @ViewBuilder
    private var content: some View {
        switch loaded {
        case .ready(let doc):
            RedactedPDFView(document: doc)
                .accessibilityIdentifier("redactedPreview")
        case .pending:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("redactedPreviewLoading")
        case .failed:
            unavailable
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Preview Unavailable",
            systemImage: "doc.questionmark",
            description: Text("The redacted file is no longer available.")
        )
    }
}

// MARK: - UIViewRepresentable Wrapper

private struct RedactedPDFView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        // SA-3 rider (c), deliberately NOT aligned to the editor's
        // `.singlePage`: the preview is a read-only whole-document
        // verification surface with no page-navigation chrome —
        // continuous is the only mode that keeps every page reachable
        // without new controls. The editor's `.singlePage` exists for
        // overlay-geometry alignment, a constraint the preview does
        // not carry.
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .systemGroupedBackground
        pdfView.document = document
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        // Swap the document if the parent reloaded a different one
        // (e.g., the user re-redacted and `outputURL` changed).
        if pdfView.document !== document {
            pdfView.document = document
        }
    }
}
