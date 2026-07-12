import Testing
import Foundation
@testable import ResectaApp

// Pkg G.1 / TRUST-import-drop-image-deadcode: drop handler routing was
// hardcoded to `suggestedType: "pdf"`, leaving the image branch dead on
// the drag-and-drop entry point. These tests pin the magic-byte sniffer
// (`ImportService.detectPayloadKind(from:)`) used by the drop handler to
// pick the routing label before dispatch.

@Suite("ImportService magic-byte routing", .tags(.importFlow))
struct ImportServiceMagicBytesTests {

    // MARK: - Image signatures

    @Test("JPEG SOI routes to image branch")
    func testJPEGDropRoutesToImageBranch() {
        // JPEG starts with FF D8 FF <application-marker>. JFIF uses E0,
        // EXIF uses E1; the sniffer only inspects the first three bytes.
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

        #expect(ImportService.detectPayloadKind(from: data) == .image)
        #expect(ImportService.detectPayloadKind(from: data).suggestedType == "image")
    }

    @Test("PNG signature routes to image branch")
    func testPNGDropRoutesToImageBranch() {
        // PNG magic: 89 50 4E 47 0D 0A 1A 0A
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        #expect(ImportService.detectPayloadKind(from: data) == .image)
        #expect(ImportService.detectPayloadKind(from: data).suggestedType == "image")
    }

    @Test("WEBP signature routes to image branch")
    func testWEBPDropRoutesToImageBranch() {
        // RIFF <size:4> WEBP — first 12 bytes. Size field is little-endian
        // but content here is irrelevant to the sniffer.
        let data = Data([
            0x52, 0x49, 0x46, 0x46, // "RIFF"
            0x00, 0x00, 0x00, 0x00, // size (placeholder)
            0x57, 0x45, 0x42, 0x50  // "WEBP"
        ])

        #expect(ImportService.detectPayloadKind(from: data) == .image)
    }

    @Test("RIFF without WEBP brand does not route to image")
    func testRIFFWithoutWEBPDoesNotRouteToImage() {
        // RIFF container with a non-WEBP brand (e.g., "WAVE" for audio) must
        // not be misclassified as an image payload.
        let data = Data([
            0x52, 0x49, 0x46, 0x46, // "RIFF"
            0x00, 0x00, 0x00, 0x00,
            0x57, 0x41, 0x56, 0x45  // "WAVE"
        ])

        #expect(ImportService.detectPayloadKind(from: data) == .unknown)
    }

    @Test("HEIC ftyp box routes to image branch")
    func testHEICDropRoutesToImageBranch() {
        // ISO BMFF: <box-size:4> "ftyp" <brand:4>. Brand "heic" identifies
        // a HEIC still image.
        let data = Data([
            0x00, 0x00, 0x00, 0x18, // box size (24)
            0x66, 0x74, 0x79, 0x70, // "ftyp"
            0x68, 0x65, 0x69, 0x63  // "heic"
        ])

        #expect(ImportService.detectPayloadKind(from: data) == .image)
    }

    @Test("HEIC variant brand heix routes to image branch")
    func testHEICVariantBrandRoutesToImageBranch() {
        let data = Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x68, 0x65, 0x69, 0x78  // "heix"
        ])

        #expect(ImportService.detectPayloadKind(from: data) == .image)
    }

    @Test("ftyp with non-image brand does not route to image")
    func testFtypNonImageBrandDoesNotRouteToImage() {
        // ftyp box with an unrecognized brand (e.g., "isom" for ISO MP4)
        // should fall through to `.unknown` rather than land on the image
        // branch.
        let data = Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x69, 0x73, 0x6F, 0x6D  // "isom"
        ])

        #expect(ImportService.detectPayloadKind(from: data) == .unknown)
    }

    // MARK: - PDF signature

    @Test("%PDF magic bytes route to pdf branch")
    func testPDFMagicBytesRouteToPDFBranch() {
        // %PDF-1.7 header — sniffer only inspects the first four bytes.
        let data = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37])

        #expect(ImportService.detectPayloadKind(from: data) == .pdf)
        #expect(ImportService.detectPayloadKind(from: data).suggestedType == "pdf")
    }

    // MARK: - Fallback

    @Test("Unknown payload falls back to pdf suggestedType")
    func testUnknownPayloadFallsBackToPDFSuggestedType() {
        // Random bytes don't match any signature — the routing label
        // defaults to "pdf" so the import path's own %PDF check has a
        // chance to reject, preserving prior behavior for the unknown
        // case.
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])

        #expect(ImportService.detectPayloadKind(from: data) == .unknown)
        #expect(ImportService.detectPayloadKind(from: data).suggestedType == "pdf")
    }

    @Test("Tiny payload below signature length returns unknown")
    func testTinyPayloadReturnsUnknown() {
        // Three bytes is too short for any recognized signature except
        // JPEG SOI (which is exactly three bytes). Two bytes always falls
        // through to `.unknown`.
        let data = Data([0xAB, 0xCD])

        #expect(ImportService.detectPayloadKind(from: data) == .unknown)
    }

    @Test("Empty payload returns unknown")
    func testEmptyPayloadReturnsUnknown() {
        let data = Data()

        #expect(ImportService.detectPayloadKind(from: data) == .unknown)
    }
}
