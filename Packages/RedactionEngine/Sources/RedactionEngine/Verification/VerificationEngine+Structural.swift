import Foundation
import PDFKit
import Vision
import ImageIO
#if canImport(UIKit)
import UIKit  // PDFPage.thumbnail(of:for:) returns UIImage
#else
import AppKit  // macOS tooling destination: thumbnail returns NSImage
#endif

extension VerificationEngine {
    // MARK: - Layer 4: Structural Verification

    /// Returns (status, affectedPages) where affectedPages is non-nil
    /// only for per-page /AA findings (enables tappable page chips in UI).
    func runLayer4Structural(_ doc: PDFDocument) throws -> (VerificationStatus, [Int]?, Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        let loaded = loadPDFData(doc)
        // /Encrypt is a trailer key, never the catalog's: an encrypted output FAILs, locked or not.
        if let cgDoc = loaded?.1, cgDoc.isEncrypted { return (.fail("Encrypt found in document"), nil, false) }
        guard let (pdfData, cgDoc) = loaded, let catalog = cgDoc.catalog else {
            return (.warn("Could not inspect document structure"), nil, true)
        }

        // FAIL-triggering keys: active content in the document catalog. /AA
        // triggers automatic actions (can execute JS on open/close/print);
        // /RichMedia and /Flash can embed content containing PII.
        let failKeys = ["JavaScript", "JS", "OpenAction", "Launch",
                        "EmbeddedFiles", "SubmitForm", "ResetForm", "AcroForm",
                        "AA", "RichMedia", "Flash"]
        for key in failKeys {
            var obj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog, key, &obj) {
                return (.fail("\(key) found in document catalog"), nil, false)
            }
        }

        // The standard real-world carrier for embedded files and
        // document-level JavaScript is the catalog's /Names name-dictionary
        // (/Names → /EmbeddedFiles, /Names → /JavaScript), not the catalog top
        // level the loop above covers. Resecta's writer never emits /Names, so
        // these subtrees are active-content carriers wherever they appear; a
        // plain /Names without them stays on the generic WARN path below.
        var namesDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &namesDict), let namesDict {
            for key in ["EmbeddedFiles", "JavaScript"] {
                var subtree: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(namesDict, key, &subtree) {
                    return (.fail("\(key) found under /Names in document catalog"), nil, false)
                }
            }
        }

        // Check per-page /AA entries. Page-level automatic actions
        // can trigger JavaScript or URI opens that leak document content.
        // Collects all affected pages for tappable navigation in the UI.
        let pageCount = cgDoc.numberOfPages
        var aaPages: [Int] = []
        for pageIdx in 1...max(1, pageCount) {
            try Task.checkCancellation()
            guard let pageDictRef = cgDoc.page(at: pageIdx)?.dictionary else { continue }
            var aaObj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(pageDictRef, "AA", &aaObj) {
                aaPages.append(pageIdx - 1)  // 0-indexed for UI (LayerResultRow shows pageRef + 1)
            }
        }
        if !aaPages.isEmpty {
            return (.fail("Per-page /AA (automatic action) found on \(pageCountPhrase(aaPages.count))"), aaPages, false)
        }

        // WARN-triggering keys
        let warnKeys = ["URI", "Metadata", "Names",
                        "OCProperties", "PieceInfo"]
        var warnings: [String] = []
        for key in warnKeys {
            var obj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog, key, &obj) {
                warnings.append(key)
            }
        }

        // Check for multiple %%EOF markers (incremental updates).
        // pdfData already read into memory by loadPDFData.
        let eofMarker = "%%EOF".data(using: .ascii)!
        var eofCount = 0
        var searchRange = pdfData.startIndex..<pdfData.endIndex
        while let range = pdfData.range(of: eofMarker, options: [], in: searchRange) {
            eofCount += 1
            searchRange = range.upperBound..<pdfData.endIndex
        }
        if eofCount > 1 {
            // Incremental updates can append original content
            // after redaction. Resecta's reconstructor writes a single clean
            // PDF stream — multiple markers indicate tampering or corruption.
            return (.fail("Multiple %%EOF markers (\(eofCount)) — incremental update may contain original content"), nil, false)
        }

        if !warnings.isEmpty {
            return (.warn("Structural findings: \(warnings.joined(separator: ", "))"), nil, false)  // LegalPhrases:safe (the shipped message; a list of structural notes)
        }
        return (.pass, nil, false)
    }

    // MARK: - Layer 5: Metadata Verification

    /// The fixed-fields PASS detail: the writer's own values, nothing of the
    /// file's, are what the /Info dictionary carries.
    static let layer5FixedFieldsDetail =
        "Producer and timestamps carry the writer's fixed values; no file-specific metadata is present."

    func runLayer5Metadata(_ doc: PDFDocument) throws -> (VerificationStatus, Bool, LayerCopy?) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        guard let (pdfData, cgDoc) = loadPDFData(doc) else {
            return (.warn("Could not inspect metadata"), true, nil)
        }

        // Scan for XMP metadata BEFORE the /Info guard. XMP lives in
        // the document's /Metadata stream, independent of /Info; the prior
        // early `return .pass` on a nil /Info dictionary skipped the XMP scan
        // entirely, so a document carrying XMP but no /Info passed silently.
        // pdfData already read into memory by loadPDFData.
        let hasXMP = pdfData.range(of: "<?xpacket".data(using: .ascii)!) != nil
            || pdfData.range(of: "<x:xmpmeta>".data(using: .ascii)!) != nil
            || pdfData.range(of: "<rdf:RDF".data(using: .ascii)!) != nil

        // Check /Info dictionary. When absent, the XMP scan above is still
        // authoritative — surface it rather than passing blind.
        guard let infoDict = cgDoc.info else {
            return (hasXMP
                ? .warn("Auto-injected metadata present: XMP metadata")
                : .pass, false, nil)
        }

        // Standard metadata keys to check. FAIL on key presence regardless of
        // value type or decode success. The prior GetString/GetName pair
        // silently passed keys whose value was an integer, array, or boolean
        // (e.g. `/Title 42`), contradicting the documented intent. A single
        // CGPDFDictionaryGetObject presence check fires on ANY value type
        // (string, name, integer, array, boolean) — bytes that don't decode under
        // PDFDocEncoding / UTF-16BE-BOM / UTF-8-BOM no longer fall through as
        // "absent," and Name-object values are covered without a second call.
        // CGPDFContext (Apple's writer) never emits these keys, so any presence
        // is suspicious.
        // Never include metadata values in status messages.
        let sensitiveKeys = ["Title", "Author", "Subject", "Keywords", "Creator"]
        for key in sensitiveKeys {
            var obj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(infoDict, key, &obj) {
                return (.fail("Metadata key /\(key) present"), false, nil)
            }
        }

        // /Producer, /CreationDate, /ModDate are Apple auto-injected and
        // rewritten to the writer's fixed values (attested below); they
        // ride in `infoFindings` so a clean doc with only these is a PASS
        // whose detail says so.
        var infoFindings: [String] = []
        var warnings: [String] = []
        let expectedKeys = ["Producer", "CreationDate", "ModDate"]
        for key in expectedKeys {
            var str: CGPDFStringRef?
            if CGPDFDictionaryGetString(infoDict, key, &str) {
                infoFindings.append("/\(key)")
            }
        }

        // Check for /Trapped (can reveal document workflow)
        var trappedStr: CGPDFStringRef?
        if CGPDFDictionaryGetString(infoDict, "Trapped", &trappedStr) {
            warnings.append("/Trapped")
        }
        // Also check as name object (PDF spec allows /Trapped as name)
        var trappedName: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(infoDict, "Trapped", &trappedName) {
            if !warnings.contains("/Trapped") {
                warnings.append("/Trapped")
            }
        }

        // Enumerate all /Info keys — FAIL on non-standard keys with content.
        // Custom metadata entries could contain PII transferred from the source
        // document (e.g., app-specific classification, document routing).
        let standardKeys: Set<String> = [
            "Title", "Author", "Subject", "Keywords", "Creator",
            "Producer", "CreationDate", "ModDate", "Trapped"
        ]
        var nonStandardKeys: [String] = []
        CGPDFDictionaryApplyBlock(infoDict, { key, _, _ in
            let keyName = String(cString: key)
            if !standardKeys.contains(keyName) {
                nonStandardKeys.append(keyName)
            }
            return true
        }, nil)
        if !nonStandardKeys.isEmpty {
            // Do not include key values — just names
            return (.fail("Non-standard /Info key(s): \(nonStandardKeys.joined(separator: ", "))"), false, nil)
        }

        // Writer-field attestation. The writer rewrites the auto-injected
        // /Producer literal to `PDFStreamReconstructor.fixedProducerValue`
        // and the /CreationDate and /ModDate literals to
        // `PDFStreamReconstructor.fixedDateValue` after the context closes;
        // that rewrite leaves a literal untouched on any anomaly and only
        // logs. Read the three values back here so a silent no-op (or a
        // future writer change) is reported instead of passing as
        // auto-injected metadata. The producer rewrite pads with spaces
        // after the closing paren, so the decoded literal is the bare fixed
        // value; trailing spaces inside a literal are tolerated. A value
        // that does not decode counts as not rewritten. An absent key stays
        // on the paths below. One message covers all three fields; never
        // echo a value in it.
        let fixedWriterFields = [
            ("Producer", PDFStreamReconstructor.fixedProducerValue),
            ("CreationDate", PDFStreamReconstructor.fixedDateValue),
            ("ModDate", PDFStreamReconstructor.fixedDateValue),
        ]
        for (key, fixedValue) in fixedWriterFields {
            var ref: CGPDFStringRef?
            guard CGPDFDictionaryGetString(infoDict, key, &ref), let ref else { continue }
            var value = (CGPDFStringCopyTextString(ref) as String?) ?? ""
            while value.hasSuffix(" ") { value.removeLast() }
            if value != fixedValue {
                return (.warn("Producer or timestamp fields were not rewritten to the fixed values"), false, nil)
            }
        }

        // File-identifier attestation. The writer rewrites both halves of
        // the trailer's `/ID` pair to the identifier derived from the
        // file's own bytes (`PDFFileIdentifier`); recompute it here and
        // report a pair that was not derived that way — after the fixed
        // fields, ahead of /Trapped and XMP, one message that never carries
        // a value. An absent pair stays on the paths below.
        if let idArray = cgDoc.fileIdentifier,
           !Self.fileIdentifierMatchesContents(idArray, pdfData: pdfData) {
            return (.warn("File identifier was not derived from the file contents"), false, nil)
        }

        // XMP metadata — scanned above the /Info guard; fold the
        // result into the warnings here for the /Info-present message path.
        if hasXMP {
            warnings.append("XMP metadata")
        }

        if !warnings.isEmpty {
            // Mixed case: real concern present. Drop infoFindings from the
            // message — auto-injected metadata is implicit when /Trapped or
            // XMP exists, so surfacing only the actionable subset keeps the
            // user focused on what matters. /Trapped is workflow-set, not
            // auto-injected, so the message only claims auto-injection when
            // XMP is the sole entry.
            let onlyXMP = warnings.allSatisfy { $0 == "XMP metadata" }
            let prefix = onlyXMP ? "Auto-injected metadata present" : "Metadata present"
            return (.warn("\(prefix): \(warnings.joined(separator: ", "))"), false, nil)
        }
        if !infoFindings.isEmpty {
            // The three keys are always present by construction and were
            // attested above: a PASS that says what it read, never a note.
            return (.pass, false, LayerCopy(short: "No issues found.", detail: Self.layer5FixedFieldsDetail))
        }
        return (.pass, false, nil)
    }

    /// True when the two strings of a trailer `/ID` array both equal the
    /// identifier recomputed from `pdfData`. An array that is not two
    /// strings, or a pair the locator cannot read from the file's tail in
    /// the writer's shape, is by construction not the writer's derived
    /// value.
    static func fileIdentifierMatchesContents(_ idArray: CGPDFArrayRef, pdfData: Data) -> Bool {
        guard CGPDFArrayGetCount(idArray) == 2 else { return false }
        var halves: [Data] = []
        for index in 0..<2 {
            var ref: CGPDFStringRef?
            guard CGPDFArrayGetString(idArray, index, &ref), let ref,
                  let bytes = CGPDFStringGetBytePtr(ref) else { return false }
            halves.append(Data(bytes: bytes, count: CGPDFStringGetLength(ref)))
        }
        guard let expected = PDFFileIdentifier.recomputedIdentifier(for: pdfData) else { return false }
        return halves[0] == expected && halves[1] == expected
    }
}
