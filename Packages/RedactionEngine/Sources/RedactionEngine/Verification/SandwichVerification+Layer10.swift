import PDFKit
import CoreGraphics
import Foundation

// Layer 10 — Operator Re-Extraction: the `CGPDFScanner` walk of every
// output page's content stream, each text-show operand decoded by
// `CGPDFStringCopyTextString` (independent of PDFKit's `page.string`,
// Layer 3's decoder) and searched with the sensitive-term automaton — the
// second decoder of the Layer 3 / Layer 10 cross-check. The body moved
// here whole from `SandwichVerification.swift` (the
// `VerificationEngine+Layer3.swift` precedent); the dispatcher and the
// layer's place in the report order are unchanged.

extension SandwichVerification {

    // MARK: - Layer 10: Operator Re-Extraction

    /// Walk each output page's content stream via `CGPDFScanner` and
    /// accumulate the per-page semantic text decoded from the four
    /// PDF 1.7 §9.4.3 text-show operators (`Tj`, `TJ`, `'`, `"`). Each string
    /// operand is decoded via `CGPDFStringCopyTextString` — an Apple-
    /// maintained string-text decoder independent of PDFKit's `page.string`
    /// (the basis of Layer 3's decoder). Reports presence of any sensitive
    /// term in the accumulated bytes via Aho-Corasick.
    ///
    /// Pairs with Layer 3 as a two-decoder cross-check: a sensitive
    /// term surfaced by exactly one of the two layers reports a decoder
    /// divergence (e.g., a Name-object Tj operand surfaced only by the
    /// scanner; a literal-string surrogate-pair surfaced by both decoders).
    ///
    /// Receives a SendablePDFDocument. The page walk reads
    /// `pageRef` (non-Sendable); the verification runner calls this layer
    /// on a single executor at a time. Hand-off across the @concurrent
    /// dispatch boundary uses the existing `SendablePDFDocument` wrapper.
    /// Returns (status, pageReferences, reviewTermTexts, couldNotVerify).
    /// `pageReferences` carries the 0-based page behind an `.attention`
    /// verdict for the UI's tappable page chips; `reviewTermTexts` carries
    /// the display-only term texts behind that verdict (the status message
    /// itself stays content-free). Both nil for every other status.
    /// `couldNotVerify` is true for the WARNs that say the scan did not
    /// fully run (terms it could not search, pages it could not traverse).
    public func verifyTextOperatorSemantics(
        outputDocument: SendablePDFDocument,
        sensitiveTerms: [SensitiveTerm]
    ) async -> (status: VerificationStatus, pageReferences: [Int]?, reviewTermTexts: [String]?,
                couldNotVerify: Bool) {
        // No terms provided — expected for manual-only redaction.
        // INFO, not PASS — the operator-semantic search did not run, and
        // "No issues found" would overstate what this layer observed
        // (mirrors Layer 3's guard).
        guard !sensitiveTerms.isEmpty else {
            return (.info("No sensitive terms were provided — string search did not run."), nil, nil, false)
        }
        // Filter terms too short to search (matches Layer 3, shared
        // `AhoCorasick.isSearchableTerm`): ≥3 scalars (supports 3-letter PII
        // abbreviations like SSN, DOB, PHI) or a 2-character CJK name.
        // The all-short case previously read as a clean PASS here
        // while Layer 3 WARNed — align on Layer 3's tier and copy.
        let validTerms = sensitiveTerms.filter { AhoCorasick.isSearchableTerm($0.text) }
        guard !validTerms.isEmpty else {
            return (.warn("All sensitive terms shorter than 3 characters"), nil, nil, true)
        }
        // Surfaced on the otherwise-clean path below (mirrors Layer 3).
        let droppedTermCount = sensitiveTerms.count - validTerms.count

        // Boundary-required terms drop matches embedded in an
        // alphanumeric run; plain terms keep substring semantics.
        let termAutomaton = SensitiveTermAutomaton(validTerms: validTerms)
        guard termAutomaton.hasPatterns else { return (.pass, nil, nil, false) }
        if termAutomaton.isDegraded {
            return (.warn(
                "Operator-semantic term search exceeded size limit — results may be incomplete"
            ), nil, nil, true)
        }

        let doc = outputDocument.document
        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIdx),
                  let pageRef = page.pageRef else {
                return (.warn(
                    "Operator scanner unavailable for page \(pageIdx + 1)"
                ), nil, nil, true)
            }

            // Accumulate per-page semantic text bytes. The C callbacks below
            // append decoded UTF-8 bytes plus a 0x1F separator to this Data
            // via the scanner's `info` pointer; @convention(c) callbacks
            // cannot capture Swift context, so the accumulator is the only
            // channel for state across operator hits.
            var accumulator = Data()
            let scanned: Bool = withUnsafeMutablePointer(to: &accumulator) { accPtr in
                guard let table = CGPDFOperatorTableCreate() else { return false }
                defer { CGPDFOperatorTableRelease(table) }

                // PDF 1.7 §9.4.3 Table 107 — text-showing operators:
                //   Tj   operand = string             (pop one object)
                //   '    operand = string             (pop one object)
                //   "    operands = a_w a_c string    (pop one object off top)
                //   TJ   operand = array              (pop array, walk objects)
                //
                // Pop via CGPDFScannerPopObject so a malformed Name operand
                // (e.g., `/SSN Tj`) — invalid under spec but surfaced by a
                // forgiving viewer — is observed alongside well-formed
                // String operands. CGPDFStringCopyTextString is the
                // independent decoder vs. PDFKit's `page.string` (Layer 3's
                // decoder): it reads each operand as PDFDocEncoding (or
                // UTF-16 behind a byte-order mark) without consulting the
                // page's font encodings, so a byte above ASCII drawn through
                // a font whose encoding differs from PDFDocEncoding there
                // (the writer's Courier subset is MacRoman-encoded) reads
                // back as PDFDocEncoding's character for that byte. The
                // corpus cell `factory-compat-residue` measures that gap.
                // nil decodes are tolerated — false negatives are
                // acceptable on a defense-in-depth layer; false positives
                // are not.
                CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
                    sandwichLayer10AppendPoppedOperand(scanner: scanner, info: info)
                }
                CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
                    sandwichLayer10AppendPoppedOperand(scanner: scanner, info: info)
                }
                CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
                    sandwichLayer10AppendPoppedOperand(scanner: scanner, info: info)
                }
                CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
                    var pdfArray: CGPDFArrayRef?
                    guard CGPDFScannerPopArray(scanner, &pdfArray),
                          let arr = pdfArray,
                          let info else { return }
                    let ptr = info.assumingMemoryBound(to: Data.self)
                    let count = CGPDFArrayGetCount(arr)
                    for i in 0..<count {
                        var obj: CGPDFObjectRef?
                        guard CGPDFArrayGetObject(arr, i, &obj),
                              let o = obj else {
                            // Numeric kerning displacements are interleaved
                            // with string/name elements in a TJ array; they
                            // carry no text content and are skipped.
                            continue
                        }
                        sandwichLayer10AppendObjectText(o, into: ptr)
                    }
                }

                let contentStream = CGPDFContentStreamCreateWithPage(pageRef)
                defer { CGPDFContentStreamRelease(contentStream) }
                let scanner = CGPDFScannerCreate(
                    contentStream, table, UnsafeMutableRawPointer(accPtr)
                )
                defer { CGPDFScannerRelease(scanner) }
                return CGPDFScannerScan(scanner)
            }
            if !scanned {
                return (.warn(
                    "Operator scanner could not traverse page \(pageIdx + 1)"
                ), nil, nil, true)
            }

            // The status message reports page index + match count
            // only; the matched term content is never echoed in it. Mirrors
            // Layer 3's shape at VerificationEngine.runLayer3BinarySearch.
            // The term texts travel beside the status in the display-only
            // third element instead. A hit here is decoded operator text that
            // survives OUTSIDE every region (in-region content is removed
            // from the stream) — residual, user-recoverable via text search
            // → ATTENTION, not FAIL.
            // The decoded operator text is scanned as decoded and, when the
            // search path's normalizer changes it (a ligature or another
            // compatibility form in an operand), in that normalized form as
            // well — the mirror of Layer 3's decoded pass in
            // `VerificationEngine.runLayer3BinarySearch`. A page counts once;
            // its instance count is the larger of the two scans, so one
            // occurrence never double-counts. The accumulator holds UTF-8
            // (decoded strings + the 0x1F separator), so the round trip
            // through String is lossless.
            let matches = termAutomaton.tokenFilteredMatches(in: accumulator)
            let decodedText = String(decoding: accumulator, as: UTF8.self)
            let normalizedText = TextNormalizer.normalize(decodedText)
            let normalizedMatches = normalizedText == decodedText
                ? []
                : termAutomaton.tokenFilteredMatches(in: Data(normalizedText.utf8))
            if !matches.isEmpty || !normalizedMatches.isEmpty {
                // Physical-occurrence count: unique (position, length), so one
                // occurrence never multi-counts across case/encoding variants.
                let count = max(
                    AhoCorasick.uniqueOccurrenceCount(matches),
                    AhoCorasick.uniqueOccurrenceCount(normalizedMatches))
                return (.attention(
                    "Text matching your redactions is readable in page \(pageIdx + 1) content "
                    + "(\(count) instance\(count == 1 ? "" : "s"))"
                ), [pageIdx], termAutomaton.matchedTermTexts(matches + normalizedMatches), false)
            }
        }
        if droppedTermCount > 0 {
            return (.warn(shortTermTail(droppedTermCount)), nil, nil, true)
        }
        return (.pass, nil, nil, false)
    }
}

// MARK: - Layer 10 callback helpers
//
// `@convention(c)` callbacks installed via `CGPDFOperatorTableSetCallback`
// cannot capture Swift context. These file-private helpers run inside the
// callback body and operate purely on the scanner ref + the info pointer
// (which the callback site populates with a `&Data` accumulator).

fileprivate func sandwichLayer10AppendPoppedOperand(
    scanner: CGPDFScannerRef,
    info: UnsafeMutableRawPointer?
) {
    var obj: CGPDFObjectRef?
    guard CGPDFScannerPopObject(scanner, &obj),
          let o = obj,
          let info else { return }
    let ptr = info.assumingMemoryBound(to: Data.self)
    sandwichLayer10AppendObjectText(o, into: ptr)
}

fileprivate func sandwichLayer10AppendObjectText(
    _ obj: CGPDFObjectRef,
    into ptr: UnsafeMutablePointer<Data>
) {
    switch CGPDFObjectGetType(obj) {
    case .string:
        var s: CGPDFStringRef?
        let popped = withUnsafeMutablePointer(to: &s) { sPtr in
            CGPDFObjectGetValue(obj, .string, UnsafeMutableRawPointer(sPtr))
        }
        guard popped,
              let str = s,
              let decoded = CGPDFStringCopyTextString(str) else { return }
        ptr.pointee.append(Data((decoded as String).utf8))
        ptr.pointee.append(0x1F)
    case .name:
        // PDF 1.7 §7.3.5: Name objects are UTF-8 byte sequences. A spec-
        // valid `Tj` operand is always a string; observing a Name operand
        // here surfaces a malformed-but-renderable construction that the
        // Layer 3 PDFKit decoder may also surface as glyph-shaped text.
        var cstr: UnsafePointer<Int8>? = nil
        let popped = withUnsafeMutablePointer(to: &cstr) { cPtr in
            CGPDFObjectGetValue(obj, .name, UnsafeMutableRawPointer(cPtr))
        }
        guard popped, let p = cstr else { return }
        ptr.pointee.append(Data(String(cString: p).utf8))
        ptr.pointee.append(0x1F)
    default:
        // Numeric kerning displacements and other non-text operands carry
        // no semantic text content for Layer 10 to surface.
        break
    }
}
