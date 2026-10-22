import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The router's own contract: JPEG, PNG and HEIC bytes take the image
// loader, every other image signature meets the unsupported-format
// refusal, and only `%PDF` and unknown bytes reach the PDF loader.

@Suite("Import router", .tags(.importFlow))
struct ImportRouterTests {

    /// The import failure a thrown error carries, named the way the
    /// failure cases are spelled, or "none".
    private func refusalName(_ body: () throws -> any DocumentLoader) -> String {
        do {
            _ = try body()
            return "none"
        } catch let error as PipelineError {
            if case .importError(let failure) = error {
                return String(describing: failure)
            }
            return "other"
        } catch {
            return "other"
        }
    }

    @Test("GIF, TIFF and BMP signatures are unsupported images")
    func unsupportedImageSignatures() {
        let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])          // GIF89a
        let tiffLittle = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00])   // II*\0
        let tiffBig = Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00])      // MM\0*
        let bmp = Data([0x42, 0x4D, 0x36, 0x00, 0x00, 0x00])          // BM
        for data in [gif, tiffLittle, tiffBig, bmp] {
            #expect(ImportRouter.kind(of: data) == .unsupportedImage)
            #expect(!ImportRouter.admitsDroppedPayload(data))
        }
    }

    @Test("Every HEIC-family brand is the HEIC image format")
    func heicBrands() {
        for brand in ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "heim", "heis", "hevm", "hevs"] {
            var data = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
            data.append(contentsOf: Array(brand.utf8))
            #expect(ImportRouter.kind(of: data) == .image(.heic), "brand \(brand)")
        }
    }

    @Test("JPEG, PNG and HEIC take the image loader; the other image kinds are refused as unsupported")
    func imagesAtTheRouter() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let heic = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
        for data in [jpeg, png, heic] {
            #expect(try ImportRouter.route(data: data) is ImageImportLoader)
        }
        let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        let avif = Data([0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66])
        for data in [gif, avif] {
            #expect(refusalName { try ImportRouter.route(data: data) } == "unsupportedFormat")
        }
    }

    @Test("%PDF and unknown bytes take the PDF loader")
    func pdfAndUnknownTakeThePDFLoader() throws {
        let pdf = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37])
        let unknown = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])
        #expect(try ImportRouter.route(data: pdf) is PDFImportLoader)
        #expect(try ImportRouter.route(data: unknown) is PDFImportLoader)
        #expect(refusalName { try ImportRouter.route(data: pdf) } == "none")
    }

    @Test("The declared type is recorded on the payload and never routes")
    func declaredTypeIsARecordNotARoute() {
        let payload = ImportPayload.bytes(
            Data([0x25, 0x50, 0x44, 0x46]), declaredType: "jpg", door: .drop)
        #expect(payload.declaredType == "jpg")
        #expect(payload.door == .drop)
        #expect(payload.data.count == 4)
        // The router answers from the bytes alone.
        #expect(ImportRouter.kind(of: payload.data) == .pdf)
        let unlabelled = ImportPayload.bytes(Data(), declaredType: nil, door: .sample)
        #expect(unlabelled.declaredType == nil)
        #expect(unlabelled.door == .sample)
    }
}
