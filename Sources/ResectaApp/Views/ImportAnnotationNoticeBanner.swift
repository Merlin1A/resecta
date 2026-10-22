import SwiftUI
import PDFKit
import CoreGraphics
import RedactionEngine

// Import-time notice for source annotations, filled form fields, XFA form
// data and embedded files. The on-screen PDFKit view draws a document's
// annotations and its form-field values; the export raster is built from
// the page content stream, which includes neither, and the rebuilt file
// carries no XFA packet and no attachment. When the imported source carries
// a non-Widget annotation whose subtype can sit over page content, a form
// field that carries a value, or XFA form data or an embedded file, this
// banner names that mechanism so the user can check the preview before
// sharing. One surface for all of them: the paragraph grows a sentence, it
// never becomes a second notice.
//
// A sibling of `InlineWarningBanner` rather than a reuse: the mechanism
// copy is a full paragraph, and the shared banner's 2-line cap (3 at
// AX5) would truncate it. Same visual grammar — warning triangle,
// tinted card, icon-only dismiss.
//
// Copy is mechanism-description only: it states what
// the app builds and what the export contains, never an outcome promise.

struct ImportAnnotationNoticeBanner: View {
    /// Notice-worthy findings in the source (`noticeWorthyCount`): the
    /// annotation subtypes, plus the document-level entry for XFA form
    /// data or embedded files when the loader staged one.
    let annotationCount: Int
    /// Form fields in the source that carry a value (`filledFormFieldCount(in:)`).
    let filledFormFieldCount: Int
    let onDismiss: () -> Void

    /// Mechanism copy for a source with annotations and no filled form
    /// fields, exposed for the unit pin. The banner does not enumerate
    /// annotation subtypes; the count and kinds do not change what the
    /// user should do (check the preview).
    static let noticeMessage = "\(annotationSentences) \(checkPreviewSentence)"

    private static let annotationSentences = "This document contains annotations such as boxes, stamps, or notes. Annotations are not part of the page image, so the exported file is built without them, and page content beneath them is included in the export."
    private static let checkPreviewSentence = "Check the preview before sharing."

    /// The sentence for XFA form data and embedded files: the viewer may
    /// draw the one and list the other; the rebuilt output carries neither.
    nonisolated static let formDataOrAttachmentsSentence = "Form data and attachments are not carried into the redacted copy."

    /// The id of the document-level entry the import loader stages beside
    /// the analyzer's annotation findings when `carriesFormDataOrAttachments`
    /// reads true. It counts toward `noticeWorthyCount` (so the banner
    /// mounts) and the banner reads it back out of the staged findings for
    /// its sentence.
    nonisolated static let formDataOrAttachmentsFindingID = "document-form-data-or-attachments"

    /// The one paragraph the banner shows: the annotation sentences when
    /// the source carries notice-worthy annotations, the form-field
    /// sentence when it carries filled fields, the form-data-and-attachments
    /// sentence when it carries XFA form data or an embedded file, every
    /// sentence that applies, then the preview sentence. Empty when none
    /// applies (the banner is not mounted then — `isVisible`).
    static func noticeMessage(
        annotationCount: Int, filledFormFieldCount: Int,
        carriesFormDataOrAttachments: Bool = false
    ) -> String {
        var sentences: [String] = []
        if annotationCount > 0 {
            sentences.append(annotationSentences)
        }
        if filledFormFieldCount > 0 {
            sentences.append(formFieldSentence(count: filledFormFieldCount,
                                               leading: annotationCount == 0))
        }
        if carriesFormDataOrAttachments {
            sentences.append(formDataOrAttachmentsSentence)
        }
        guard !sentences.isEmpty else { return "" }
        sentences.append(checkPreviewSentence)
        return sentences.joined(separator: " ")
    }

    /// Whether the source's catalog carries `/AcroForm /XFA` (XFA form data)
    /// or `/Names → /EmbeddedFiles` (attachments), read from the CoreGraphics
    /// document behind the PDFKit one — the reader the import walks inspect.
    /// A document with no readable reader answers false: the walk reader
    /// stage has already refused a document whose catalog cannot be read.
    nonisolated static func carriesFormDataOrAttachments(in document: PDFDocument) -> Bool {
        guard let catalog = document.documentRef?.catalog else { return false }
        var acroForm: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm {
            var xfa: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(acroForm, "XFA", &xfa) { return true }
        }
        var names: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names {
            var embedded: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(names, "EmbeddedFiles", &embedded) { return true }
        }
        return false
    }

    /// The staged entries carry the document-level one.
    nonisolated static func carriesFormDataOrAttachments(_ findings: [PDFFinding]) -> Bool {
        findings.contains { $0.id == formDataOrAttachmentsFindingID }
    }

    /// "N filled form fields; their values are not carried into the
    /// output." The viewer draws a field's value from the field
    /// dictionary; the export raster is built from the page content
    /// stream, which does not carry it. `leading` opens the paragraph;
    /// otherwise the sentence follows the annotation sentences.
    static func formFieldSentence(count: Int, leading: Bool) -> String {
        let subject = leading ? "This document contains" : "It also contains"
        return count == 1
            ? "\(subject) 1 filled form field; its value is not carried into the output."
            : "\(subject) \(count) filled form fields; their values are not carried into the output."
    }

    /// Widget annotations in the document whose field carries a value.
    /// `widgetStringValue` is PDFKit's read of the field's `/V`; a
    /// whitespace-only value and a button at its `Off` state do not
    /// count. Widgets are the one subtype `AnnotationAnalyzer` skips, so
    /// this walk is the notice's only read of them. Runs off the main
    /// actor at import, beside the analyzer.
    nonisolated static func filledFormFieldCount(in document: PDFDocument) -> Int {
        var count = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                if hasFieldValue(annotation) { count += 1 }
            }
        }
        return count
    }

    nonisolated private static func hasFieldValue(_ annotation: PDFAnnotation) -> Bool {
        let raw = annotation.widgetStringValue
            ?? (annotation.value(forAnnotationKey: .widgetValue) as? String)
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return false }
        return value != "Off" && value != "/Off"
    }

    /// Finding ids for annotation subtypes that draw nothing over page
    /// content, so their presence says nothing about what the export
    /// contains. A deny-list, not an allow-list: an unlisted subtype
    /// keeps firing (the posture fails toward warning — `Text` notes and
    /// `Highlight` can sit over page content, so they stay in).
    /// `AnnotationAnalyzer` ids are "annotation-<subtype.lowercased()>".
    static let nonConcealingFindingIDs: Set<String> = ["annotation-link", "annotation-popup"]

    /// The banner owns this policy; `DocumentState.sourceAnnotationFindings`
    /// stays the faithful record of everything the analyzer saw.
    static func noticeWorthyCount(_ findings: [PDFFinding]) -> Int {
        findings.filter { !nonConcealingFindingIDs.contains($0.id) }.count
    }

    /// Visibility contract, exposed as a static so unit tests can pin
    /// it without rendering the view: the notice shows while editing a
    /// document whose source carries annotations or filled form fields,
    /// until the user dismisses it, and yields to the two sibling
    /// top-edge banners (background-resume and detection-summary) rather
    /// than stacking over them — it returns once they clear because
    /// dismissal is the only terminal state.
    static func isVisible(
        phaseKind: DocumentState.PhaseKind,
        annotationTypeCount: Int,
        filledFormFieldCount: Int = 0,
        dismissed: Bool,
        pausedBannerActive: Bool,
        detectionBannerActive: Bool
    ) -> Bool {
        phaseKind == .editing
            && (annotationTypeCount > 0 || filledFormFieldCount > 0)
            && !dismissed
            && !pausedBannerActive
            && !detectionBannerActive
    }

    @Environment(DocumentState.self) private var documentState

    /// The paragraph for the staged record: `annotationCount` is the view's
    /// notice-worthy count, which includes the document-level entry when
    /// the loader staged one; the sentence for it is composed from the
    /// entry, not from that count.
    private var message: String {
        let findings = documentState.sourceAnnotationFindings
        let carries = Self.carriesFormDataOrAttachments(findings)
        return Self.noticeMessage(
            annotationCount: max(0, annotationCount - (carries ? 1 : 0)),
            filledFormFieldCount: filledFormFieldCount,
            carriesFormDataOrAttachments: carries)
    }

    var body: some View {
        HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("Dismiss", systemImage: "xmark.circle.fill") {
                onDismiss()
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
        }
        .padding(ResectaTokens.Spacing.sm)
        // Chained backgrounds stack behind what precedes them: the tint
        // stays on top of an opaque base so the document under the
        // banner cannot show through the card and overprint the copy.
        .background(ResectaTokens.SemanticColor.warningTint.opacity(0.12),
                    in: .rect(cornerRadius: ResectaTokens.CornerRadius.medium))
        .background(Color(.systemBackground),
                    in: .rect(cornerRadius: ResectaTokens.CornerRadius.medium))
        .padding(.horizontal, ResectaTokens.Spacing.md)
        // Container id + header trait mirror `InlineWarningBanner`; the
        // dismiss Button stays its own accessibility element so it is
        // individually hittable.
        .accessibilityIdentifier("importAnnotationNotice")
        .accessibilityAddTraits(.isHeader) // VoiceOver announces on appearance
    }
}
