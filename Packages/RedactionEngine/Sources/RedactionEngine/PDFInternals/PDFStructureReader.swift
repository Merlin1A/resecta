import CoreGraphics
import Foundation
import PDFKit

// Low-level CGPDFDocument traversal for structural PDF analysis.
// ENGINE 6.4 (Layer 4 key sets) and 6.5 (Layer 5 key sets).
// Metadata (Layer 5): Read via PDFKit documentAttributes.
// Active content (Layer 4): Read via CGPDFDocument catalog (created internally from Data).
// Methods accept Data (Sendable) to avoid non-Sendable CGPDFDocument crossing boundaries.

/// Reads PDF structure via CoreGraphics and PDFKit APIs. Stateless, nonisolated struct.
public struct PDFStructureReader: Sendable {

    public init() {}

    // MARK: - Metadata (Layer 5 key sets)

    /// Read metadata from the PDF using PDFKit documentAttributes.
    /// Sensitive keys (.warning): /Title, /Author, /Subject, /Keywords, /Creator
    /// Expected keys (.info): /Producer, /CreationDate, /ModDate
    @concurrent
    public func readMetadata(from document: PDFDocument) async -> [PDFFinding] {
        var findings: [PDFFinding] = []

        let attrs = document.documentAttributes ?? [:]

        let sensitiveMap: [(PDFDocumentAttribute, String)] = [
            (.titleAttribute, "Title"),
            (.authorAttribute, "Author"),
            (.subjectAttribute, "Subject"),
            (.keywordsAttribute, "Keywords"),
            (.creatorAttribute, "Creator"),
        ]

        for (attr, key) in sensitiveMap {
            if let value = attrs[attr] {
                let displayValue = describeAttributeValue(value)
                findings.append(PDFFinding(
                    id: "metadata-\(key.lowercased())",
                    summary: "/\(key) metadata field is present",
                    detail: displayValue.map { "Value: \($0)" },
                    severity: .warning
                ))
            }
        }

        let expectedMap: [(PDFDocumentAttribute, String)] = [
            (.producerAttribute, "Producer"),
            (.creationDateAttribute, "CreationDate"),
            (.modificationDateAttribute, "ModDate"),
        ]

        for (attr, key) in expectedMap {
            if attrs[attr] != nil {
                findings.append(PDFFinding(
                    id: "metadata-\(key.lowercased())",
                    summary: "/\(key) metadata field is present",
                    severity: .info
                ))
            }
        }

        return findings
    }

    // MARK: - Active Content (Layer 4 key sets)

    /// Check catalog for dangerous keys. Creates CGPDFDocument internally from data.
    /// FAIL-level: /JavaScript, /JS, /OpenAction, /Launch, /SubmitForm, /ResetForm,
    ///   /AcroForm, /AA, /Encrypt, /RichMedia, /Flash, /EmbeddedFiles
    /// WARN-level: /URI, /Metadata, /Names, /PieceInfo
    @concurrent
    public func checkActiveContent(from data: Data) async -> [PDFFinding] {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let catalog = document.catalog else { return [] }

        var findings: [PDFFinding] = []

        let criticalKeys: [(String, String)] = [
            ("JavaScript", "JavaScript actions detected in document catalog"),
            ("JS", "JavaScript reference detected in document catalog"),
            ("OpenAction", "Automatic open action detected in document catalog"),
            ("Launch", "Launch action detected in document catalog"),
            ("SubmitForm", "Form submission action detected in document catalog"),
            ("ResetForm", "Form reset action detected in document catalog"),
            ("AcroForm", "Interactive form fields detected in document"),
            ("AA", "Additional actions detected in document catalog"),
            ("Encrypt", "Encryption dictionary detected in document"),
            ("RichMedia", "Rich media content detected in document"),
            ("Flash", "Flash content detected in document"),
            ("EmbeddedFiles", "Embedded files reference detected in document catalog"),
        ]

        for (key, summary) in criticalKeys {
            var obj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog, key, &obj) {
                findings.append(PDFFinding(
                    id: "active-\(key.lowercased())",
                    summary: summary,
                    severity: .critical
                ))
            }
        }

        let warnKeys: [(String, String)] = [
            ("URI", "URI dictionary detected in document catalog"),
            ("Metadata", "XMP metadata stream detected in document catalog"),
            ("Names", "Name dictionary detected in document catalog"),
            ("PieceInfo", "Application-specific data detected in document catalog"),
        ]

        for (key, summary) in warnKeys {
            var obj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog, key, &obj) {
                findings.append(PDFFinding(
                    id: "active-\(key.lowercased())",
                    summary: summary,
                    severity: .warning
                ))
            }
        }

        // Per-page /AA (additional actions) — include pageIndex in finding.
        let pageCount = document.numberOfPages
        for i in 0..<pageCount {
            // CGPDFDocument pages are 1-indexed
            guard let page = document.page(at: i + 1) else { continue }
            guard let pageDict = page.dictionary else { continue }
            var obj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(pageDict, "AA", &obj) {
                findings.append(PDFFinding(
                    id: "active-page-aa-\(i)",
                    summary: "Additional actions detected on page \(i + 1)",
                    severity: .critical,
                    pageIndices: [i]
                ))
            }
        }

        return findings
    }

    // MARK: - Embedded Files

    /// Check /Names -> /EmbeddedFiles name tree. Creates CGPDFDocument internally.
    @concurrent
    public func checkEmbeddedFiles(from data: Data) async -> [PDFFinding] {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let catalog = document.catalog else { return [] }

        var namesDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Names", &namesDict),
              let names = namesDict else {
            return []
        }

        var embeddedDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &embeddedDict),
              let embedded = embeddedDict else {
            return []
        }

        // Count embedded files via /Names array
        var namesArray: CGPDFArrayRef?
        var fileCount = 0
        if CGPDFDictionaryGetArray(embedded, "Names", &namesArray), let arr = namesArray {
            // Names array alternates: [name1, filespec1, name2, filespec2, ...]
            fileCount = CGPDFArrayGetCount(arr) / 2
        }

        if fileCount > 0 {
            return [PDFFinding(
                id: "embedded-files",
                summary: "\(fileCount) embedded file\(fileCount == 1 ? "" : "s") detected in document",
                detail: "Embedded files may contain additional data not visible in the PDF pages.",
                severity: .critical
            )]
        }

        // /EmbeddedFiles key exists but no files found — still notable
        return [PDFFinding(
            id: "embedded-files-empty",
            summary: "Embedded files dictionary is present but contains no files",
            severity: .info
        )]
    }

    // MARK: - Hidden Layers (OCGs)

    /// Check /OCProperties for optional content groups. Creates CGPDFDocument internally.
    @concurrent
    public func checkHiddenLayers(from data: Data) async -> [PDFFinding] {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let catalog = document.catalog else { return [] }

        var ocPropsDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "OCProperties", &ocPropsDict),
              let ocProps = ocPropsDict else {
            return []
        }

        var findings: [PDFFinding] = []

        // Check /D -> /OFF array for hidden OCGs
        var defaultDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(ocProps, "D", &defaultDict), let d = defaultDict {
            var offArray: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(d, "OFF", &offArray), let off = offArray {
                let hiddenCount = CGPDFArrayGetCount(off)
                if hiddenCount > 0 {
                    // Try to extract hidden layer names
                    var layerNames: [String] = []
                    for i in 0..<hiddenCount {
                        var ocgDict: CGPDFDictionaryRef?
                        if CGPDFArrayGetDictionary(off, i, &ocgDict), let ocg = ocgDict {
                            if let name = readStringValue(from: ocg, key: "Name") {
                                layerNames.append(name)
                            }
                        }
                    }
                    let detail = layerNames.isEmpty ? nil : "Hidden layers: \(layerNames.joined(separator: ", "))"
                    findings.append(PDFFinding(
                        id: "hidden-layers-off",
                        summary: "\(hiddenCount) hidden layer\(hiddenCount == 1 ? "" : "s") detected in document",
                        detail: detail,
                        severity: .warning
                    ))
                    return findings
                }
            }
        }

        // /OCProperties exists but no hidden layers
        findings.append(PDFFinding(
            id: "hidden-layers-present",
            summary: "Optional content groups (layers) detected in document",
            detail: "The document uses layers. All layers appear to be visible.",
            severity: .warning
        ))
        return findings
    }

    // MARK: - Font Analysis (Bland et al. glyph positioning context)

    /// Analyze fonts per page for proportional font usage.
    /// Proportional fonts are flagged as info-level findings because glyph
    /// positioning in proportional fonts can leak information about redacted
    /// content (Bland et al. attack). Creates CGPDFDocument internally.
    @concurrent
    public func analyzeFonts(from data: Data) async -> [PDFFinding] {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return [] }

        let monospaceIndicators = ["Courier", "Consolas", "Menlo", "Monaco",
                                   "AndaleMono", "LucidaConsole", "DejaVuSansMono",
                                   "SourceCodePro", "FiraMono", "RobotoMono"]
        var proportionalFonts: Set<String> = []
        var pagesWithProportional: Set<Int> = []

        for i in 0..<document.numberOfPages {
            guard let page = document.page(at: i + 1),  // CGPDFDocument pages are 1-indexed
                  let pageDict = page.dictionary else { continue }

            var resourcesDict: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resourcesDict),
                  let resources = resourcesDict else { continue }

            var fontDict: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "Font", &fontDict),
                  let fonts = fontDict else { continue }

            // Enumerate font entries in the dictionary
            let pageIndex = i
            CGPDFDictionaryApplyBlock(fonts, { key, value, _ in
                var fontObjDict: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &fontObjDict),
                      let fontObj = fontObjDict else { return true }

                // Read /BaseFont name via CGPDFString
                var baseFontStr: CGPDFStringRef?
                if CGPDFDictionaryGetString(fontObj, "BaseFont", &baseFontStr),
                   let bfStr = baseFontStr,
                   let cfStr = CGPDFStringCopyTextString(bfStr) {
                    let baseFontName = cfStr as String
                    let isMonospace = monospaceIndicators.contains { indicator in
                        baseFontName.localizedCaseInsensitiveContains(indicator)
                    }
                    if !isMonospace {
                        proportionalFonts.insert(baseFontName)
                        pagesWithProportional.insert(pageIndex)
                    }
                }
                return true  // continue enumeration
            }, nil)
        }

        guard !proportionalFonts.isEmpty else { return [] }

        let fontList = proportionalFonts.sorted().prefix(5)
        let truncated = proportionalFonts.count > 5 ? " and \(proportionalFonts.count - 5) more" : ""
        return [PDFFinding(
            id: "font-proportional",
            summary: "Proportional font\(proportionalFonts.count == 1 ? "" : "s") detected in document",
            detail: "Font\(proportionalFonts.count == 1 ? "" : "s"): \(fontList.joined(separator: ", "))\(truncated). "
                + "Proportional fonts may allow glyph positioning analysis to infer redacted content length or character patterns.",
            severity: .info,
            pageIndices: pagesWithProportional.sorted()
        )]
    }

    // MARK: - Private Helpers

    private func readStringValue(from dict: CGPDFDictionaryRef, key: String) -> String? {
        var stringRef: CGPDFStringRef?
        if CGPDFDictionaryGetString(dict, key, &stringRef), let s = stringRef {
            if let cfStr = CGPDFStringCopyTextString(s) {
                return cfStr as String
            }
        }
        return nil
    }

    private func describeAttributeValue(_ value: Any) -> String? {
        if let str = value as? String, !str.isEmpty {
            return str
        }
        if let arr = value as? [String], !arr.isEmpty {
            return arr.joined(separator: ", ")
        }
        return nil
    }
}
