import CryptoKit
import Foundation

// The walk of a page picture's coded data, block by block, without decoding
// to pixels. It decodes exactly the block groups the frame declares; meets
// restart markers in order at the declared interval and none where no
// interval is declared; and ends on the end marker with no byte left.
// Padding bits that are not ones are counted, not refused. For every block it
// keeps the mean level (the first coefficient times the file's own step) and
// whether the block is flat (no other coefficient is non-zero). Every reason
// to stop is returned as a value; only cancellation is thrown.

enum JPEGEntropyWalk {

    /// Made only in this file: a `PageImageWalk` needs one, so no other code
    /// can build a walk.
    struct Seal: Sendable {
        fileprivate init() {}
    }

    /// The largest first coefficient a baseline picture can carry: 11 bits.
    static let firstCoefficientLimit = 2_047

    private enum Stop: Error {
        case refused(PageImageRefusal)
        case cancelled
    }

    /// Reads one page picture as the file stores it.
    static func walk(_ jpeg: Data) throws(CancellationError) -> Result<PageImageWalk, PageImageRefusal> {
        let result: Result<PageImageWalk, Stop> = jpeg.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            do throws(Stop) { return .success(try decode(bytes, sha256: Data(SHA256.hash(data: raw)))) } catch {
                return .failure(error)
            }
        }
        switch result {
        case .success(let walk): return .success(walk)
        case .failure(.refused(let refusal)): return .failure(refusal)
        case .failure(.cancelled): throw CancellationError()
        }
    }

    private struct BitReader {
        let bytes: UnsafeBufferPointer<UInt8>
        let restartsDeclared: Bool
        var position: Int
        var current: UInt8 = 0
        var bitsLeft = 0

        mutating func bit() throws(Stop) -> Int {
            if bitsLeft == 0 {
                guard position < bytes.count else { throw refused(.scanCutShort, position) }
                let byte = bytes[position]
                if byte == 0xFF {
                    guard position + 1 < bytes.count else { throw refused(.scanCutShort, position) }
                    switch bytes[position + 1] {
                    case 0x00: position += 2
                    case 0xFF: throw refused(.fillByteBeforeMarker, position)
                    case 0xD9: throw refused(.scanCutShort, position)
                    case 0xD0...0xD7:
                        throw refused(restartsDeclared ? .restartMarkerOrder : .restartMarkerNotDeclared, position)
                    default: throw refused(.markerInsideScan, position)
                    }
                } else {
                    position += 1
                }
                current = byte
                bitsLeft = 8
            }
            bitsLeft -= 1
            return Int((current >> UInt8(bitsLeft)) & 1)
        }

        mutating func bits(_ count: Int) throws(Stop) -> Int {
            var value = 0
            for _ in 0..<count { value = (value << 1) | (try bit()) }
            return value
        }

        /// Drops the rest of the current byte; true when every dropped bit was 1.
        mutating func alignToByte() -> Bool {
            let mask = (1 << bitsLeft) - 1
            let allOnes = (Int(current) & mask) == mask
            bitsLeft = 0
            return allOnes
        }
    }

    private static func refused(_ reason: PageImageRefusal.Reason, _ offset: Int) -> Stop {
        .refused(PageImageRefusal(reason: reason, offset: offset))
    }

    private static func symbol(_ reader: inout BitReader, _ table: JPEGHuffmanTable) throws(Stop) -> Int {
        var code = 0
        for length in 1...16 {
            code = (code << 1) | (try reader.bit())
            if table.maxCode[length] >= 0 && code <= table.maxCode[length] && code >= table.minCode[length] {
                let index = table.valuePointer[length] + code - table.minCode[length]
                guard index < table.values.count else { throw refused(.huffmanCodeNotInTable, reader.position) }
                return Int(table.values[index])
            }
        }
        throw refused(.huffmanCodeNotInTable, reader.position)
    }

    private static func extend(_ value: Int, _ size: Int) -> Int {
        size == 0 ? 0 : (value < (1 << (size - 1)) ? value - (1 << size) + 1 : value)
    }

    /// The restart marker a reader at `p` must meet: the next in order, with
    /// no fill byte before it. The end marker here means the stream ended
    /// before every block group the frame declares was read.
    private static func expectRestart(_ b: UnsafeBufferPointer<UInt8>, at p: Int, number: Int) throws(Stop) {
        guard p + 1 < b.count else { throw refused(.scanCutShort, p) }
        guard b[p] == 0xFF else { throw refused(.restartMarkerOrder, p) }
        if b[p + 1] == 0xFF { throw refused(.fillByteBeforeMarker, p) }
        if b[p + 1] == 0xD9 { throw refused(.scanCutShort, p) }
        guard Int(b[p + 1]) == 0xD0 + number else { throw refused(.restartMarkerOrder, p) }
    }

    private static func decode(_ b: UnsafeBufferPointer<UInt8>, sha256: Data) throws(Stop) -> PageImageWalk {
        let header: JPEGHeader
        do throws(PageImageRefusal) { header = try JPEGHeader.read(b) } catch { throw .refused(error) }
        let components = header.components
        let wide = components.indices.map { header.blocksWide($0) }
        let high = components.indices.map { header.blocksHigh($0) }
        // One component: a block group is one block. Three: each component's
        // blocks by its sampling.
        let single = components.count == 1
        var blocks = components.indices.map { [CodedBlock](repeating: CodedBlock(dcTimesStep: 0, flat: true), count: wide[$0] * high[$0]) }
        let dcTables = components.map { header.dcTables[$0.dcTable]! }
        let acTables = components.map { header.acTables[$0.acTable]! }
        let steps = components.map { header.dcStep[$0.quantiserTable]! }
        var reader = BitReader(bytes: b, restartsDeclared: header.restartInterval > 0, position: header.scanStart)
        var predictors = [Int](repeating: 0, count: components.count)
        var nextRestart = 0
        var restartCount = 0
        var paddingNotOnes = 0
        let columns = header.groupsWide
        let total = header.blockGroupCount

        for group in 0..<total {
            if group % columns == 0 && Task.isCancelled { throw .cancelled }
            if header.restartInterval > 0 && group > 0 && group % header.restartInterval == 0 {
                if !reader.alignToByte() { paddingNotOnes += 1 }
                try expectRestart(b, at: reader.position, number: nextRestart)
                reader.position += 2
                nextRestart = (nextRestart + 1) & 7
                restartCount += 1
                for c in predictors.indices { predictors[c] = 0 }
            }
            let gx = group % columns, gy = group / columns
            for c in components.indices {
                let across = single ? 1 : components[c].horizontal
                let down = single ? 1 : components[c].vertical
                for v in 0..<down {
                    for h in 0..<across {
                        let size = try symbol(&reader, dcTables[c])
                        guard size <= 11 else { throw refused(.coefficientSize, reader.position) }
                        predictors[c] += extend(try reader.bits(size), size)
                        // A baseline picture's first coefficient fits in 11
                        // bits (its largest difference is 2,047): a running
                        // sum past that is no 8-bit picture, refused before
                        // it is multiplied by the step.
                        guard abs(predictors[c]) <= JPEGEntropyWalk.firstCoefficientLimit else {
                            throw refused(.coefficientSize, reader.position)
                        }
                        var k = 1
                        var flat = true
                        while k < 64 {
                            let rs = try symbol(&reader, acTables[c])
                            let run = rs >> 4, bitSize = rs & 15
                            if bitSize == 0 {
                                if run == 0 { break }
                                guard run == 15, k + 16 <= 63 else { throw refused(.coefficientRun, reader.position) }
                                k += 16
                                continue
                            }
                            guard bitSize <= 10 else { throw refused(.coefficientSize, reader.position) }
                            k += run
                            guard k < 64 else { throw refused(.coefficientRun, reader.position) }
                            _ = try reader.bits(bitSize)
                            flat = false
                            k += 1
                        }
                        let index = (gy * down + v) * wide[c] + gx * across + h
                        blocks[c][index] = CodedBlock(dcTimesStep: Int32(predictors[c] * steps[c]), flat: flat)
                    }
                }
            }
        }
        if !reader.alignToByte() { paddingNotOnes += 1 }
        let p = reader.position
        guard p + 1 < b.count else { throw refused(.noEndMarker, p) }
        if b[p] == 0xFF && b[p + 1] == 0xFF { throw refused(.fillByteBeforeMarker, p) }
        guard b[p] == 0xFF, b[p + 1] == 0xD9 else { throw refused(.noEndMarker, p) }
        guard p + 2 == b.count else { throw refused(.bytesAfterEndMarker, p + 2) }
        return PageImageWalk(
            seal: Seal(), width: header.width, height: header.height,
            components: components.map { FrameComponent(id: $0.id, horizontal: $0.horizontal, vertical: $0.vertical) },
            blockGroupCount: total, restartCount: restartCount, bytesConsumed: p + 2, sha256: sha256,
            unlistedSegments: header.unlistedSegments, paddingNotOnes: paddingNotOnes,
            blocks: blocks, blocksWide: wide, blocksHigh: high)
    }
}
