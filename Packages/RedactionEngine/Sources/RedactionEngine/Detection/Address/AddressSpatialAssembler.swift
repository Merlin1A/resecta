import Foundation
import CoreGraphics

// Multi-line address assembly on Vision line boxes.
// Replaces the inline AddressDetector.addressPattern regex when OCR lines are
// available. Strategy:
//
//   1. Group OCR lines by y-proximity (own y-gap tolerance, defined below).
//   2. For each contiguous y-group, scan for a ZIP regex anchor
//      (\d{5}(-\d{4})?).
//   3. On ZIP hit, look up to 3 lines upward within x-alignment ±5% page
//      width for a state abbreviation (or spelled state).
//   4. Cross-check the ZIP's 3-digit SCF prefix against the state via
//      ZIPStateTable. Mismatch → reject.
//   5. Concatenate participating lines into one address; compute union bbox.
//
// The regex-only path inside AddressDetector stays available as a fallback for
// callers without line-level data. Line-level callers run assembly ALONGSIDE
// the regex arms: DetectionOrchestrator Phase 3 and both
// DocumentSearcher PII-scan legs (`searchPII` over
// `EmbeddedTextSource` lines; `scanPagePIIViaOCR` over its normalized OCR
// line records).

struct AddressSpatialAssembler: Sendable {

    /// Optional city/county gazetteer. If absent (JSON missing or decode
    /// failed), assembler behavior is unchanged; if present, an extracted
    /// city token that the gazetteer rejects downgrades the assembly
    /// confidence.
    private let addressComponents: AddressComponentsGazetteer?

    /// Cached module-bundle load so repeated `AddressSpatialAssembler()`
    /// calls do not re-parse the 2 MB address_components.json.
    /// Outside the manifest signature by design; a load failure reports via
    /// the valid-path probe in `PIIDetector.loadWithDiagnostics`.
    private static let sharedAddressComponents: AddressComponentsGazetteer? =
        try? AddressComponentsGazetteer()

    init() {
        self.addressComponents = Self.sharedAddressComponents
    }

    static let zipPattern = try! NSRegularExpression(
        pattern: #"\b(\d{5})(?:-(\d{4}))?\b"#
    )

    /// Regex hinting a line looks like a "first line" of an address
    /// ("123 Main St", "456 Elm Avenue Apt 2"). Used to bound assembly.
    static let streetLinePattern = try! NSRegularExpression(
        pattern: #"\b\d{1,5}\s+[A-Za-z][A-Za-z0-9\s.,#-]{1,50}\b(?:St(?:reet)?|Ave(?:nue)?|Blvd|Boulevard|Dr(?:ive)?|Ln|Lane|Rd|Road|Ct|Court|Pl(?:ace)?|Way|Cir(?:cle)?|Pkwy|Parkway|Hwy|Highway|Ter(?:race)?|Sq(?:uare)?|Loop)\b"#,
        options: [.caseInsensitive]
    )

    /// Terminal street-type suffix pattern. Used by `streetTypeValid` to
    /// extract the street-type token from a candidate line so it can be
    /// checked against the gazetteer. Covers the subset of
    /// `streetLinePattern`'s trailing alternation whose canonical full-word
    /// forms the pipeline `street_types` list carries. `Loop` is deliberately
    /// absent: the pipeline list has never carried it, so Loop lines defer to
    /// the regex verdict (pre-S5 behavior) rather than being rejected.
    static let streetTypeSuffixPattern = try! NSRegularExpression(
        pattern: #"\b(?:St(?:reet)?|Ave(?:nue)?|Blvd|Boulevard|Dr(?:ive)?|Ln|Lane|Rd|Road|Ct|Court|Pl(?:ace)?|Way|Cir(?:cle)?|Pkwy|Parkway|Hwy|Highway|Ter(?:race)?|Sq(?:uare)?)\s*$"#,
        options: [.caseInsensitive]
    )

    /// A two-letter, upper-case, word-bounded token: a state code candidate
    /// in a line that names no state in full.
    static let stateCodePattern = try! NSRegularExpression(pattern: #"\b([A-Z]{2})\b"#)

    /// Abbreviation → canonical full word for the gazetteer lookup. The
    /// pipeline `street_types` list ships full words only ("Street",
    /// "Avenue", …), while `streetLinePattern` also accepts the common
    /// abbreviated forms; lookups must canonicalize or every abbreviated
    /// street line ("123 Main St") would fail validation. Keys and values
    /// lowercased; the table covers exactly the abbreviations
    /// `streetLinePattern` can match.
    private static let streetTypeCanonical: [String: String] = [
        "st": "street", "ave": "avenue", "blvd": "boulevard", "dr": "drive",
        "ln": "lane", "rd": "road", "ct": "court", "pl": "place",
        "cir": "circle", "pkwy": "parkway", "hwy": "highway",
        "ter": "terrace", "sq": "square",
    ]

    /// Optional state-name dictionary for spelled-out forms.
    private static let stateNameToCode: [String: String] = [
        "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR",
        "california": "CA", "colorado": "CO", "connecticut": "CT",
        "delaware": "DE", "florida": "FL", "georgia": "GA", "hawaii": "HI",
        "idaho": "ID", "illinois": "IL", "indiana": "IN", "iowa": "IA",
        "kansas": "KS", "kentucky": "KY", "louisiana": "LA", "maine": "ME",
        "maryland": "MD", "massachusetts": "MA", "michigan": "MI",
        "minnesota": "MN", "mississippi": "MS", "missouri": "MO",
        "montana": "MT", "nebraska": "NE", "nevada": "NV",
        "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM",
        "new york": "NY", "north carolina": "NC", "north dakota": "ND",
        "ohio": "OH", "oklahoma": "OK", "oregon": "OR", "pennsylvania": "PA",
        "rhode island": "RI", "south carolina": "SC", "south dakota": "SD",
        "tennessee": "TN", "texas": "TX", "utah": "UT", "vermont": "VT",
        "virginia": "VA", "washington": "WA", "west virginia": "WV",
        "wisconsin": "WI", "wyoming": "WY", "district of columbia": "DC"
    ]

    struct Assembled {
        let text: String
        let unionRect: CGRect
        let confidence: Double
        /// The union of the participating lines' text-layer boxes when any
        /// line was fitted to its ink (`OCREngine.TextLine.textLayerRect`): the
        /// hidden glyphs a Searchable export strips. Nil otherwise.
        var textLayerUnionRect: CGRect? = nil
        /// Some participating line's fit fell back to the drift envelope: the
        /// caller reports the page as not fully analysed.
        var inkFitDegraded: Bool = false
    }

    func assemble(lines: [OCREngine.TextLine]) -> [Assembled] {
        guard !lines.isEmpty else { return [] }

        // Lines group and join on the text layer's own geometry
        // (`textLayerRect`, set when a line was fitted to its ink), never on
        // the painted box: a fit or a drift envelope must not move the join.
        func place(_ line: OCREngine.TextLine) -> CGRect { line.textLayerRect ?? line.normalizedRect }
        // Sort by y descending (Vision coords: y=1 top, y=0 bottom).
        let sorted = lines.enumerated().sorted {
            place($0.element).minY > place($1.element).minY
        }

        var results: [Assembled] = []

        // Walk lines top-to-bottom; look for a ZIP anchor. For each anchor,
        // walk upward up to 3 lines to pick up state + street components
        // as long as y-gap and x-alignment allow.
        for (idx, hit) in sorted.enumerated() {
            let haystack = hit.element.text as NSString
            guard let zipMatch = Self.zipPattern.firstMatch(
                in: hit.element.text,
                range: NSRange(location: 0, length: haystack.length)
            ) else { continue }

            let zipString = haystack.substring(with: zipMatch.range(at: 1))
            let scfState = ZIPStateTable.state(forZIP: zipString)

            // Extract state from same line or prior lines.
            var state: String?
            if let found = Self.findState(in: hit.element.text) {
                state = found
            }

            // Walk up to 3 lines upward.
            var participants: [OCREngine.TextLine] = [hit.element]
            var streetLineFound = false
            if Self.streetLinePattern.firstMatch(
                in: hit.element.text,
                range: NSRange(location: 0, length: haystack.length)
            ) != nil,
               Self.streetTypeValid(in: hit.element.text, gazetteer: addressComponents) {
                streetLineFound = true
            }

            var back = idx - 1
            var steps = 0
            while back >= 0 && steps < 3 {
                let candidate = sorted[back].element
                let yGap = place(candidate).minY - place(hit.element).minY
                guard yGap >= 0, yGap <= 0.08 else { break }
                // x-alignment: line lefts within 5% page width.
                let dx = abs(place(candidate).minX - place(hit.element).minX)
                guard dx <= 0.05 else { break }

                participants.insert(candidate, at: 0)
                if state == nil, let found = Self.findState(in: candidate.text) {
                    state = found
                }
                let ns = candidate.text as NSString
                if !streetLineFound,
                   Self.streetLinePattern.firstMatch(
                       in: candidate.text,
                       range: NSRange(location: 0, length: ns.length)
                   ) != nil,
                   Self.streetTypeValid(in: candidate.text, gazetteer: addressComponents) {
                    streetLineFound = true
                }

                back -= 1
                steps += 1
            }

            // Reject if we have a state AND a SCF prefix but they disagree.
            if let state, let scfState, state.uppercased() != scfState {
                continue
            }
            // Require at least a street-looking line OR a clear state to emit.
            guard streetLineFound || state != nil else { continue }

            let assembledText = participants.map(\.text).joined(separator: ", ")
            let unionRect = participants.dropFirst().reduce(participants[0].normalizedRect) {
                $0.union($1.normalizedRect)
            }
            var baseConfidence: Double = state != nil && streetLineFound ? 0.80 :
                                         state != nil ? 0.65 : 0.55
            // City cross-check. Present-gazetteer + extractable
            // city + gazetteer-rejects → downweight; absent-gazetteer or
            // non-extractable city → unchanged (back-compat).
            if let gazetteer = addressComponents,
               let city = Self.extractCityToken(from: hit.element.text),
               !gazetteer.containsCity(city) {
                baseConfidence = max(0.30, baseConfidence - 0.20)
            }
            let textLayerUnionRect = participants.contains { $0.textLayerRect != nil }
                ? participants.dropFirst().reduce(participants[0].textLayerRect ?? participants[0].normalizedRect) {
                    $0.union($1.textLayerRect ?? $1.normalizedRect)
                }
                : nil
            results.append(Assembled(
                text: assembledText,
                unionRect: unionRect,
                confidence: baseConfidence,
                textLayerUnionRect: textLayerUnionRect,
                inkFitDegraded: participants.contains(where: \.inkFitDegraded)
            ))
        }
        return results
    }

    /// Return whether the street-type token matched by `streetLinePattern` in
    /// *line* is recognised by the gazetteer.
    ///
    /// Behavioral contract:
    /// - When *gazetteer* is `nil` (resource absent or decode failed), this
    ///   method returns `true` unconditionally so nil-gazetteer behavior is
    ///   byte-identical to the pre-S5 code path.
    /// - When *gazetteer* is present, the regex-matched street-type suffix is
    ///   extracted and checked via `gazetteer.containsStreetType(_:)`.
    ///
    /// Today every token this method positively validates canonicalizes into
    /// the pipeline's current 20-word `street_types` list, so the validation
    /// is behavior-neutral with the shipped artifact. Its purpose is forward
    /// compatibility: future pipeline-driven changes to the street-type list
    /// flow to the assembler (both full and abbreviated surface forms)
    /// without Swift edits.
    private static func streetTypeValid(
        in line: String,
        gazetteer: AddressComponentsGazetteer?
    ) -> Bool {
        guard let gazetteer else { return true }
        // Extract the terminal token that looks like a street type.
        // streetTypeSuffixPattern covers the canonicalizable subset of
        // streetLinePattern's trailing alternation.
        let ns = line as NSString
        guard let match = Self.streetTypeSuffixPattern.firstMatch(
            in: line,
            range: NSRange(location: 0, length: ns.length)
        ) else {
            // No canonicalizable terminal suffix (e.g. "Loop"); defer to the
            // original regex verdict rather than rejecting a line the
            // validator does not understand.
            return true
        }
        let token = ns.substring(with: match.range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let canonical = Self.streetTypeCanonical[token] ?? token
        return gazetteer.containsStreetType(canonical)
    }

    /// Extract a candidate city token from a "City, ST 12345" or
    /// "City, State Name 12345" line. Returns `nil` when the line doesn't
    /// match that shape, which skips the gazetteer cross-check.
    private static func extractCityToken(from line: String) -> String? {
        guard let commaIdx = line.firstIndex(of: ",") else { return nil }
        let city = line[..<commaIdx].trimmingCharacters(in: .whitespacesAndNewlines)
        return city.isEmpty ? nil : city
    }

    private static func findState(in text: String) -> String? {
        let lower = text.lowercased()
        for (name, code) in stateNameToCode where lower.contains(name) {
            return code
        }
        // Two-letter state codes must be uppercase and word-bounded —
        // searched through the original text.
        let pattern = Self.stateCodePattern
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let code = ns.substring(with: match.range(at: 1))
            if Self.validStateCodes.contains(code) { return code }
        }
        return nil
    }

    private static let validStateCodes: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI",
        "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD", "MA", "MI",
        "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC",
        "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT",
        "VT", "VA", "WA", "WV", "WI", "WY", "DC", "PR", "VI"
    ]
}
