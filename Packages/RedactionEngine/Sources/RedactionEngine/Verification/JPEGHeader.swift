import Foundation

// The header of a page's stored picture, accepted by what it means rather
// than by a list of byte patterns. Accepted only when the picture is
// baseline sequential with eight bits a sample; has one component or three,
// sampled once or twice, brightness never below colour; has one frame and
// one scan that names every component; carries a JFIF header of 16 bytes
// whose thumbnail sides are zero, and no Adobe segment, so three components
// are brightness and two colour differences; defines every table before the
// scan uses it, once, and uses each; keeps every segment inside the stream;
// and puts no fill byte before a marker.
// Segments outside the admitted list are counted by kind and length, and
// admitted up to a named limit. Anything else is a refusal with its reason
// and the byte where it was met.

/// The reader's named limits.
enum PageImageLimits {
    /// The bytes of segments outside the admitted list one picture may carry,
    /// markers included. The app's writer adds two small ones today; once it
    /// stops, this becomes zero.
    static let unlistedSegmentBytes = 4_096
    /// The blocks one picture may declare. A frame over this is refused at
    /// its header, before any byte of its coded data is read.
    static let blocks = 4_000_000
}

/// One component as the header declares it, with the tables it names.
struct JPEGComponent: Equatable, Sendable {
    let id: Int
    let horizontal: Int
    let vertical: Int
    let quantiserTable: Int
    var dcTable = 0
    var acTable = 0
}

/// A Huffman table in the decoding form of the JPEG standard (its Annex C).
struct JPEGHuffmanTable: Sendable {
    var minCode = [Int](repeating: 0, count: 17)
    var maxCode = [Int](repeating: -1, count: 17)
    var valuePointer = [Int](repeating: 0, count: 17)
    let values: [UInt8]

    /// `counts[1...16]`: how many codes of each length.
    init?(counts: [Int], values: [UInt8]) {
        self.values = values
        var code = 0
        var k = 0
        for length in 1...16 {
            valuePointer[length] = k
            minCode[length] = code
            code += counts[length]
            k += counts[length]
            guard code <= (1 << length) else { return nil }
            maxCode[length] = counts[length] > 0 ? code - 1 : -1
            code <<= 1
        }
        guard k == values.count, k <= 256 else { return nil }
    }
}

struct JPEGHeader: Sendable {
    var width = 0
    var height = 0
    var components: [JPEGComponent] = []
    /// The step of the first coefficient, by quantiser table id.
    var dcStep: [Int: Int] = [:]
    var dcTables: [Int: JPEGHuffmanTable] = [:]
    var acTables: [Int: JPEGHuffmanTable] = [:]
    /// Block groups between restart markers; 0 when none is declared.
    var restartInterval = 0
    /// The first byte of the coded data.
    var scanStart = 0
    var unlistedSegments: [UnlistedSegment] = []

    var maxHorizontal: Int { components.map(\.horizontal).max() ?? 1 }
    var maxVertical: Int { components.map(\.vertical).max() ?? 1 }

    /// With one component the scan codes one block at a time; with three, a
    /// block group holds each component's blocks by its sampling.
    var groupsWide: Int {
        components.count == 1 ? (width + 7) / 8 : (width + 8 * maxHorizontal - 1) / (8 * maxHorizontal)
    }
    var groupsHigh: Int {
        components.count == 1 ? (height + 7) / 8 : (height + 8 * maxVertical - 1) / (8 * maxVertical)
    }
    var blockGroupCount: Int { groupsWide * groupsHigh }
    func blocksWide(_ c: Int) -> Int { components.count == 1 ? groupsWide : groupsWide * components[c].horizontal }
    func blocksHigh(_ c: Int) -> Int { components.count == 1 ? groupsHigh : groupsHigh * components[c].vertical }
    var blockCount: Int { components.indices.reduce(0) { $0 + blocksWide($1) * blocksHigh($1) } }

    private static let jfif: [UInt8] = Array("JFIF\0".utf8)
    private static let adobe: [UInt8] = Array("Adobe".utf8)

    /// Reads the header up to the first byte of the coded data.
    static func read(_ b: UnsafeBufferPointer<UInt8>) throws(PageImageRefusal) -> JPEGHeader {
        func refuse(_ reason: PageImageRefusal.Reason, _ offset: Int) -> PageImageRefusal {
            PageImageRefusal(reason: reason, offset: offset)
        }
        func starts(_ prefix: [UInt8], at p: Int, end: Int) -> Bool {
            p + prefix.count <= end && prefix.indices.allSatisfy { b[p + $0] == prefix[$0] }
        }
        var header = JPEGHeader()
        guard b.count >= 2, b[0] == 0xFF, b[1] == 0xD8 else { throw refuse(.noStartMarker, 0) }
        var i = 2
        var sawFrame = false, sawJFIF = false, sawRestart = false
        var quantDefined = Set<Int>(), dcDefined = Set<Int>(), acDefined = Set<Int>()
        var unlistedBytes = 0
        while true {
            guard i + 1 < b.count, b[i] == 0xFF else { throw refuse(.markerExpected, i) }
            let marker = b[i + 1]
            if marker == 0xFF { throw refuse(.fillByteBeforeMarker, i) }
            switch marker {
            case 0xD0...0xD9, 0x01: throw refuse(.markerNotAllowed, i)
            default: break
            }
            guard i + 4 <= b.count else { throw refuse(.segmentOutsideStream, i) }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { throw refuse(.segmentOutsideStream, i) }
            let body = i + 4
            let end = i + 2 + length

            switch marker {
            case 0xE0 where starts(jfif, at: body, end: end):
                if sawJFIF { throw refuse(.secondJFIFHeader, i) }
                // 16 bytes, no thumbnail, as the system encoder writes it. A
                // longer one carries bytes this reader would never read.
                guard length == 16 else { throw refuse(.jfifHeaderLength, i) }
                // Its last two bytes are the thumbnail's sides: a 16-byte
                // header has room for none, so both are zero.
                guard b[body + 12] == 0, b[body + 13] == 0 else { throw refuse(.jfifThumbnail, i) }
                sawJFIF = true
            case 0xEE where starts(adobe, at: body, end: end):
                throw refuse(.adobeSegment, i)
            case 0xE0...0xEF, 0xFE:
                header.unlistedSegments.append(UnlistedSegment(marker: marker, length: length + 2))
                unlistedBytes += length + 2
                if unlistedBytes > PageImageLimits.unlistedSegmentBytes { throw refuse(.unlistedSegmentsOverLimit, i) }

            case 0xDB:
                var p = body
                while p < end {
                    let precision = Int(b[p] >> 4), id = Int(b[p] & 15)
                    guard precision == 0, id <= 3, p + 65 <= end else { throw refuse(.quantiserTable, p) }
                    guard quantDefined.insert(id).inserted else { throw refuse(.tableDefinedTwice, p) }
                    for k in 1...64 where b[p + k] == 0 { throw refuse(.quantiserStepZero, p) }
                    header.dcStep[id] = Int(b[p + 1])
                    p += 65
                }

            case 0xC4:
                var p = body
                while p < end {
                    guard p + 17 <= end else { throw refuse(.huffmanTable, p) }
                    let kind = Int(b[p] >> 4), id = Int(b[p] & 15)
                    guard kind <= 1, id <= 1 else { throw refuse(.huffmanTable, p) }
                    var counts = [Int](repeating: 0, count: 17)
                    var total = 0
                    for n in 1...16 { counts[n] = Int(b[p + n]); total += counts[n] }
                    guard p + 17 + total <= end,
                          let table = JPEGHuffmanTable(counts: counts, values: Array(b[(p + 17)..<(p + 17 + total)])) else {
                        throw refuse(.huffmanTable, p)
                    }
                    let inserted = kind == 0 ? dcDefined.insert(id).inserted : acDefined.insert(id).inserted
                    guard inserted else { throw refuse(.tableDefinedTwice, p) }
                    if kind == 0 { header.dcTables[id] = table } else { header.acTables[id] = table }
                    p += 17 + total
                }

            case 0xC0:
                if sawFrame { throw refuse(.secondFrame, i) }
                sawFrame = true
                guard length >= 8 else { throw refuse(.componentCount, i) }
                guard b[body] == 8 else { throw refuse(.precisionNotEightBits, body) }
                let count = Int(b[body + 5])
                guard count == 1 || count == 3, length == 8 + 3 * count else { throw refuse(.componentCount, body + 5) }
                header.height = Int(b[body + 1]) << 8 | Int(b[body + 2])
                header.width = Int(b[body + 3]) << 8 | Int(b[body + 4])
                guard header.width > 0, header.height > 0 else { throw refuse(.frameSideZero, body + 1) }
                for c in 0..<count {
                    let q = body + 6 + 3 * c
                    let h = Int(b[q + 1] >> 4), v = Int(b[q + 1] & 15), tq = Int(b[q + 2])
                    guard (1...2).contains(h), (1...2).contains(v) else { throw refuse(.samplingFactor, q) }
                    guard tq <= 3 else { throw refuse(.quantiserTable, q) }
                    guard !header.components.contains(where: { $0.id == Int(b[q]) }) else { throw refuse(.componentCount, q) }
                    header.components.append(JPEGComponent(id: Int(b[q]), horizontal: h, vertical: v, quantiserTable: tq))
                }
                if count == 3 {
                    let y = header.components[0]
                    for colour in header.components.dropFirst()
                    where colour.horizontal > y.horizontal || colour.vertical > y.vertical {
                        throw refuse(.colourSampledAboveBrightness, body + 6)
                    }
                    guard header.components.reduce(0, { $0 + $1.horizontal * $1.vertical }) <= 10 else {
                        throw refuse(.samplingFactor, body + 6)
                    }
                }
                guard header.blockCount <= PageImageLimits.blocks else { throw refuse(.tooManyBlocks, i) }

            case 0xC1...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                throw refuse(.notBaselineSequential, i)

            case 0xDD:
                guard length == 4, !sawRestart else { throw refuse(.restartDefinition, i) }
                sawRestart = true
                header.restartInterval = Int(b[body]) << 8 | Int(b[body + 1])

            case 0xDA:
                guard sawFrame else { throw refuse(.scanBeforeFrame, i) }
                // The component count is read only from inside the segment.
                guard length >= 3 else { throw refuse(.scanNotEveryComponent, i) }
                let count = Int(b[body])
                guard count == header.components.count, length == 6 + 2 * count else {
                    throw refuse(.scanNotEveryComponent, i)
                }
                for c in 0..<count {
                    let q = body + 1 + 2 * c
                    guard Int(b[q]) == header.components[c].id else { throw refuse(.scanNotEveryComponent, q) }
                    let td = Int(b[q + 1] >> 4), ta = Int(b[q + 1] & 15)
                    guard td <= 1, ta <= 1 else { throw refuse(.huffmanTable, q) }
                    header.components[c].dcTable = td
                    header.components[c].acTable = ta
                }
                let q = body + 1 + 2 * count
                guard b[q] == 0, b[q + 1] == 63, b[q + 2] == 0 else { throw refuse(.scanNotSequential, q) }
                guard sawJFIF else { throw refuse(.noJFIFHeader, i) }
                for component in header.components {
                    guard quantDefined.contains(component.quantiserTable), dcDefined.contains(component.dcTable),
                          acDefined.contains(component.acTable) else {
                        throw refuse(.tableNotDefined, i)
                    }
                }
                guard quantDefined == Set(header.components.map(\.quantiserTable)),
                      dcDefined == Set(header.components.map(\.dcTable)),
                      acDefined == Set(header.components.map(\.acTable)) else {
                    throw refuse(.tableNeverUsed, i)
                }
                header.scanStart = end
                return header

            default:
                throw refuse(.markerNotAllowed, i)
            }
            i = end
        }
    }
}
