import CoreGraphics
import Foundation
import RedactionCore
import Testing
@testable import RedactionEngine

// The reader of each page's stored picture: its header by meaning, the walk
// of its coded data, the one image of a page accepted by its recorded hash
// and placed in the checked file. These are the cases of the check's table
// that need no box; they keep their numbers in that table, which the box
// package completes.

@Suite("A page's stored picture is read as the file stores it, or refused by name")
struct PageImageReadTests {

    typealias F = PageImageFixtures
    typealias Reason = PageImageRefusal.Reason

    struct Case: Sendable, CustomTestStringConvertible {
        let number: Int
        let name: String
        let body: @Sendable () async throws -> Void
        var testDescription: String { "\(number): \(name)" }
    }

    static let pageSize = CGSize(width: 612, height: 792)

    /// A Letter page's picture at the size the cases use.
    static func page(mark: Int = 0, gray: Bool = false, noise: Bool = false, blank: Bool = false) -> Data {
        F.encode(F.madePage(width: 1275, height: 1650, gray: gray, mark: mark, noise: noise, blank: blank))
    }

    static func walked(_ jpeg: Data) throws -> PageImageWalk {
        switch try JPEGEntropyWalk.walk(jpeg) {
        case .success(let walk): return walk
        case .failure(let refusal): throw TestFailure("refused: \(refusal)")
        }
    }

    static func refusal(_ jpeg: Data) throws -> PageImageRefusal? {
        if case .failure(let r) = try JPEGEntropyWalk.walk(jpeg) { return r }
        return nil
    }

    static func expectRefused(_ jpeg: Data, _ reason: Reason, _ label: String) throws {
        let r = try refusal(jpeg)
        print("PAGEIMAGE \(label): \(r.map { "\($0.reason.rawValue) at \($0.offset)" } ?? "accepted")")
        #expect(r?.reason == reason, "\(label): \(String(describing: r))")
    }

    static func readExport(_ file: Data, hashes: [Data]?) throws -> PageImageReport {
        let source = try #require(SystemPageImageSource(fileData: file))
        return try PageImageLocator.read(fileData: file, source: source, recordedHashes: hashes)
    }

    static func pages(_ report: PageImageReport) throws -> [PageImageOutcome] {
        guard case .pages(let pages) = report else { throw TestFailure("no record") }
        return pages
    }

    static func walk(_ outcome: PageImageOutcome) -> PageImageWalk? {
        if case .completed(let w) = outcome { return w }
        return nil
    }

    static func reason(_ outcome: PageImageOutcome) -> Reason? {
        if case .couldNotFinish(let r) = outcome { return r.reason }
        return nil
    }

    struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static let cases: [Case] = [
        Case(number: 5, name: "a page picture of 6,000 by 4,001 pixels is read; its block groups are the declared ones", body: {
            let w = try walked(F.encode(F.madePage(width: 6_000, height: 4_001, mark: 5)))
            let across = w.components.map(\.horizontal).max()!, down = w.components.map(\.vertical).max()!
            #expect(w.width == 6_000 && w.height == 4_001)
            #expect(w.blockGroupCount == ((6_000 + 8 * across - 1) / (8 * across)) * ((4_001 + 8 * down - 1) / (8 * down)))
            #expect(w.blocks.indices.allSatisfy { w.blocks[$0].count == w.blocksWide[$0] * w.blocksHigh[$0] })
            print("PAGEIMAGE 5: groups \(w.blockGroupCount), sampling \(w.components.map { "\($0.horizontal)x\($0.vertical)" }), restarts \(w.restartCount), unlisted \(w.unlistedSegments.map { "\(String($0.marker, radix: 16)):\($0.length)" })")
        }),
        Case(number: 6, name: "a one-component page picture is read, and says it has no colour", body: {
            let w = try walked(page(gray: true))
            #expect(w.components.count == 1 && !w.hasColour)
            #expect(w.blockGroupCount == w.blocksWide[0] * w.blocksHigh[0])
        }),
        Case(number: 7, name: "two blank pages and two like scanned pages are read in both modes, shared or not", body: {
            let blank = page(blank: true), scan = page(mark: 7, noise: true)
            for searchable in [false, true] {
                let pictures = [blank, blank, scan, scan]
                let file = try await F.export(pictures, size: pageSize, searchable: searchable)
                let outcomes = try pages(readExport(file, hashes: pictures.map(F.sha256)))
                #expect(outcomes.count == 4 && outcomes.allSatisfy { walk($0) != nil },
                        "searchable \(searchable): \(outcomes.map { reason($0)?.rawValue ?? "completed" })")
            }
        }),
        Case(number: 12, name: "an export with no boxes: every page is read", body: {
            let pictures = (0..<3).map { page(mark: 12 + $0) }
            let outcomes = try pages(readExport(try await F.export(pictures, size: pageSize), hashes: pictures.map(F.sha256)))
            #expect(outcomes.count == 3)
            for (i, o) in outcomes.enumerated() {
                #expect(walk(o)?.sha256 == F.sha256(pictures[i]), "page \(i + 1): \(String(describing: reason(o)))")
            }
        }),
        Case(number: 20, name: "the stream cut short; one byte after the end marker; the coded data zeroed", body: {
            let jpeg = page(mark: 20)
            let last = try #require(F.restartMarkers(jpeg).last, "the writer's picture carries restart markers")
            var cut = jpeg
            cut.removeSubrange(last..<F.codedData(jpeg).upperBound)
            try expectRefused(cut, .scanCutShort, "20 cut short at its last restart, its end marker kept")
            try expectRefused(jpeg.prefix(jpeg.count - 200), .scanCutShort, "20 cut short, no end marker")
            try expectRefused(jpeg + [0x00], .bytesAfterEndMarker, "20 a byte after the end")
            var zeroed = jpeg
            zeroed.replaceSubrange(F.codedData(jpeg), with: [UInt8](repeating: 0, count: F.codedData(jpeg).count))
            // Zeros decode as codes of the writer's tables until the first
            // restart, where a zero stands in place of the marker.
            try expectRefused(zeroed, .restartMarkerOrder, "20 zeroed")
        }),
        Case(number: 21, name: "a progressive picture; a 12-bit picture", body: {
            let jpeg = page(mark: 21)
            let frame = F.segment(0xC0, in: jpeg)
            try expectRefused(F.setting(frame.at + 1, to: 0xC2, in: jpeg), .notBaselineSequential, "21 progressive")
            try expectRefused(F.setting(frame.at + 4, to: 12, in: jpeg), .precisionNotEightBits, "21 twelve bits")
        }),
        Case(number: 22, name: "an Adobe segment; a table defined twice; a table never used; a fill byte before a marker", body: {
            let jpeg = page(mark: 22)
            let afterJFIF = F.segment(0xE0, in: jpeg).at + F.segment(0xE0, in: jpeg).length
            let adobe = F.segmentBytes(0xEE, body: Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, 1])
            try expectRefused(F.inserting(adobe, at: afterJFIF, in: jpeg), .adobeSegment, "22 Adobe")
            let dqt = F.segment(0xDB, in: jpeg)
            let firstTable = [UInt8](jpeg[(dqt.at + 4)..<(dqt.at + 4 + 65)])
            try expectRefused(F.inserting(F.segmentBytes(0xDB, body: firstTable), at: dqt.at, in: jpeg), .tableDefinedTwice, "22 defined twice")
            let unused = [0x03] + [UInt8](repeating: 1, count: 64)
            try expectRefused(F.inserting(F.segmentBytes(0xDB, body: unused), at: dqt.at, in: jpeg), .tableNeverUsed, "22 never used")
            try expectRefused(F.inserting([0xFF], at: F.segment(0xC0, in: jpeg).at, in: jpeg), .fillByteBeforeMarker, "22 fill byte")
        }),
        Case(number: 23, name: "unlisted segments of more than 4,096 bytes", body: {
            let jpeg = page(mark: 23)
            let comment = F.segmentBytes(0xFE, body: [UInt8](repeating: 0x41, count: PageImageLimits.unlistedSegmentBytes))
            try expectRefused(F.inserting(comment, at: F.segment(0xC0, in: jpeg).at, in: jpeg), .unlistedSegmentsOverLimit, "23 unlisted")
            #expect(PageImageLimits.unlistedSegmentBytes == 4_096)
        }),
        Case(number: 24, name: "one byte changed in a page picture: the hash differs", body: {
            let pictures = (0..<3).map { page(mark: 24 + $0) }
            var file = try await F.export(pictures, size: pageSize)
            let second = try #require(PageImageLocator.place(pictures[1], in: file, from: 0, avoiding: []))
            let at = second.lowerBound + F.codedData(pictures[1]).lowerBound + 100
            file[at] = file[at] == 0x11 ? 0x12 : 0x11
            let outcomes = try pages(readExport(file, hashes: pictures.map(F.sha256)))
            #expect(walk(outcomes[0]) != nil && walk(outcomes[2]) != nil)
            #expect(reason(outcomes[1]) == .hashDiffers)
            #expect(outcomes[1].kind == .fault(.wrongSubject))
        }),
        Case(number: 25, name: "a page with two pictures; a picture whose bytes are nowhere in the checked file", body: {
            let a = page(mark: 25), b = page(mark: 26)
            let two = F.pageWithTwoImages(a, b, size: pageSize)
            let outcomes = try pages(readExport(two, hashes: [F.sha256(a)]))
            #expect(reason(outcomes[0]) == .twoPageImages)
            #expect(outcomes[0].kind == .fault(.unreadableInput))
            let file = try await F.export([a], size: pageSize)
            let elsewhere = GivenPageImageSource(pages: [[PageImageStream(bytes: b, isJPEG: true)]])
            let report = try PageImageLocator.read(fileData: file, source: elsewhere, recordedHashes: [F.sha256(b)])
            let missing = try pages(report)[0]
            #expect(reason(missing) == .bytesNotInFile)
            #expect(missing.kind == .fault(.wrongSubject))
        }),
        Case(number: 26, name: "no record of the run: one answer for the document", body: {
            let report = try readExport(try await F.export([page(mark: 27)], size: pageSize), hashes: nil)
            guard case .noRecord = report else { throw TestFailure("pages read without a record") }
            #expect(report.outcomes.count == 1)
            #expect(report.outcomes[0].unit == .document && report.outcomes[0].kind == .fault(.noRecord))
            #expect(report.outcomes[0].kind.rowClass != .passed)
        }),
        Case(number: 28, name: "restart markers swapped; the restart definition removed while the markers stay", body: {
            let jpeg = page(mark: 28)
            let markers = F.restartMarkers(jpeg)
            try #require(markers.count >= 2, "the writer's picture carries restart markers")
            var swapped = jpeg
            swapped.swapAt(markers[0] + 1, markers[1] + 1)
            try expectRefused(swapped, .restartMarkerOrder, "28 swapped")
            try expectRefused(F.removing(F.segment(0xDD, in: jpeg), from: jpeg), .restartMarkerNotDeclared, "28 no definition")
        }),
    ]

    @Test("The table holds twelve cases")
    func tableLength() {
        #expect(Self.cases.count == 12)
        #expect(Set(Self.cases.map(\.number)).count == 12)
    }

    @Test("Each case", arguments: PageImageReadTests.cases)
    func row(_ c: Case) async throws {
        try await c.body()
    }

    @Test("A header that declares more than 4,000,000 blocks is refused before any byte of its coded data")
    func tooManyBlocksAtTheHeader() throws {
        let jpeg = Self.page(mark: 30)
        let frame = F.segment(0xC0, in: jpeg)
        var big = jpeg
        big.replaceSubrange((frame.at + 5)..<(frame.at + 9), with: [0xFF, 0xFF, 0xFF, 0xFF])
        let r = try #require(try Self.refusal(big))
        #expect(r.reason == .tooManyBlocks)
        #expect(r.offset < F.codedData(jpeg).lowerBound, "refused at the header")
        #expect(PageImageLimits.blocks == 4_000_000)
    }

    @Test("The four lines of the page check's table, as data, against the result")
    func outcomesReadAsTheTable() {
        let wrongSubject: Set<Reason> = [.noRecordedHash, .hashDiffers, .bytesNotInFile]
        for reason in Reason.allCases {
            let kind = PageImageOutcome.couldNotFinish(PageImageRefusal(reason: reason, offset: 0)).kind
            #expect(kind == .fault(wrongSubject.contains(reason) ? .wrongSubject : .unreadableInput), "\(reason)")
            #expect(kind.rowClass == .couldNotVerify)
        }
        #expect(PageImageReport.noRecord.outcomes.map(\.unit) == [.document])
        #expect(PageImageReport.noRecord.outcomes.map(\.kind) == [.fault(.noRecord)])
        #expect(PageImageReport.noRecord.outcomes[0].kind.rowClass == .skipped)
    }

    @Test("Only the walker's file can make the seal a walk needs")
    func onlyTheWalkerBuildsAWalk() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RedactionEngine")
        let walker = try String(contentsOf: sources.appendingPathComponent("Verification/JPEGEntropyWalk.swift"), encoding: .utf8)
        #expect(walker.contains("struct Seal: Sendable {\n        fileprivate init() {}\n    }"), "the seal's only initialiser is the walker's own")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        try #require(files.count > 100, "the engine's sources were read")
        for file in files where file.lastPathComponent != "JPEGEntropyWalk.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("Seal()"), "\(file.lastPathComponent) makes a seal")
        }
    }

    @Test("A 200-page export locates every page in under 5 seconds")
    func twoHundredPagesLocated() async throws {
        let pictures = (0..<200).map { Self.page(mark: 1_000 + $0) }
        let file = try await F.export(pictures, size: Self.pageSize)
        let clock = ContinuousClock()
        var located = 0
        let elapsed = try clock.measure {
            let source = try #require(SystemPageImageSource(fileData: file))
            var cursor = 0
            var claimed: [Range<Int>] = []
            for index in 0..<source.pageCount {
                let image = source.images(onPage: index)
                guard image.count == 1, F.sha256(image[0].bytes) == F.sha256(pictures[index]),
                      let range = PageImageLocator.place(image[0].bytes, in: file, from: cursor, avoiding: claimed) else { continue }
                claimed.append(range)
                cursor = range.upperBound
                located += 1
            }
        }
        print("PAGEIMAGE 200 pages located in \(elapsed), file \(file.count) bytes")
        #expect(located == 200)
        #expect(elapsed < .seconds(5))
    }

    @Test("The checks hand this reader the run's record", .disabled("waits on the position check's package, which adds the checks' parameter for the run's record"))
    func readerTakesTheRecordFromTheChecks() {
        Issue.record("Nothing hands the reader the run's record yet: the checks have no parameter for it.")
    }

    @Test("Each page's picture is hashed as it is encoded and kept in the run's record", .disabled("waits on the run's record type merging; the hash is kept nowhere else meanwhile"))
    func hashKeptInTheRecordAtTheSource() {
        Issue.record("The writer does not yet keep each page's SHA-256 in the run's record.")
    }
}
