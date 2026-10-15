import Testing
import Foundation
@testable import ResectaApp

// The router reads a payload's leading bytes and never the type a caller
// declares. These tests pin the sniffer (`ImportRouter.kind(of:)`) the drop
// door and the import share, and the drop door's admission rule.

@Suite("Import magic-byte routing", .tags(.importFlow))
struct ImportServiceMagicBytesTests {

    // MARK: - Image signatures

    @Test("JPEG SOI is the JPEG image signature")
    func testJPEGSignature() {
        // JPEG starts with FF D8 FF <application-marker>. JFIF uses E0,
        // EXIF uses E1; the sniffer only inspects the first three bytes.
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

        #expect(ImportRouter.kind(of: data) == .image(.jpeg))
    }

    @Test("PNG signature is the PNG image signature")
    func testPNGSignature() {
        // PNG magic: 89 50 4E 47 0D 0A 1A 0A
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        #expect(ImportRouter.kind(of: data) == .image(.png))
    }

    @Test("WEBP signature is an unsupported image")
    func testWEBPSignature() {
        // RIFF <size:4> WEBP — first 12 bytes. Size field is little-endian
        // but content here is irrelevant to the sniffer.
        let data = Data([
            0x52, 0x49, 0x46, 0x46, // "RIFF"
            0x00, 0x00, 0x00, 0x00, // size (placeholder)
            0x57, 0x45, 0x42, 0x50  // "WEBP"
        ])

        #expect(ImportRouter.kind(of: data) == .unsupportedImage)
    }

    @Test("RIFF without WEBP brand is not an image")
    func testRIFFWithoutWEBPIsNotAnImage() {
        // RIFF container with a non-WEBP brand (e.g., "WAVE" for audio) must
        // not be misclassified as an image payload.
        let data = Data([
            0x52, 0x49, 0x46, 0x46, // "RIFF"
            0x00, 0x00, 0x00, 0x00,
            0x57, 0x41, 0x56, 0x45  // "WAVE"
        ])

        #expect(ImportRouter.kind(of: data) == .unknown)
    }

    @Test("HEIC ftyp box is the HEIC image signature")
    func testHEICSignature() {
        // ISO BMFF: <box-size:4> "ftyp" <brand:4>. Brand "heic" identifies
        // a HEIC still image.
        let data = Data([
            0x00, 0x00, 0x00, 0x18, // box size (24)
            0x66, 0x74, 0x79, 0x70, // "ftyp"
            0x68, 0x65, 0x69, 0x63  // "heic"
        ])

        #expect(ImportRouter.kind(of: data) == .image(.heic))
    }

    @Test("HEIC variant brand heix is the HEIC image signature")
    func testHEICVariantBrand() {
        let data = Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x68, 0x65, 0x69, 0x78  // "heix"
        ])

        #expect(ImportRouter.kind(of: data) == .image(.heic))
    }

    @Test("ftyp with non-image brand is not an image")
    func testFtypNonImageBrandIsNotAnImage() {
        // ftyp box with an unrecognized brand (e.g., "isom" for ISO MP4)
        // should fall through to `.unknown` rather than read as an image.
        let data = Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x69, 0x73, 0x6F, 0x6D  // "isom"
        ])

        #expect(ImportRouter.kind(of: data) == .unknown)
    }

    // MARK: - PDF signature

    @Test("%PDF magic bytes are the PDF signature")
    func testPDFMagicBytes() {
        // %PDF-1.7 header — sniffer only inspects the first four bytes.
        let data = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37])

        #expect(ImportRouter.kind(of: data) == .pdf)
    }

    // MARK: - Fallback

    @Test("Unknown payload is unknown and reaches the PDF parser")
    func testUnknownPayloadReachesThePDFParser() throws {
        // Random bytes match no signature. The PDF loader takes them, so
        // the parser's own %PDF check has the chance to refuse.
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])

        #expect(ImportRouter.kind(of: data) == .unknown)
        #expect(try ImportRouter.route(data: data) is PDFImportLoader)
    }

    @Test("Tiny payload below signature length returns unknown")
    func testTinyPayloadReturnsUnknown() {
        // Three bytes is too short for any recognized signature except
        // JPEG SOI (which is exactly three bytes) and BMP's two-byte
        // "BM". Two unrelated bytes fall through to `.unknown`.
        let data = Data([0xAB, 0xCD])

        #expect(ImportRouter.kind(of: data) == .unknown)
    }

    @Test("Empty payload returns unknown")
    func testEmptyPayloadReturnsUnknown() {
        let data = Data()

        #expect(ImportRouter.kind(of: data) == .unknown)
    }

    // MARK: - The drop door (PDF files only)

    @Test("Image payloads are refused at the drop door")
    func testImagePayloadsRefusedAtDoor() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let heic = Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x68, 0x65, 0x69, 0x63  // "heic"
        ])
        let webp = Data([
            0x52, 0x49, 0x46, 0x46,
            0x00, 0x00, 0x00, 0x00,
            0x57, 0x45, 0x42, 0x50  // "WEBP"
        ])

        #expect(!ImportRouter.admitsDroppedPayload(jpeg), "a JPEG drop must be refused")
        #expect(!ImportRouter.admitsDroppedPayload(png), "a PNG drop must be refused")
        #expect(!ImportRouter.admitsDroppedPayload(heic), "a HEIC drop must be refused")
        #expect(!ImportRouter.admitsDroppedPayload(webp), "a WEBP drop must be refused")
    }

    @Test("A %PDF payload is admitted at the drop door")
    func testPDFPayloadAdmittedAtDoor() {
        let data = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37])

        #expect(ImportRouter.admitsDroppedPayload(data))
    }

    @Test("An unknown payload is admitted at the drop door and reaches the PDF parser")
    func testUnknownPayloadAdmittedAtDoor() throws {
        // A PDF whose `%PDF` header is not at offset 0 sniffs as unknown;
        // refusing unknown bytes would refuse it. The PDF parser reports
        // anything it cannot open.
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])

        #expect(ImportRouter.admitsDroppedPayload(data))
        #expect(try ImportRouter.route(data: data) is PDFImportLoader)
    }
}
