import Darwin
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// Search's ink-fit content key reads a page's largest image without undoing
// its filter: a JPEG alone by its stored bytes, any other image by its
// dictionary's facts. A Flate stream that inflates to gigabytes is never
// inflated for the key. The fixture pages carry a hidden text layer over a
// page-scale image declared 2550 x 3300 x 8 bit, stored under FlateDecode,
// that inflates to 512 MiB or 2 GiB.

@Suite("Ink-fit key: an image is read by its dictionary, never inflated", .serialized)
struct InkTokenKeyInflateTests {
    static let mid512m = 512 * 1_048_576
    static let bomb2g = 2 * 1_073_741_824
    /// The key step's bound: the whole process's peak footprint.
    static let bound: UInt64 = 100 * 1_048_576

    /// The process's footprint now and its peak (the number jetsam reads).
    static func footprint() -> (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (UInt64(info.phys_footprint), UInt64(max(0, info.ledger_phys_footprint_peak)))
    }

    static func page(_ data: Data) throws -> (PDFPage, CGPDFPage) {
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        return (page, try #require(page.pageRef))
    }

    static func key(_ data: Data) throws -> Int {
        let (page, cgPage) = try page(data)
        return InkTokenCache.key(page: page, cgPage: cgPage, visual: page.bounds(for: .cropBox).size)
    }

    /// Builds the page, takes its key, and answers whether the process's peak
    /// footprint stayed under the bound. Run alone in a child process, so the
    /// peak is the key step's own (with the fixture and the test runner).
    static func keyStepStaysUnderTheBound(inflatedTo count: Int) -> Bool {
        let data = TestFixtures.inflatingImagePage(inflatedTo: count)
        guard let document = PDFDocument(data: data), let page = document.page(at: 0), let cgPage = page.pageRef else {
            return false
        }
        _ = InkTokenCache.key(page: page, cgPage: cgPage, visual: page.bounds(for: .cropBox).size)
        let peak = footprint().peak
        print("[ink-key-inflate] inflates to \(count) B: key step peak footprint \(peak / 1_048_576) MiB, bound \(bound / 1_048_576) MiB")
        return peak > 0 && peak < bound
    }

    /// Where no child process can be started: the step's rise over this
    /// process's own peak and footprint so far.
    static func keyStepRiseIsUnderTheBound(inflatedTo count: Int) -> Bool {
        let data = TestFixtures.inflatingImagePage(inflatedTo: count)
        guard let document = PDFDocument(data: data), let page = document.page(at: 0), let cgPage = page.pageRef else {
            return false
        }
        let before = footprint()
        _ = InkTokenCache.key(page: page, cgPage: cgPage, visual: page.bounds(for: .cropBox).size)
        let after = footprint()
        return after.peak > 0 && after.peak <= max(before.peak, before.now + bound)
    }

    // MARK: - The fixtures are what they claim

    @Test("Each fixture's image stream inflates to its named size, past 200 MiB", arguments: [mid512m, bomb2g])
    func fixtureInflates(count: Int) throws {
        let stream = TestFixtures.zlibOfRepeatedByte(0x80, count: count)
        #expect(stream.count > 0 && stream.count < 4 * 1_048_576, "stored \(stream.count) B")
        let inflated = try #require(TestFixtures.inflatedCount(ofZlib: stream), "the stream decodes")
        #expect(inflated == count)
        #expect(inflated > 200 * 1_048_576)
    }

    // MARK: - The key step stays bounded

    @Test("The key of a page whose image inflates to 512 MiB is taken under 100 MB")
    func keyStepBoundedMid512m() async {
        #if os(macOS)
        await #expect(processExitsWith: .success) {
            guard InkTokenKeyInflateTests.keyStepStaysUnderTheBound(inflatedTo: InkTokenKeyInflateTests.mid512m) else { exit(1) }
        }
        #else
        #expect(Self.keyStepRiseIsUnderTheBound(inflatedTo: Self.mid512m))
        #endif
    }

    @Test("The key of a page whose image inflates to 2 GiB is taken under 100 MB")
    func keyStepBoundedBomb2g() async {
        #if os(macOS)
        await #expect(processExitsWith: .success) {
            guard InkTokenKeyInflateTests.keyStepStaysUnderTheBound(inflatedTo: InkTokenKeyInflateTests.bomb2g) else { exit(1) }
        }
        #else
        #expect(Self.keyStepRiseIsUnderTheBound(inflatedTo: Self.bomb2g))
        #endif
    }

    // MARK: - What the key tells apart

    @Test("Two Flate pages alike but for the image's stored /Length get different keys, and pages alike in every fact the same key")
    func flateImageKeyedByItsFacts() throws {
        let stream = TestFixtures.zlibOfRepeatedByte(0x80, count: TestFixtures.inflatingImageWidth * TestFixtures.inflatingImageHeight)
        var sameLength = stream
        sameLength[sameLength.count - 1] ^= 0x01
        let longer = stream + Data([0x00])
        let base = try Self.key(TestFixtures.flateImagePage(stream: stream))
        #expect(try Self.key(TestFixtures.flateImagePage(stream: longer)) != base, "a different /Length")
        #expect(try Self.key(TestFixtures.flateImagePage(stream: sameLength)) == base, "every dictionary fact alike")
    }

    @Test("Two JPEG pages with equal dictionaries and different stored bytes get different keys")
    func jpegImageKeyedByItsBytes() throws {
        let jpeg = Data([0xFF, 0xD8] + [UInt8](repeating: 0x00, count: 60) + [0xFF, 0xD9])
        var other = jpeg
        other[31] = 0x01
        let first = try Self.key(TestFixtures.pdfWithDCTImageStream(jpeg))
        #expect(try Self.key(TestFixtures.pdfWithDCTImageStream(other)) != first)
        #expect(try Self.key(TestFixtures.pdfWithDCTImageStream(jpeg)) == first, "the same bytes, the same key")
    }

    // MARK: - The gate is unchanged

    @Test("A page whose image inflates to 2 GiB still carries hidden text over an image, so the ink fit still runs")
    func gateStillOpens() throws {
        let (page, cgPage) = try Self.page(TestFixtures.inflatingImagePage(inflatedTo: Self.bomb2g))
        #expect(DocumentSearcher.carriesHiddenTextOverImage(page, cgPage: cgPage))
    }
}
