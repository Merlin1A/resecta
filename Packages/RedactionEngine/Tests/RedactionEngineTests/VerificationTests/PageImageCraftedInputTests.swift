import Foundation
import Testing
@testable import RedactionEngine

// The reader of a page's stored picture given bytes no system encoder makes:
// each case below stopped the process or read past the stream, or followed
// forms without end, before the reader refused it by name. The reasons are
// compared by their names, so each case reads the same against any reader.
// Also here: the block table each walk keeps, value by value and place by
// place.

@Suite("A page's stored picture, crafted by hand, is read or refused by name")
struct PageImageCraftedInputTests {

    typealias C = CraftedPageImages

    static func walk(_ jpeg: Data) throws -> Result<PageImageWalk, PageImageRefusal> {
        try JPEGEntropyWalk.walk(jpeg)
    }

    static func reasonName(_ jpeg: Data) throws -> String? {
        if case .failure(let r) = try walk(jpeg) { return r.reason.rawValue }
        return nil
    }

    /// The one page's outcome of a hand-written file.
    static func pageOutcome(_ file: Data, picture: Data) throws -> (reason: String?, completed: Bool) {
        let source = try #require(SystemPageImageSource(fileData: file))
        let report = try PageImageLocator.read(fileData: file, source: source, recordedHashes: [C.sha256(picture)])
        guard case .pages(let pages) = report, pages.count == 1 else { throw CraftedFailure("not one page") }
        switch pages[0] {
        case .completed: return (nil, true)
        case .couldNotFinish(let r): return (r.reason.rawValue, false)
        }
    }

    struct CraftedFailure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    // MARK: - The block table

    @Test("Each block keeps its first coefficient times the step, and whether every other is zero, at its own place")
    func blockTableValuesAndPlaces() throws {
        let differences = [5, -3, 0, 7, -12, 2]
        let seconds = [false, true, false, false, true, false]
        let blocks = zip(differences, seconds).map { C.Block(difference: $0, second: $1) }
        let jpeg = C.picture(columns: 3, rows: 2, step: 4, blocks: blocks)
        guard case .success(let w) = try Self.walk(jpeg) else { throw CraftedFailure("refused: \(try Self.reasonName(jpeg) ?? "")") }
        #expect(w.blocksWide == [3] && w.blocksHigh == [2])
        // Running sums 5, 2, 2, 9, -3, -1, times the step 4.
        #expect(w.blocks[0].map(\.dcTimesStep) == [20, 8, 8, 36, -12, -4])
        #expect(w.blocks[0].map(\.flat) == [true, false, true, true, false, true])
    }

    @Test("A white page from the system encoder: every block flat, every block at one level near white")
    func whitePageEveryBlockFlat() throws {
        let F = PageImageFixtures.self
        let jpeg = F.encode(F.madePage(width: 160, height: 96, gray: true, blank: true))
        guard case .success(let w) = try Self.walk(jpeg) else { throw CraftedFailure("refused: \(try Self.reasonName(jpeg) ?? "")") }
        let levels = Set(w.blocks[0].map(\.dcTimesStep))
        print("PAGEIMAGE white page: blocks \(w.blocks[0].count), levels \(levels.sorted())")
        #expect(w.blocks[0].count == 20 * 12)
        #expect(w.blocks[0].allSatisfy { $0.flat })
        #expect(levels.count == 1)
        // White, 255, is 8 × 127 = 1,016 after the level shift; the step rounds it.
        #expect(levels.allSatisfy { abs(Int($0) - 1_016) <= 16 })
    }

    // MARK: - The first coefficient's running sum

    @Test("A first coefficient of 2,047 is read; a running sum past it is refused by name")
    func firstCoefficientLimit() throws {
        let at = C.picture(columns: 1, rows: 1, step: 1, blocks: [C.Block(difference: 2_047)])
        guard case .success(let w) = try Self.walk(at) else { throw CraftedFailure("2,047 refused") }
        #expect(w.blocks[0].map(\.dcTimesStep) == [2_047])
        let past = C.picture(columns: 2, rows: 1, step: 1, blocks: [C.Block(difference: 2_047), C.Block(difference: 1)])
        #expect(try Self.reasonName(past) == "coefficientSize")
        let below = C.picture(columns: 2, rows: 1, step: 1, blocks: [C.Block(difference: -2_047), C.Block(difference: -1)])
        #expect(try Self.reasonName(below) == "coefficientSize")
    }

    @Test("A first coefficient summed past 32 bits once multiplied by the step is refused, not a stopped process")
    func firstCoefficientNeverOverflows() throws {
        // 4,200 blocks of +2,047 at step 255: the sum times the step passes
        // Int32's largest value at about block 4,114.
        let blocks = [C.Block](repeating: C.Block(difference: 2_047), count: 60 * 70)
        let jpeg = C.picture(columns: 60, rows: 70, step: 255, blocks: blocks)
        #expect(try Self.reasonName(jpeg) == "coefficientSize")
    }

    // MARK: - The scan header at the end of the stream

    @Test("A scan header with no byte after its length, at the very end of the stream, is refused within the stream")
    func scanHeaderCutAtTheEnd() throws {
        let head = C.header(columns: 1, rows: 1, step: 1)
        let jpeg = Data(head + [0xFF, 0xDA, 0x00, 0x02])
        let r = try #require(try { if case .failure(let r) = try Self.walk(jpeg) { return r }; return nil }())
        #expect(r.reason.rawValue == "scanNotEveryComponent")
        #expect(r.offset == head.count)
    }

    // MARK: - Forms

    static let picture = C.picture(columns: 1, rows: 1, step: 1, blocks: [C.Block(difference: 3)])

    /// A chain of `length` forms, each naming the next; the last names the picture.
    static func chain(_ length: Int) -> [C.Form] {
        (0..<length).map { i in i == length - 1 ? C.Form(namesPicture: true) : C.Form(names: [i + 1]) }
    }

    @Test("A second picture inside 8 nested forms is seen; inside 9 the page is refused, never read as one picture")
    func formsNestedPastTheLimit() throws {
        let eight = C.formsPage(picture: Self.picture, columns: 1, rows: 1, pageForms: [0], forms: Self.chain(8))
        #expect(try Self.pageOutcome(eight, picture: Self.picture).reason == "twoPageImages")
        let nine = C.formsPage(picture: Self.picture, columns: 1, rows: 1, pageForms: [0], forms: Self.chain(9))
        let outcome = try Self.pageOutcome(nine, picture: Self.picture)
        #expect(!outcome.completed, "a picture past the depth limit went unseen")
        #expect(outcome.reason == "formsOverLimit")
    }

    @Test("Forms named past 64 refuse the page; 64 are read")
    func formsNamedPastTheLimit() throws {
        let empty = [C.Form](repeating: C.Form(), count: 65)
        let sixtyFour = C.formsPage(picture: Self.picture, columns: 1, rows: 1, pageForms: Array(0..<64), forms: empty)
        #expect(try Self.pageOutcome(sixtyFour, picture: Self.picture).completed)
        let sixtyFive = C.formsPage(picture: Self.picture, columns: 1, rows: 1, pageForms: Array(0..<65), forms: empty)
        #expect(try Self.pageOutcome(sixtyFive, picture: Self.picture).reason == "formsOverLimit")
    }

    @Test("A form that names itself six times over is refused after at most 64 visits, in well under a second")
    func formNamingItselfIsBounded() throws {
        let selfNaming = C.formsPage(picture: Self.picture, columns: 1, rows: 1, pageForms: [0],
                                     forms: [C.Form(names: [0, 0, 0, 0, 0, 0])])
        let clock = ContinuousClock()
        var reason: String?
        let elapsed = try clock.measure { reason = try Self.pageOutcome(selfNaming, picture: Self.picture).reason }
        print("PAGEIMAGE self-naming form: \(reason ?? "completed") in \(elapsed)")
        #expect(reason == "formsOverLimit")
        #expect(elapsed < .seconds(1))
    }
}
