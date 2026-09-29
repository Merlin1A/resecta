import SwiftUI
import PDFKit
import RedactionEngine

// Post-redaction preview: read-only PDFView of the redacted output.
// Shown in the "Preview" tab of VerificationResultsView.
//
// `PDFDocument(url:)` is CPU-bound
// on multi-hundred-page outputs and previously ran inside `makeUIView` on
// MainActor, stuttering the sheet transition. The parse now runs via
// `Task.detached` (mirrors the shape used by
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
        // This is small `.caption` TEXT (plus its 12%
        // wash background riding the same variable, mirroring
        // ToastSeverity's text/fill pairing), not a glyph — routed
        // through the WCAG-AA text tier rather than `.color`'s system
        // hues.
        let tint = verdict?.textColor ?? .secondary
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, ResectaTokens.Spacing.sm)
            .padding(.vertical, ResectaTokens.Spacing.xxs)
            .background(tint.opacity(0.12), in: Capsule())
            .accessibilityIdentifier("previewVerdictCapsule")
            .accessibilityLabel(text)
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

/// The preview's link policy — the editor's discipline
/// (`PDFViewCoordinator`) on the read-only output view: installed as the
/// view's delegate before any document is assigned (PDFKit follows link
/// annotations itself without one), and the data detectors turned off
/// after every assignment (the switch lives on the document, so each
/// newly assigned output arrives with PDFKit's default). In Searchable
/// mode the output carries a text layer; a residual number or URL in it
/// must not become a live link on the surface meant for checking it.
final class RedactedPreviewLinkPolicy: NSObject, PDFViewDelegate {

    /// Installs this policy as the view's delegate.
    func applyLinkPolicy(to pdfView: PDFView) {
        pdfView.delegate = self
    }

    /// Assigns the document to the view and turns data detectors off for
    /// it. Both `RedactedPDFView` assignment sites route through here.
    func assign(_ document: PDFDocument?, to pdfView: PDFView) {
        pdfView.document = document
        pdfView.enableDataDetectors = false
    }

    /// Link annotations in the output are not followed: the app opens no
    /// URL from document content. Intentionally empty, touches no state.
    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
    }
}

private struct RedactedPDFView: UIViewRepresentable {
    let document: PDFDocument

    func makeCoordinator() -> RedactedPreviewLinkPolicy {
        RedactedPreviewLinkPolicy()
    }

    func makeUIView(context: Context) -> FitFlooredPDFView {
        // The same zoom floor as the editor — a pinch
        // out stops at fit width here (continuous mode).
        let pdfView = FitFlooredPDFView()
        pdfView.autoScales = true
        // Deliberately NOT aligned to the editor's
        // `.singlePage`: the preview is a read-only whole-document
        // verification surface with no page-navigation chrome —
        // continuous is the only mode that keeps every page reachable
        // without new controls. The editor's `.singlePage` exists for
        // overlay-geometry alignment, a constraint the preview does
        // not carry.
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .systemGroupedBackground
        // The delegate first, then the document through the policy so the
        // detectors are off for it (see `RedactedPreviewLinkPolicy`).
        context.coordinator.applyLinkPolicy(to: pdfView)
        context.coordinator.assign(document, to: pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: FitFlooredPDFView, context: Context) {
        // Swap the document if the parent reloaded a different one
        // (e.g., the user re-redacted and `outputURL` changed).
        if pdfView.document !== document {
            context.coordinator.assign(document, to: pdfView)
        }
    }
}
