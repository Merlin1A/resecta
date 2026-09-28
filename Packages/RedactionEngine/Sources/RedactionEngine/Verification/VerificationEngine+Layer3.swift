import Foundation
import PDFKit

// Layer 3 — Binary String Search: the raw-byte structural pass (stream
// ranges excluded), the decoded `page.string` re-scan (as extracted and in
// its normalized form) and the JPEG EXIF scan, all over the sensitive-term
// automaton. The body moved here whole from `VerificationEngine.swift`
// (the Layer-2 split precedent); the dispatcher stays in `runLayer`.

extension VerificationEngine {

    // MARK: - Layer 3: Binary String Search

    /// Returns (status, affectedPages, reviewTermTexts). The
    /// decoded-page hits and the EXIF WARN carry their 0-based page lists
    /// for the UI's tappable page chips; the structural raw-byte pass is
    /// document-level (nil). The third element carries the display-only term
    /// texts behind an `.attention` verdict (nil for every other status).
    func runLayer3BinarySearch(
        _ doc: PDFDocument, sensitiveTerms: [SensitiveTerm]
    ) throws -> (VerificationStatus, [Int]?, [String]?, Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        // No terms provided — expected for manual-only redaction.
        // INFO, not PASS — the string search did not run, and "No issues
        // found" would overstate what this layer observed. INFO lands in the
        // notes group without bumping the masthead (Layer-7 boundary-count
        // precedent).
        guard !sensitiveTerms.isEmpty else {
            return (.info("No sensitive terms were provided — string search did not run."), nil, nil, false)
        }
        // Filter terms too short to search (shared
        // `AhoCorasick.isSearchableTerm`): ≥3 scalars (supports 3-letter PII
        // abbreviations like SSN, DOB, PHI) or a 2-character CJK name.
        let validTerms = sensitiveTerms.filter { AhoCorasick.isSearchableTerm($0.text) }
        guard !validTerms.isEmpty else {
            return (.warn("All sensitive terms shorter than 3 characters"), nil, nil, true)
        }
        // Surfaced on the otherwise-clean path below so a partial drop is
        // never silent (the all-short WARN above covers the total drop).
        let droppedTermCount = sensitiveTerms.count - validTerms.count

        // Build the Aho-Corasick automaton with all encoding variants, keeping
        // each pattern's token-boundary discipline for the match
        // post-filters below.
        // DEFERRED: automaton caching is deferred to
        // V1.1. AhoCorasick is a Sendable value built fresh per
        // verification call; caching needs an actor/class wrapper for ~25 ms
        // saved once per export — low benefit, no security relevance.
        let termAutomaton = SensitiveTermAutomaton(validTerms: validTerms)
        guard termAutomaton.hasPatterns else { return (.pass, nil, nil, false) }
        let automaton = termAutomaton.automaton

        // If the automaton degraded due to pattern size limits,
        // report the limitation rather than silently passing.
        if automaton.isDegraded {
            return (.warn("Sensitive term search exceeded size limit — results may be incomplete"), nil, nil, true)
        }

        // Get raw PDF bytes.
        // Raw PDF bytes: loadPDFData reads the whole output into memory;
        // `Data(contentsOf:)` with default options requests no mapping
        // (`.mappedIfSafe` is an opt-in reading option).
        guard let (data, cgDoc) = loadPDFData(doc) else {
            return (.warn("Could not read output PDF for binary search"), nil, nil, true)
        }

        // First WARN encountered, returned only if no FAIL is found below: a
        // non-boundary structural fragment (Part A) or an EXIF hit (Part B) must
        // not mask a boundary-token or decoded-text FAIL. Carries the 0-based page
        // list when the WARN is page-scoped (EXIF); nil when document-level.
        var deferredWarn: (message: String, pages: [Int]?)?
        // Structural complete-token FAIL, held (not returned) so the
        // decoded pass below always runs — a structural hit must not mask a
        // decoded-text hit; both findings combine into one result at the end.
        var structuralFailMessage: String?

        // Structural pass: raw-byte scan with stream ranges excluded.
        // Compressed streams (FlateDecode) contain random byte sequences that
        // produce false positive matches. Structural/metadata bytes outside
        // streams are the meaningful search surface. Other layers (1, 2, 6, 8)
        // independently verify text content. See ISO 32000-2 §7.3.8.
        // DEFERRED: stream decompression (decompress-then-search)
        // is deferred to V1.1 — Resecta's own CGPDFContext
        // output embeds no compressed PII-bearing streams, and the
        // page.string re-scan below compensates for PDFKit-decoded text.
        // Boundary-required terms drop matches embedded in an
        // alphanumeric run before any classification.
        let allMatches = termAutomaton.tokenFilteredMatches(in: data)
        if !allMatches.isEmpty {
            let streamRanges = findStreamRanges(data)
            let structuralMatches = allMatches.filter { match in
                !streamRanges.contains { $0.contains(match.position) }
            }
            if !structuralMatches.isEmpty {
                // Token-boundary rule ("verify matches are complete PDF
                // tokens"): a match bounded by PDF delimiters on BOTH sides is a
                // complete token → FAIL; a match embedded mid-token on either
                // side (the term inside "classifieddata", or trailing a name
                // token as in "/FontName ") is a possible fragment collision →
                // WARN. A match at buffer start / ending at EOF has no adjacent
                // byte on that side and counts as bounded there.
                let boundaryMatches = structuralMatches.filter { match in
                    if match.position > 0,
                       !Self.pdfDelimiters.contains(data[data.startIndex + match.position - 1]) {
                        return false
                    }
                    let end = match.position + match.length
                    guard end < data.count else { return true }  // EOF = boundary
                    return Self.pdfDelimiters.contains(data[data.startIndex + end])
                }
                if !boundaryMatches.isEmpty {
                    // Physical-occurrence count: unique (position, length), so
                    // one occurrence never multi-counts across case/encoding
                    // pattern variants.
                    structuralFailMessage =
                        "Sensitive string found in output PDF structural data (\(AhoCorasick.uniqueOccurrenceCount(boundaryMatches)) match(es))"
                } else {
                    deferredWarn = deferredWarn
                        ?? (message: "Possible sensitive term fragment in output PDF structural data (\(AhoCorasick.uniqueOccurrenceCount(structuralMatches)) match(es))",
                            pages: nil)
                }
            }
        }

        // M1 tightening: always re-scan PDFKit's decoded
        // page.string, even when the structural raw-byte pass produced no
        // matches. PDFKit decodes operator-level encodings transparently
        // (UTF-16 surrogate halves, octal escapes inside literal strings,
        // Name-object substitution); sensitive terms that live only inside
        // an excluded stream range or behind a decoding transformation
        // surface here.
        // Accumulate across ALL pages (not first-hit-return) so a multi-page
        // leak is reported in one run; the 0-based page list feeds the chips.
        var decodedHitPages: [Int] = []
        var decodedMatchCount = 0
        var decodedTermTexts: [String] = []
        var decodedTermsSeen = Set<String>()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i),
                  let pageText = page.string,
                  !pageText.isEmpty else { continue }
            // The decoded text is scanned as extracted and, when the search
            // path's normalizer changes it (a ligature or another
            // compatibility form in the text layer), in that normalized form
            // as well, so a residue the search can locate is never invisible
            // here. A page counts once; its instance count is the larger of
            // the two scans, so one occurrence never double-counts.
            let decodedMatches = termAutomaton.tokenFilteredMatches(in: Data(pageText.utf8))
            let normalizedText = TextNormalizer.normalize(pageText)
            let normalizedMatches = normalizedText == pageText
                ? []
                : termAutomaton.tokenFilteredMatches(in: Data(normalizedText.utf8))
            if !decodedMatches.isEmpty || !normalizedMatches.isEmpty {
                decodedHitPages.append(i)
                decodedMatchCount += max(
                    AhoCorasick.uniqueOccurrenceCount(decodedMatches),
                    AhoCorasick.uniqueOccurrenceCount(normalizedMatches))
                for text in termAutomaton.matchedTermTexts(decodedMatches + normalizedMatches)
                where decodedTermsSeen.insert(text).inserted {
                    decodedTermTexts.append(text)
                }
            }
        }
        var decodedResidualMessage: String?
        if !decodedHitPages.isEmpty {
            let list = decodedHitPages.map { String($0 + 1) }.joined(separator: ", ")
            decodedResidualMessage =
                "Text matching your redactions is still readable on \(pagePhrase(decodedHitPages, list: list)) "
                + "(\(decodedMatchCount) instance\(decodedMatchCount == 1 ? "" : "s"))"
        }
        // Combine the held structural and decoded verdicts into ONE result so
        // neither verdict masks the other; the page list carries the decoded
        // pass's page-scoped part (the structural pass is document-level).
        // Tiering: a structural hit is a defect in the output itself → FAIL
        // (the decoded text rides along in the combined message). A decoded
        // hit alone is residual text OUTSIDE every region — the user's remedy
        // is a text search — → ATTENTION, with the term texts threaded for
        // display (the message itself stays content-free).
        if let structuralFailMessage {
            let message = [structuralFailMessage, decodedResidualMessage]
                .compactMap { $0 }
                .joined(separator: "; ")
            return (.fail(message), decodedHitPages.isEmpty ? nil : decodedHitPages, nil, false)
        }
        if let decodedResidualMessage {
            return (.attention(decodedResidualMessage), decodedHitPages, decodedTermTexts, false)
        }

        // EXIF scan ("scan JPEG APP1/EXIF markers", WARN-only):
        // EXIF IFD bytes live inside the image stream and surface in neither
        // page.string nor the structural pass. Scan each JPEG XObject's raw
        // bytes for an APP1/EXIF segment carrying a sensitive term. WARN only;
        // skipped if a structural fragment WARN was already recorded.
        if deferredWarn == nil {
            for pageIdx in 1...max(1, cgDoc.numberOfPages) {
                try Task.checkCancellation()
                guard let cgPage = cgDoc.page(at: pageIdx) else { continue }
                if Self.extractRawJPEGStreams(from: cgPage).contains(where: {
                    Self.jpegEXIFContainsTerm($0, automaton: automaton)
                }) {
                    deferredWarn = (message: "Sensitive term found in embedded JPEG EXIF metadata on page \(pageIdx)",
                                    pages: [pageIdx - 1])
                    break
                }
            }
        }

        if let warn = deferredWarn { return (.warn(warn.message), warn.pages, nil, false) }
        if droppedTermCount > 0 {
            // Partial-coverage honesty: some (not all) terms were too short
            // to search — terms it could not search: a could-not-verify WARN.
            return (.warn(shortTermTail(droppedTermCount)), nil, nil, true)
        }
        return (.pass, nil, nil, false)
    }

    /// Byte ranges of PDF stream data (between `stream` and `endstream` markers).
    /// ISO 32000-2 §7.3.8: the `stream` keyword is followed by CR LF or LF
    /// (bare CR is not permitted), data bytes, then EOL + `endstream`.
    /// Returns ranges covering the data bytes (exclusive of markers).
    ///
    /// The strict pass REQUIRES that keyword EOL. Without it, any structural
    /// byte-run containing the letters "stream" (e.g. a /Downstream name)
    /// opened a phantom range reaching to the next `endstream` or EOF, and
    /// structural term matches inside that span were excluded from Layer 3's
    /// FAIL/WARN pass. The permissive scan (EOL optional — the pre-gate
    /// behavior) is retained ONLY as a fallback when the strict pass yields
    /// no ranges at all, so a malformed writer's streams are still excluded
    /// rather than raw-byte-scanned (malformed-file tolerance; compressed
    /// stream bytes as false-positive fodder is the worse failure there).
    private func findStreamRanges(_ data: Data) -> [Range<Int>] {
        let strict = scanStreamRanges(data, requireKeywordEOL: true)
        if !strict.isEmpty { return strict }
        return scanStreamRanges(data, requireKeywordEOL: false)
    }

    private func scanStreamRanges(_ data: Data, requireKeywordEOL: Bool) -> [Range<Int>] {
        // ASCII bytes for marker detection
        let streamMarker: [UInt8] = [0x73, 0x74, 0x72, 0x65, 0x61, 0x6D]       // "stream"
        let endstreamMarker: [UInt8] = [0x65, 0x6E, 0x64, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D] // "endstream"

        var ranges: [Range<Int>] = []
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = rawBuffer.count
            var i = 0

            while i < count - streamMarker.count {
                // Look for "stream" not preceded by "end" (avoid matching "endstream" as "stream")
                guard memcmp(base + i, streamMarker, streamMarker.count) == 0 else {
                    i += 1
                    continue
                }
                // Verify not "endstream"
                if i >= 3 && memcmp(base + i - 3, endstreamMarker, endstreamMarker.count) == 0 {
                    i += streamMarker.count
                    continue
                }

                // Skip past "stream" + EOL (CR+LF or just LF)
                var dataStart = i + streamMarker.count
                if requireKeywordEOL {
                    // Strict: the keyword must be followed by CR LF or LF
                    // (§7.3.8) or this is not a stream keyword at all — an
                    // embedded byte-run like "Downstream" opens no range.
                    if dataStart + 1 < count, base[dataStart] == 0x0D, base[dataStart + 1] == 0x0A {
                        dataStart += 2
                    } else if dataStart < count, base[dataStart] == 0x0A {
                        dataStart += 1
                    } else {
                        i += 1
                        continue
                    }
                } else {
                    if dataStart < count && base[dataStart] == 0x0D { dataStart += 1 } // CR
                    if dataStart < count && base[dataStart] == 0x0A { dataStart += 1 } // LF
                }

                // Locate "endstream"
                var j = dataStart
                while j < count - endstreamMarker.count {
                    if memcmp(base + j, endstreamMarker, endstreamMarker.count) == 0 {
                        break
                    }
                    j += 1
                }
                if j < count - endstreamMarker.count {
                    ranges.append(dataStart..<j)
                    i = j + endstreamMarker.count
                } else {
                    // Malformed: no endstream found, treat rest as stream data
                    ranges.append(dataStart..<count)
                    break
                }
            }
        }
        return ranges
    }
}
