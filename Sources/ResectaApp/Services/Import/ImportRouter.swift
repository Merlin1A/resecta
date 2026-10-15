import Foundation
import RedactionEngine

/// Decides a payload's route from its leading bytes. The type a door
/// declares is never consulted. Resecta opens PDF files only: every image
/// signature meets the unsupported-format refusal before any decode;
/// `%PDF` and unknown payloads reach the PDF parser, which decides.
nonisolated enum ImportRouter {

    /// An image format a later loader may decode. Refused today.
    enum ImageFormat: Sendable, Equatable {
        case jpeg
        case png
        /// The HEIC/HEIF family of ISO BMFF still-image brands.
        case heic
    }

    /// What the first bytes say a payload is.
    enum PayloadKind: Sendable, Equatable {
        case pdf
        /// A decodable image format, refused at the router until a loader
        /// for it exists.
        case image(ImageFormat)
        /// An image format no loader will decode: WEBP, GIF, TIFF, BMP.
        case unsupportedImage
        /// No recognised signature; the PDF parser decides.
        case unknown
    }

    /// Sniff the leading bytes. Only the first 12 are read.
    ///
    /// Recognised signatures:
    /// - `%PDF` (`25 50 44 46`)                     → `.pdf`
    /// - JPEG SOI (`FF D8 FF`)                      → `.image(.jpeg)`
    /// - PNG (`89 50 4E 47`)                        → `.image(.png)`
    /// - HEIC family (`ftyp` + a still-image brand) → `.image(.heic)`
    /// - WEBP (`RIFF` + `WEBP` at offset 8)         → `.unsupportedImage`
    /// - GIF (`GIF8`)                               → `.unsupportedImage`
    /// - TIFF (`II*\0` or `MM\0*`)                  → `.unsupportedImage`
    /// - BMP (`BM`)                                 → `.unsupportedImage`
    static func kind(of data: Data) -> PayloadKind {
        // Normalize to a zero-based array: `Data` indices are not always
        // zero-based, and copying twelve bytes is cheaper than indexing a
        // 50 MB payload through its slice arithmetic.
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .image(.jpeg) }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image(.png) }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .unsupportedImage }  // GIF8
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) { return .unsupportedImage }  // II*\0
        if bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .unsupportedImage }  // MM\0*
        if bytes.starts(with: [0x42, 0x4D]) { return .unsupportedImage }              // BM
        // WEBP — RIFF<size>WEBP. Bytes 0..3 = "RIFF", bytes 8..11 = "WEBP".
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return .unsupportedImage
        }
        // HEIC / HEIF — ISO BMFF box: bytes 4..7 = "ftyp", bytes 8..11 = brand.
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand: [UInt8] = [bytes[8], bytes[9], bytes[10], bytes[11]]
            if heicBrands.contains(brand) { return .image(.heic) }
        }
        return .unknown
    }

    /// The ISO BMFF brands of HEIC/HEIF still images.
    private static let heicBrands: [[UInt8]] = [
        [0x68, 0x65, 0x69, 0x63], // heic
        [0x68, 0x65, 0x69, 0x78], // heix
        [0x68, 0x65, 0x76, 0x63], // hevc
        [0x68, 0x65, 0x76, 0x78], // hevx
        [0x6D, 0x69, 0x66, 0x31], // mif1
        [0x6D, 0x73, 0x66, 0x31], // msf1
        [0x68, 0x65, 0x69, 0x6D], // heim
        [0x68, 0x65, 0x69, 0x73], // heis
        [0x68, 0x65, 0x76, 0x6D], // hevm
        [0x68, 0x65, 0x76, 0x73], // hevs
    ]

    /// The loader for a payload. Every image kind throws the
    /// unsupported-format refusal before any decode; `%PDF` and unknown
    /// payloads take the PDF loader.
    static func route(data: Data) throws -> any DocumentLoader {
        switch kind(of: data) {
        case .pdf, .unknown:
            return PDFImportLoader()
        case .image, .unsupportedImage:
            throw PipelineError.importError(.unsupportedFormat)
        }
    }

    /// The drop door: whether a dropped payload may enter the import path.
    /// A payload whose leading bytes carry an image signature is refused
    /// before dispatch. `%PDF` and unknown payloads are admitted: an
    /// unknown payload reaches the PDF parser, which reports anything it
    /// cannot open (refusing unknown bytes would also refuse a PDF whose
    /// `%PDF` header is not at offset 0).
    static func admitsDroppedPayload(_ data: Data) -> Bool {
        switch kind(of: data) {
        case .pdf, .unknown: return true
        case .image, .unsupportedImage: return false
        }
    }
}
