import Foundation
import CoreGraphics

/// The finished file read back before it is kept. After the writer's own
/// values are replaced (`PDFStreamReconstructor.overwriteInfoLiteralsReporting`
/// and `overwriteFileIdentifier`), the file is read again as a whole, and it
/// replaces the output only when all four rules hold:
///
/// - M1: the information dictionary's `/Producer`, `/CreationDate` and
///   `/ModDate` read exactly the fixed values;
/// - M2: the trailer's `/ID` is two strings, each the identifier derived from
///   the file's own bytes;
/// - M3: none of the writer's own values is left in the file: (a) no whole
///   value, in any of the spellings below, anywhere in its bytes, and (b) after
///   each fixed value's closing parenthesis, only white space up to the next
///   key or the dictionary's end, so no rest of an old value stays beside it;
/// - M4: a file the read-back cannot read never passes.
///
/// It checks the result, not the steps that made it. Named limits: a value
/// inside a compressed stream is read only where the same bytes also stand
/// uncompressed (the writer never compresses its dictionary); a source
/// document that itself carries one of the writer's exact values uncompressed
/// stops its export (the safe direction).
package enum MetaReadBack {

    /// What the read-back saw. It never carries a value from the file.
    package enum Outcome: Hashable, Sendable {
        case held
        case valuesNotFixed
        case identifierNotDerived
        case originalLeft
        case unreadable
    }

    /// The writer's own values, read before they are replaced, as the byte
    /// strings M3 looks for. Held in memory for the one read-back and never
    /// written, logged or recorded: they name the system build and the moment
    /// the file was written.
    package struct Originals: Sendable {
        fileprivate let needles: [Data]
        fileprivate let complete: Bool
        package static let none = Originals(needles: [], complete: false)
    }

    /// The shortest byte string M3 looks for; the writer's shortest value
    /// today is a 23-byte date.
    static let shortestNeedle = 8

    static let fixedKeys = ["Producer", "CreationDate", "ModDate"]

    /// The writer's three values and its `/ID` pair, as read through the
    /// system reader. `complete` is false unless all five strings were read.
    package static func originals(of url: URL) -> Originals {
        guard let doc = CGPDFDocument(url as CFURL), let info = doc.info else { return .none }
        // `info` and the strings read through it point into `doc`, which
        // nothing below names: it is held until the reading is done.
        defer { withExtendedLifetime(doc) {} }
        var needles: [Data] = []
        var read = 0
        for key in fixedKeys {
            var ref: CGPDFStringRef?
            guard CGPDFDictionaryGetString(info, key, &ref), let ref, let bytes = stringBytes(ref) else { continue }
            read += 1
            needles.append(bytes)
            needles.append(literalSpelling(bytes))
            if let text = CGPDFStringCopyTextString(ref) { needles.append(Data((text as String).utf8)) }
        }
        if let pair = doc.fileIdentifier, CGPDFArrayGetCount(pair) == 2 {
            for index in 0..<2 {
                var ref: CGPDFStringRef?
                guard CGPDFArrayGetString(pair, index, &ref), let ref, let bytes = stringBytes(ref) else { continue }
                read += 1
                let hex = bytes.map { String(format: "%02x", $0) }.joined()
                needles.append(Data(hex.utf8))
                needles.append(Data(hex.uppercased().utf8))
            }
        }
        var unique: [Data] = []
        for needle in needles where needle.count >= shortestNeedle && !unique.contains(needle) {
            unique.append(needle)
        }
        return Originals(needles: unique, complete: read == fixedKeys.count + 2)
    }

    /// The four rules over the file at `url`, in order; the first that does
    /// not hold is the outcome.
    package static func check(url: URL, originals: Originals) -> Outcome {
        guard originals.complete,
              let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider) else { return .unreadable }
        // `info`, `pair` and their strings point into `doc`: it is held until
        // the four rules are read.
        defer { withExtendedLifetime(doc) {} }

        // M1.
        guard let info = doc.info else { return .valuesNotFixed }
        let fixed = [PDFStreamReconstructor.fixedProducerValue,
                     PDFStreamReconstructor.fixedDateValue, PDFStreamReconstructor.fixedDateValue]
        for (key, value) in zip(fixedKeys, fixed) {
            var ref: CGPDFStringRef?
            guard CGPDFDictionaryGetString(info, key, &ref), let ref,
                  let text = CGPDFStringCopyTextString(ref) else { return .valuesNotFixed }
            var read = text as String
            while read.hasSuffix(" ") { read.removeLast() }
            guard read == value else { return .valuesNotFixed }
        }

        // M2.
        guard let pair = doc.fileIdentifier, CGPDFArrayGetCount(pair) == 2,
              let derived = PDFFileIdentifier.recomputedIdentifier(for: data) else { return .identifierNotDerived }
        for index in 0..<2 {
            var ref: CGPDFStringRef?
            guard CGPDFArrayGetString(pair, index, &ref), let ref, stringBytes(ref) == derived else {
                return .identifierNotDerived
            }
        }

        // M3 (a): no whole value anywhere.
        for needle in originals.needles where data.range(of: needle) != nil { return .originalLeft }
        // M3 (b): only white space after each fixed value, up to the next key.
        for (key, value) in zip(fixedKeys, fixed) {
            guard onlySpaceAfter(key: key, value: value, in: data) else { return .originalLeft }
        }
        return .held
    }

    /// True when `/key (value)` stands in `data` at least once, and after
    /// each such literal's closing parenthesis only PDF white space comes
    /// before the next `/` or `>`.
    static func onlySpaceAfter(key: String, value: String, in data: Data) -> Bool {
        let keyBytes = Data("/\(key)".utf8)
        let literal = Data("(\(value))".utf8)
        var seen = false
        var from = data.startIndex
        while let hit = data.range(of: keyBytes, in: from..<data.endIndex) {
            from = hit.upperBound
            var index = hit.upperBound
            while index < data.endIndex, isSpace(data[index]) { index += 1 }
            guard index + literal.count <= data.endIndex,
                  data[index..<(index + literal.count)] == literal else { continue }
            seen = true
            index += literal.count
            while index < data.endIndex, data[index] != 0x2F, data[index] != 0x3E {  // "/" and ">"
                guard isSpace(data[index]) else { return false }
                index += 1
            }
        }
        return seen
    }

    static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x0C || byte == 0x00
    }

    /// The string's bytes as stored, after the reader undoes the file's escapes.
    static func stringBytes(_ ref: CGPDFStringRef) -> Data? {
        guard let pointer = CGPDFStringGetBytePtr(ref) else { return nil }
        return Data(bytes: pointer, count: CGPDFStringGetLength(ref))
    }

    /// The bytes as a literal string spells them: backslash and both
    /// parentheses escaped, as the writer writes its values.
    static func literalSpelling(_ bytes: Data) -> Data {
        var out = Data(capacity: bytes.count + 8)
        for byte in bytes {
            if byte == 0x5C || byte == 0x28 || byte == 0x29 { out.append(0x5C) }
            out.append(byte)
        }
        return out
    }
}
