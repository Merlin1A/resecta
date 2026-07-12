import PDFKit

// ENGINE §5A — Text layer detection and per-page fallback triggers.
// Determines whether Searchable Redaction is available per page.

/// Stateless text layer detector. Analyzes PDF pages at import time
/// to classify text layer status and detect conditions that require
/// per-page fallback from Searchable Redaction to Secure Rasterization.
public enum TextLayerDetector {

    // MARK: - Text Layer Status Detection (ENGINE §5A)

    /// Classify a page's text layer as .rich, .sparse, or .none.
    /// - .rich: Substantial text layer — sandwich candidate.
    /// - .sparse: Fewer than 10 meaningful characters — treat as image-only.
    /// - .none: No text at all (includes whitespace-only layers per Experiment M4).
    public static func detectTextLayer(_ page: PDFPage) -> TextLayerStatus {
        let charCount = page.numberOfCharacters
        guard charCount > 0 else { return .none }
        guard let text = page.string else { return .none }

        let meaningful = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if meaningful.count < 10 { return .sparse }
        return .rich
    }

    // MARK: - Fallback Trigger Detection (ENGINE §5A)

    /// Check whether a page requires fallback from Searchable Redaction
    /// to Secure Rasterization. Returns a FallbackReason if fallback is
    /// needed, nil if the page can proceed with Searchable Redaction.
    ///
    /// Called after detectTextLayer() returns .rich.
    public static func checkFallbackTriggers(_ page: PDFPage) -> FallbackReason? {
        guard let text = page.string, !text.isEmpty else {
            return .noExtractableText
        }

        // CJK encoding failure: >1% U+FFFD in extracted text
        // ENGINE §5A: M5 confirmed threshold validated at 0%, 1%, 5%, 6%, 50%.
        // Tightened from 5% to 1% — at 5%, up to 95% of CJK text could survive
        // in the text layer. 1% is the safe direction (over-redacts, never under).
        let replacementCount = text.unicodeScalars.filter { $0 == "\u{FFFD}" }.count
        let totalScalars = text.unicodeScalars.count
        if totalScalars > 0 {
            let ratio = Double(replacementCount) / Double(totalScalars)
            if ratio > 0.01 {
                return .cjkEncodingFailure
            }
        }

        // RTL text: Arabic U+0600–06FF, Hebrew U+0590–05FF
        // ENGINE §5A: M5 confirmed correct identification
        if containsRTLText(text) {
            return .rtlText
        }

        // Vertical text mode: WMode=1 in page fonts
        if hasVerticalWritingMode(page) {
            return .verticalText
        }

        // Zero-size bounds: all PDFSelection.bounds return .zero
        if allSelectionBoundsAreZero(page) {
            return .zeroSizeBounds
        }

        // Character diversity floor for custom/unresolvable encoding
        // (absolute distinct-character count; see hasLowCharacterDiversity)
        if hasLowCharacterDiversity(text) {
            return .unresolvedEncoding
        }

        return nil
    }

    /// Reasons a page falls back from Searchable Redaction to Secure Rasterization.
    public enum FallbackReason: Sendable {
        case noExtractableText
        case cjkEncodingFailure
        case rtlText
        case verticalText
        case zeroSizeBounds
        case unresolvedEncoding
        /// Runtime text extraction threw (e.g., the OCG defense) — recorded
        /// by PageRasterizer, never returned by the pre-flight trigger check.
        case extractionFailed
    }

    // MARK: - Private Helpers

    /// Check for RTL script blocks (Arabic U+0600–06FF, Hebrew U+0590–05FF).
    private static func containsRTLText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            // Arabic block
            if scalar.value >= 0x0600 && scalar.value <= 0x06FF { return true }
            // Hebrew block
            if scalar.value >= 0x0590 && scalar.value <= 0x05FF { return true }
            // Arabic Supplement
            if scalar.value >= 0x0750 && scalar.value <= 0x077F { return true }
            // Arabic Extended-A
            if scalar.value >= 0x08A0 && scalar.value <= 0x08FF { return true }
            // Arabic Presentation Forms
            if scalar.value >= 0xFB50 && scalar.value <= 0xFDFF { return true }
            if scalar.value >= 0xFE70 && scalar.value <= 0xFEFF { return true }
        }
        return false
    }

    /// Check for vertical writing mode (WMode=1) in page fonts.
    /// ENGINE §5A: Horizontal Td positioning model does not apply to vertical text.
    private static func hasVerticalWritingMode(_ page: PDFPage) -> Bool {
        guard let pageRef = page.pageRef,
              let dict = pageRef.dictionary else { return false }

        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
              let res = resources else { return false }

        var fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "Font", &fonts),
              let fontDict = fonts else { return false }

        var foundVertical = false
        CGPDFDictionaryApplyBlock(fontDict, { _, value, ctx in
            var fontObj: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(value, .dictionary, &fontObj),
                  let font = fontObj else { return true }

            // Check /DescendantFonts for CIDFont WMode
            var descendantArray: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(font, "DescendantFonts", &descendantArray),
               let descendants = descendantArray {
                let count = CGPDFArrayGetCount(descendants)
                for i in 0..<count {
                    var cidFont: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(descendants, i, &cidFont),
                       let cid = cidFont {
                        var wmode: CGPDFInteger = 0
                        if CGPDFDictionaryGetInteger(cid, "WMode", &wmode),
                           wmode == 1 {
                            let ctxPtr = ctx!.assumingMemoryBound(to: Bool.self)
                            ctxPtr.pointee = true
                            return false // stop iteration
                        }
                    }
                }
            }
            return true
        }, &foundVertical)

        return foundVertical
    }

    /// Check if all PDFSelection bounds are zero-size (unusable bounding box data).
    /// ENGINE §5A: Extraction produces zero-size bounds.
    private static func allSelectionBoundsAreZero(_ page: PDFPage) -> Bool {
        let charCount = page.numberOfCharacters
        guard charCount > 0 else { return true }

        // Sample up to 10 characters across the page
        let sampleCount = min(charCount, 10)
        let step = max(charCount / sampleCount, 1)
        var allZero = true

        for i in stride(from: 0, to: charCount, by: step) {
            let range = NSRange(location: i, length: 1)
            if let sel = page.selection(for: range) {
                let bounds = sel.bounds(for: page)
                if bounds.width > 0 && bounds.height > 0 {
                    allZero = false
                    break
                }
            }
        }
        return allZero
    }

    /// Check for low character diversity — possible custom/unresolvable encoding.
    ///
    /// Absolute floor on the DISTINCT-character count. The populations this
    /// check separates do not overlap: repeated-glyph extraction failures
    /// (the check's target) yield ~2–5 distinct characters at any length,
    /// digit-heavy tables reach ~14+, and natural-language text saturates
    /// around ~70. A ratio against total length cannot separate them — the
    /// distinct set stops growing while the total keeps climbing, so any
    /// fixed ratio eventually classifies every long normal page as
    /// low-diversity (PD-5 part 1).
    private static func hasLowCharacterDiversity(_ text: String) -> Bool {
        let meaningful = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard meaningful.count >= 50 else { return false } // Too short to assess

        let uniqueChars = Set(meaningful)
        return uniqueChars.count < 10
    }
}
