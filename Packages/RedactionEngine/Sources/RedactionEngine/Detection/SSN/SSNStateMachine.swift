import Foundation

// A6: Linear-time SSN candidate scanner over UnicodeScalars.
// O(n) — no regex, bypasses the per-page 5 s timeout (SEARCH_AND_REDACT §9.4).

/// A candidate SSN span extracted by the state machine.
public struct SSNCandidate: Sendable {
    /// Three-digit area number (digits only).
    public let area: String
    /// Two-digit group number (digits only).
    public let group: String
    /// Four-digit serial number (digits only).
    public let serial: String
    /// Range in the original string (NSRange for compatibility with PIIMatch).
    public let range: NSRange
    /// The separator character used, or nil for unseparated.
    public let separator: Character?
    /// The full matched text including separators.
    public let matchedText: String
}

/// Linear-time state machine that scans text for SSN-shaped sequences.
/// Produces raw candidates — structural validation and context scoring
/// are applied downstream by SSNStructuralValidator and ContextWindowScorer.
public struct SSNStateMachine: Sendable {

    public init() {}

    // Characters recognized as SSN separators (hyphen-minus, space, typographic dashes).
    private static let separators: Set<Character> = [
        "-",            // U+002D hyphen-minus
        " ",            // U+0020 space
        "\u{2011}",     // non-breaking hyphen
        "\u{2012}",     // figure dash
        "\u{2013}",     // en-dash
        "\u{2014}",     // em-dash
    ]

    private enum State {
        case idle
        case area(digits: String, start: String.Index)
        case separator1(area: String, sep: Character, start: String.Index)
        case group(digits: String, area: String, sep: Character?, start: String.Index)
        case separator2(area: String, group: String, sep: Character?, start: String.Index)
        case serial(digits: String, area: String, group: String, sep: Character?, start: String.Index)
    }

    /// Scan text and return all SSN-shaped candidate spans.
    /// Boundary enforcement: candidates preceded or followed by a digit are rejected.
    public func scan(_ text: String) -> [SSNCandidate] {
        guard !text.isEmpty else { return [] }

        var candidates: [SSNCandidate] = []
        var state = State.idle

        for index in text.indices {
            let char = text[index]
            let isDigit = char.isWholeNumber

            switch state {
            case .idle:
                if isDigit {
                    state = .area(digits: String(char), start: index)
                }

            case .area(let digits, let start):
                if isDigit {
                    let newDigits = digits + String(char)
                    if newDigits.count == 3 {
                        // Area complete — look for separator or group digit
                        state = .group(digits: "", area: newDigits, sep: nil, start: start)
                    } else {
                        state = .area(digits: newDigits, start: start)
                    }
                } else {
                    // Not a digit — reset
                    state = .idle
                    continue
                }

            case .group(let digits, let area, let sep, let start) where digits.isEmpty:
                // We just finished reading area — next can be separator or first group digit
                if isDigit {
                    // No separator (unseparated format)
                    state = .group(digits: String(char), area: area, sep: sep, start: start)
                } else if Self.separators.contains(char) && sep == nil {
                    // First separator
                    state = .separator1(area: area, sep: char, start: start)
                } else {
                    state = .idle
                    continue
                }

            case .separator1(let area, let sep, let start):
                if isDigit {
                    state = .group(digits: String(char), area: area, sep: sep, start: start)
                } else {
                    // Expected a digit after separator
                    state = .idle
                    continue
                }

            case .group(let digits, let area, let sep, let start):
                if isDigit {
                    let newDigits = digits + String(char)
                    if newDigits.count == 2 {
                        // Group complete — look for separator2 or serial digit
                        state = .serial(digits: "", area: area, group: newDigits, sep: sep, start: start)
                    } else {
                        state = .group(digits: newDigits, area: area, sep: sep, start: start)
                    }
                } else {
                    state = .idle
                    continue
                }

            case .serial(let digits, let area, let group, let sep, let start) where digits.isEmpty:
                // Just finished group — next can be separator2 or first serial digit
                if isDigit {
                    // No second separator (must match first: both nil for unseparated)
                    if sep == nil {
                        state = .serial(digits: String(char), area: area, group: group, sep: sep, start: start)
                    } else {
                        // Had a first separator but no second — separator mismatch
                        // Restart: this digit might be the start of a new area
                        state = .area(digits: String(char), start: index)
                    }
                } else if Self.separators.contains(char) {
                    // Second separator — must match first
                    if char == sep {
                        state = .separator2(area: area, group: group, sep: sep, start: start)
                    } else {
                        // Separator mismatch
                        state = .idle
                        continue
                    }
                } else {
                    state = .idle
                    continue
                }

            case .separator2(let area, let group, let sep, let start):
                if isDigit {
                    state = .serial(digits: String(char), area: area, group: group, sep: sep, start: start)
                } else {
                    state = .idle
                    continue
                }

            case .serial(let digits, let area, let group, let sep, let start):
                if isDigit {
                    let newDigits = digits + String(char)
                    if newDigits.count == 4 {
                        // Serial complete — check trailing boundary
                        let afterIndex = text.index(after: index)
                        let followedByDigit = afterIndex < text.endIndex && text[afterIndex].isWholeNumber

                        // Check leading boundary: digit before area start
                        let precededByDigit: Bool
                        if start > text.startIndex {
                            let beforeStart = text.index(before: start)
                            precededByDigit = text[beforeStart].isWholeNumber
                        } else {
                            precededByDigit = false
                        }

                        if !precededByDigit && !followedByDigit {
                            let matchedText = String(text[start...index])
                            let nsRange = NSRange(start...index, in: text)
                            candidates.append(SSNCandidate(
                                area: area,
                                group: group,
                                serial: newDigits,
                                range: nsRange,
                                separator: sep,
                                matchedText: matchedText
                            ))
                        }
                        state = .idle
                    } else {
                        state = .serial(digits: newDigits, area: area, group: group, sep: sep, start: start)
                    }
                } else {
                    // Non-digit before 4 serial digits — not an SSN
                    state = .idle
                    continue
                }

            }

        }

        return candidates
    }
}
