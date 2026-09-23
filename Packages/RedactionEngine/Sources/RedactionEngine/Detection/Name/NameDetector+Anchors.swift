import Foundation

// The deterministic name passes: the legal-prefix heuristics (pass 3) and
// the label-anchor routes (pass 4), run by `NameDetector.detect` after the
// two tagger passes; a tagger row on the same text wins the range overlap.
extension NameDetector {

    // MARK: - Legal Prefix Heuristics

    private static let legalPrefixes = [
        "Mr.", "Ms.", "Mrs.", "Dr.", "Judge", "Plaintiff", "Defendant",
        "Appellant", "Respondent", "Patient", "Witness",
        "Attorney", "Counsel", "Prof.", "Professor", "Officer", "Agent",
        "Senator", "Rep.", "Honorable", "Reverend", "Rev."
    ]

    /// True when the text right after a prefix hit opens with a sentence
    /// boundary: optional horizontal whitespace, one of `.` `;` `:`, optional
    /// horizontal whitespace, then a line break. Anything else — a name, a
    /// bare line break, a comma, a dash — is not a boundary.
    private static func sentenceBoundaryOpens(_ window: String) -> Bool {
        var sawTerminator = false
        for ch in window {
            if ch == " " || ch == "\t" { continue }
            if ch.isNewline { return sawTerminator }
            if !sawTerminator, ch == "." || ch == ";" || ch == ":" {
                sawTerminator = true
                continue
            }
            return false
        }
        return false
    }

    func scanLegalPrefixes(in text: String) -> [PIIMatch] {
        var results: [PIIMatch] = []
        let nsText = text as NSString

        for prefix in Self.legalPrefixes {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while true {
                let found = nsText.range(of: prefix, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }

                // Look for the word(s) following the prefix. Strip leading
                // whitespace AND the punctuation marks that commonly sit
                // between a legal/medical prefix and the name (e.g.
                // "Patient: Maria Johnson", "Plaintiff, John Doe",
                // "Witness — Jane Smith"). Without this the colon/comma
                // becomes the first "word" and the uppercase-prefix scan
                // bails before it reaches the name.
                let afterPrefix = found.length + found.location
                let remaining = nsText.length - afterPrefix
                guard remaining > 1 else { break }

                let afterRange = NSRange(location: afterPrefix, length: min(50, remaining))
                let trimSet = CharacterSet.whitespacesAndNewlines
                    .union(CharacterSet(charactersIn: ":,;.-—–"))
                let window = nsText.substring(with: afterRange)
                // A sentence boundary right after the prefix — `.` / `;` / `:`
                // and then a line break — ends the reading before the trim:
                // the next line's first capitalised word opens a new sentence
                // and is not the name after the prefix. A bare line break or
                // same-line punctuation still reaches the trim below.
                let afterText = Self.sentenceBoundaryOpens(window)
                    ? ""
                    : window.trimmingCharacters(in: trimSet)

                // Extract first 1-3 capitalized words
                let words = afterText.split(separator: " ", maxSplits: 3)
                let nameWords = words.prefix(while: { word in
                    guard let first = word.first else { return false }
                    return first.isUppercase
                })
                let name = nameWords.joined(separator: " ")
                // An empty assembly or a stop token standing alone after the
                // prefix is not a name; the scan moves on to the next prefix hit.
                if !nameWords.isEmpty, !Self.nameStopTokens.contains(name) {
                    // `afterText` was trimmed of leading punctuation/
                    // whitespace, but `afterPrefix` still points at the first
                    // trimmed char, so the name range was left-shifted by the
                    // leading-trim width (e.g. the ": " in "Patient: Maria").
                    // Recover the true start from the first non-trim character in
                    // the window. This measures the LEADING trim only; a
                    // window-length-minus-trimmed-length width would also absorb
                    // any TRAILING trim and push the box past the name when the
                    // 50-char window ends on punctuation/whitespace.
                    let firstNonTrim = nsText.rangeOfCharacter(
                        from: trimSet.inverted, options: [], range: afterRange
                    )
                    let nameStart = firstNonTrim.location != NSNotFound
                        ? firstNonTrim.location
                        : afterPrefix
                    let nameRange = NSRange(location: nameStart, length: (name as NSString).length)
                    results.append(PIIMatch(text: name, range: nameRange, kind: .name,
                                           confidence: 0.65))
                }

                searchRange = NSRange(location: found.location + found.length,
                                     length: nsText.length - found.location - found.length)
            }
        }
        return results
    }

    // MARK: - Label Anchor Routes

    /// Confidence of every label-anchor match: the prefix pass's number. The
    /// conservative preset's cutoff drops them by design. The routes sit
    /// outside the inventory gate, as the prefix pass does, and say so
    /// through their own rule id and route signal.
    static let labelAnchorConfidence = 0.65

    /// Rule id every label-anchor match carries; the rationale's pattern
    /// signal names the route (`name.label-anchor.<route>`).
    static let labelAnchorRuleID = "name.label-anchor"

    /// Tokens that mark a capitalised run as an organisation rather than a
    /// person (case-folded, trailing period stripped). A candidate holding
    /// any of them is not read: in `Marcus Bellamy v. Sablebrook Holdings
    /// Inc.` only the left party is a name.
    static let organizationMarkers: Set<String> = [
        "inc", "incorporated", "corp", "corporation", "co", "company",
        "llc", "llp", "lp", "ltd", "limited", "plc", "pllc", "group",
        "holdings", "bank", "trust", "association", "partners",
        "partnership", "industries", "enterprises", "hospital", "clinic",
        "university", "college", "school", "county", "city", "state",
        "department", "board", "commission", "agency", "authority",
        "district", "bureau", "office", "services", "systems", "solutions",
        "technologies", "insurance", "foundation", "institute", "center",
        "fund", "union", "council", "court", "estate", "united", "national",
        "federal", "government", "unit", "division", "section", "branch",
        "team", "desk", "program",
    ]

    /// The caption connector between two parties, read case-folded and
    /// bounded by horizontal whitespace on both sides.
    private static let captionConnectors = ["v.", "vs."]

    /// A candidate a route read: one to three capitalised tokens on one line.
    private struct AnchorCandidate {
        let text: String
        let range: NSRange
        let tokens: [String]
    }

    private static let anchorTokenJoiners = CharacterSet(charactersIn: "'\u{2019}-.")

    private static func scalar(_ u: unichar) -> UnicodeScalar? { UnicodeScalar(u) }
    private static func isAnchorLetter(_ u: unichar) -> Bool {
        scalar(u).map { CharacterSet.letters.contains($0) } ?? false
    }
    private static func isAnchorUppercase(_ u: unichar) -> Bool {
        scalar(u).map { CharacterSet.uppercaseLetters.contains($0) } ?? false
    }
    private static func isAnchorAlphanumeric(_ u: unichar) -> Bool {
        scalar(u).map { CharacterSet.alphanumerics.contains($0) } ?? false
    }
    private static func isAnchorTokenChar(_ u: unichar) -> Bool {
        scalar(u).map { CharacterSet.letters.contains($0) || anchorTokenJoiners.contains($0) } ?? false
    }
    private static func isHorizontalSpace(_ u: unichar) -> Bool { u == 0x20 || u == 0x09 }

    /// Read forwards from `start`: skip horizontal whitespace, then take up
    /// to three tokens, each a maximal run of letters, apostrophes, hyphens
    /// and periods that opens with an uppercase letter, separated by
    /// horizontal whitespace only. A comma, a colon, a digit, a lowercase
    /// token or the line's end closes the reading.
    private static func readCandidate(
        forwardFrom start: Int, lineEnd: Int, in ns: NSString, minTokens: Int
    ) -> AnchorCandidate? {
        var i = start
        while i < lineEnd, isHorizontalSpace(ns.character(at: i)) { i += 1 }
        var ranges: [NSRange] = []
        while ranges.count < 3 {
            guard i < lineEnd, isAnchorUppercase(ns.character(at: i)) else { break }
            var j = i
            while j < lineEnd, isAnchorTokenChar(ns.character(at: j)) { j += 1 }
            ranges.append(NSRange(location: i, length: j - i))
            var k = j
            while k < lineEnd, isHorizontalSpace(ns.character(at: k)) { k += 1 }
            guard k > j else { break }
            i = k
        }
        return assemble(ranges, in: ns, minTokens: minTokens)
    }

    /// Read backwards from `end` (exclusive): the mirror of the forward
    /// reading, so the tokens closest to the anchor are taken first.
    private static func readCandidate(
        backwardFrom end: Int, lineStart: Int, in ns: NSString, minTokens: Int
    ) -> AnchorCandidate? {
        var i = end
        while i > lineStart, isHorizontalSpace(ns.character(at: i - 1)) { i -= 1 }
        var ranges: [NSRange] = []
        while ranges.count < 3 {
            guard i > lineStart, isAnchorTokenChar(ns.character(at: i - 1)) else { break }
            var j = i
            while j > lineStart, isAnchorTokenChar(ns.character(at: j - 1)) { j -= 1 }
            guard isAnchorUppercase(ns.character(at: j)) else { break }
            ranges.insert(NSRange(location: j, length: i - j), at: 0)
            var k = j
            while k > lineStart, isHorizontalSpace(ns.character(at: k - 1)) { k -= 1 }
            guard k < j else { break }
            i = k
        }
        return assemble(ranges, in: ns, minTokens: minTokens)
    }

    /// Join the token ranges into one candidate. A trailing period on a
    /// token of three or more letters is a sentence's, not the name's, and
    /// is left outside the box; an initial (`J.`) or a short suffix (`Jr.`)
    /// keeps its period.
    private static func assemble(_ ranges: [NSRange], in ns: NSString, minTokens: Int) -> AnchorCandidate? {
        guard ranges.count >= minTokens, let first = ranges.first, var last = ranges.last else { return nil }
        let lastText = ns.substring(with: last)
        if lastText.hasSuffix("."), lastText.filter(\.isLetter).count >= 3 {
            last = NSRange(location: last.location, length: last.length - 1)
        }
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var tokens = ranges.map { ns.substring(with: $0) }
        tokens[tokens.count - 1] = ns.substring(with: last)
        return AnchorCandidate(text: ns.substring(with: range), range: range, tokens: tokens)
    }

    /// Words that name a role, an honorific or a generic addressee rather
    /// than a person (case-folded, period-stripped): the legal prefixes, the
    /// stop tokens and the generic addressees, read on EVERY token of a
    /// candidate — `Records Officer` and `Hiring Committee` are titles, not
    /// names, whichever token carries the role word.
    private static let nonPersonTokens: Set<String> = {
        var set = Set<String>()
        for word in legalPrefixes + Array(nameStopTokens) + genericAddressees.flatMap({ $0.split(separator: " ").map(String.init) }) {
            var folded = word.lowercased()
            while folded.hasSuffix(".") { folded.removeLast() }
            if !folded.isEmpty { set.insert(folded) }
        }
        return set
    }()

    /// The candidate is a person's name only if it is not a stop token, does
    /// not open with a legal prefix or a stop token (the prefix pass's
    /// shape), holds no organisation marker and no role, honorific or
    /// generic-addressee word on any token, and carries at least one token
    /// of two or more letters.
    private static func admits(_ candidate: AnchorCandidate) -> Bool {
        guard !nameStopTokens.contains(candidate.text), let first = candidate.tokens.first else { return false }
        guard !legalPrefixes.contains(first), !nameStopTokens.contains(first) else { return false }
        for token in candidate.tokens {
            var folded = token.lowercased()
            while folded.hasSuffix(".") { folded.removeLast() }
            if organizationMarkers.contains(folded) || nonPersonTokens.contains(folded) { return false }
        }
        return candidate.tokens.contains { $0.filter(\.isLetter).count >= 2 }
    }

    private static func anchorMatch(_ candidate: AnchorCandidate, route: String) -> PIIMatch {
        PIIMatch(
            text: candidate.text, range: candidate.range, kind: .name,
            confidence: labelAnchorConfidence,
            rationale: MatchRationale(
                ruleID: labelAnchorRuleID,
                signals: [.regexPattern(name: "\(labelAnchorRuleID).\(route)")],
                preThresholdScore: labelAnchorConfidence,
                finalScore: labelAnchorConfidence
            )
        )
    }

    /// Pass 4 of `detect`: the label-anchor routes, one line at a time.
    /// The vocabulary of the label route is the legal prefixes plus the
    /// shipped name positives in scope for `doctype` (the court role words
    /// are court-scoped; with no doctype only the global rows read).
    /// Internal so the routes can be exercised on their own, apart from the
    /// tagger rows that win the overlap in `detect`.
    func scanLabelAnchors(in text: String, doctype: DoctypeClass? = nil) -> [PIIMatch] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var labels = Set(Self.legalPrefixes.map { $0.lowercased() })
        if let positives = contextLoader?.positiveKeywords(for: .name, doctype: doctype) {
            labels.formUnion(positives)
        }
        let orderedLabels = labels.sorted()
        var lines: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            lines.append(line)
        }
        var results: [PIIMatch] = []
        for (index, line) in lines.enumerated() where line.length > 0 {
            Self.scanLabelColon(in: ns, line: line, labels: orderedLabels, into: &results)
            Self.scanCaption(in: ns, line: line, into: &results)
            Self.scanClosingLine(in: ns, lines: lines, at: index, into: &results)
            Self.scanSalutation(in: ns, line: line, into: &results)
            Self.scanSubjectLine(in: ns, line: line, into: &results)
        }
        return results
    }

    /// Route 1a — a label from the vocabulary, matched case-folded and
    /// token-bounded (no letter or digit touches it on either side),
    /// optional horizontal whitespace, a colon, then the candidate.
    private static func scanLabelColon(
        in ns: NSString, line: NSRange, labels: [String], into results: inout [PIIMatch]
    ) {
        let lineEnd = NSMaxRange(line)
        for label in labels {
            var search = line
            while search.length > 0 {
                let hit = ns.range(of: label, options: [.caseInsensitive], range: search)
                guard hit.location != NSNotFound else { break }
                let after = NSMaxRange(hit)
                search = NSRange(location: after, length: lineEnd - after)
                if hit.location > line.location, isAnchorAlphanumeric(ns.character(at: hit.location - 1)) { continue }
                if after < lineEnd, isAnchorAlphanumeric(ns.character(at: after)) { continue }
                var i = after
                while i < lineEnd, isHorizontalSpace(ns.character(at: i)) { i += 1 }
                guard i < lineEnd, ns.character(at: i) == 0x3A else { continue }
                guard let candidate = readCandidate(forwardFrom: i + 1, lineEnd: lineEnd, in: ns, minTokens: 2),
                      admits(candidate) else { continue }
                results.append(anchorMatch(candidate, route: "label-colon"))
            }
        }
    }

    /// Route 1b — the caption connector with a candidate read backwards on
    /// its left and forwards on its right; each side is kept on its own.
    private static func scanCaption(in ns: NSString, line: NSRange, into results: inout [PIIMatch]) {
        let lineEnd = NSMaxRange(line)
        for connector in captionConnectors {
            var search = line
            while search.length > 0 {
                let hit = ns.range(of: connector, options: [.caseInsensitive], range: search)
                guard hit.location != NSNotFound else { break }
                let after = NSMaxRange(hit)
                search = NSRange(location: after, length: lineEnd - after)
                guard hit.location > line.location, isHorizontalSpace(ns.character(at: hit.location - 1)),
                      after < lineEnd, isHorizontalSpace(ns.character(at: after)) else { continue }
                if let left = readCandidate(backwardFrom: hit.location, lineStart: line.location, in: ns, minTokens: 2),
                   admits(left) {
                    results.append(anchorMatch(left, route: "caption"))
                }
                if let right = readCandidate(forwardFrom: after, lineEnd: lineEnd, in: ns, minTokens: 2),
                   admits(right) {
                    results.append(anchorMatch(right, route: "caption"))
                }
            }
        }
    }

    /// The closing phrases a letter signs off with, case-folded; the line
    /// that carries one ends with a comma and holds nothing else.
    private static let closingPhrases: Set<String> = [
        "sincerely", "regards", "best regards", "kind regards", "warm regards",
        "respectfully", "respectfully submitted", "yours truly",
        "very truly yours", "cordially", "best", "thank you", "thanks",
    ]

    /// How many blank lines may sit between the closing phrase and the
    /// signature line (room for a handwritten signature).
    private static let closingLineBlankLimit = 3

    /// True when the line is exactly a closing phrase followed by a comma.
    private static func isClosingPhraseLine(_ ns: NSString, _ line: NSRange) -> Bool {
        let text = ns.substring(with: line).trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix(",") else { return false }
        return closingPhrases.contains(String(text.dropLast()).trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Route 2 — the closing line: the first non-blank line after a
    /// closing-phrase line (at most `closingLineBlankLimit` blank lines
    /// skipped) is read when the candidate opens it and nothing but a
    /// comma-led suffix (`, Esq.`) or a period follows on that line.
    private static func scanClosingLine(
        in ns: NSString, lines: [NSRange], at index: Int, into results: inout [PIIMatch]
    ) {
        guard isClosingPhraseLine(ns, lines[index]) else { return }
        var next = index + 1
        var blanks = 0
        while next < lines.count, blanks <= closingLineBlankLimit {
            let line = lines[next]
            let trimmed = ns.substring(with: line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blanks += 1
                next += 1
                continue
            }
            let lineEnd = NSMaxRange(line)
            guard let candidate = readCandidate(forwardFrom: line.location, lineEnd: lineEnd, in: ns, minTokens: 2),
                  admits(candidate) else { return }
            var i = NSMaxRange(candidate.range)
            while i < lineEnd, isHorizontalSpace(ns.character(at: i)) { i += 1 }
            if i < lineEnd {
                let u = ns.character(at: i)
                guard u == 0x2C || u == 0x2E else { return }   // ',' or '.'
                if u == 0x2E, i + 1 < lineEnd { return }
            }
            results.append(anchorMatch(candidate, route: "closing-line"))
            return
        }
    }

    /// Generic addressees a salutation names instead of a person; a
    /// candidate equal to one of them (case-folded) is not read.
    private static let genericAddressees: Set<String> = [
        "sir", "madam", "sir or madam", "sirs", "customer", "valued customer",
        "member", "colleague", "colleagues", "team", "all", "friend", "friends",
        "parent", "parents", "guardian", "patient", "resident", "homeowner",
        "applicant", "candidate", "hiring manager", "committee", "editor",
        "doctor", "counsel", "client", "employee", "staff", "student",
        "occupant", "taxpayer",
    ]

    /// The subject-line labels, case-folded; the colon follows.
    private static let subjectLabels = ["re", "subject", "regarding"]

    /// Route 4a — the salutation: `Dear` at the line's start, then the
    /// candidate, closed by a comma, a colon or the line's end. A generic
    /// addressee (`Dear Sir or Madam,`) is not a name.
    private static func scanSalutation(in ns: NSString, line: NSRange, into results: inout [PIIMatch]) {
        let lineEnd = NSMaxRange(line)
        var i = line.location
        while i < lineEnd, isHorizontalSpace(ns.character(at: i)) { i += 1 }
        let dear = ns.range(of: "dear", options: [.caseInsensitive, .anchored], range: NSRange(location: i, length: lineEnd - i))
        guard dear.location != NSNotFound else { return }
        let after = NSMaxRange(dear)
        guard after < lineEnd, isHorizontalSpace(ns.character(at: after)) else { return }
        guard let candidate = readCandidate(forwardFrom: after, lineEnd: lineEnd, in: ns, minTokens: 1) else { return }
        var j = NSMaxRange(candidate.range)
        while j < lineEnd, isHorizontalSpace(ns.character(at: j)) { j += 1 }
        if j < lineEnd {
            let u = ns.character(at: j)
            guard u == 0x2C || u == 0x3A else { return }   // ',' or ':'
        }
        guard !genericAddressees.contains(candidate.text.lowercased()), admits(candidate) else { return }
        results.append(anchorMatch(candidate, route: "salutation"))
    }

    /// Route 4b — the subject line: `Re:` / `Subject:` / `Regarding:` at
    /// the line's start, and the candidate that CLOSES the line when a
    /// lower-case token stands right before it (`Re: Records pertaining to
    /// Jane Q. Public`); a subject in title case throughout is a title, not
    /// a name, and yields nothing.
    private static func scanSubjectLine(in ns: NSString, line: NSRange, into results: inout [PIIMatch]) {
        let lineEnd = NSMaxRange(line)
        var i = line.location
        while i < lineEnd, isHorizontalSpace(ns.character(at: i)) { i += 1 }
        var labelled = false
        for label in subjectLabels {
            let hit = ns.range(of: label, options: [.caseInsensitive, .anchored], range: NSRange(location: i, length: lineEnd - i))
            guard hit.location != NSNotFound else { continue }
            var k = NSMaxRange(hit)
            while k < lineEnd, isHorizontalSpace(ns.character(at: k)) { k += 1 }
            if k < lineEnd, ns.character(at: k) == 0x3A { labelled = true; i = k + 1; break }
        }
        guard labelled else { return }
        // The line's tail: drop trailing whitespace and one closing period.
        var end = lineEnd
        while end > i, isHorizontalSpace(ns.character(at: end - 1)) { end -= 1 }
        if end > i, ns.character(at: end - 1) == 0x2E {
            // A period that closes an initial or a suffix stays; a sentence's is dropped.
            var t = end - 1
            while t > i, isAnchorLetter(ns.character(at: t - 1)) { t -= 1 }
            if end - 1 - t >= 3 { end -= 1 }
        }
        guard let candidate = readCandidate(backwardFrom: end, lineStart: i, in: ns, minTokens: 2), admits(candidate) else { return }
        // The token before the candidate must be a lower-case word.
        var p = candidate.range.location
        while p > i, isHorizontalSpace(ns.character(at: p - 1)) { p -= 1 }
        guard p > i, p < candidate.range.location, isAnchorLetter(ns.character(at: p - 1)) else { return }
        var q = p
        while q > i, isAnchorTokenChar(ns.character(at: q - 1)) { q -= 1 }
        guard !isAnchorUppercase(ns.character(at: q)) else { return }
        results.append(anchorMatch(candidate, route: "subject-line"))
    }
}
