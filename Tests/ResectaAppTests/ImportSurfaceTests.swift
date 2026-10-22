import Testing
import Foundation
import UniformTypeIdentifiers
import RedactionEngine
@testable import ResectaApp

// Resecta opens PDF files and JPEG, PNG and HEIC images. These pins cover
// the input surfaces that have no pure-function seam: the Files picker
// declares the accepted types and never the generic image type, exactly one
// file mounts the Photos picker, and the unsupported-format message and the
// drop-refusal toast read the same words and name the accepted formats
// without naming a refused one. Source files are read the way
// `DocumentEditorViewSourceContractsTests` reads them.

@Suite("Import surfaces", .tags(.importFlow))
struct ImportSurfaceTests {

    @Test("The Files picker lists the accepted content types and never the generic image type")
    func filePickerDeclaresTheAcceptedTypes() throws {
        let path = "Sources/ResectaApp/Views/HomeView.swift"
        let source = try loadRepoFile(path)
        #expect(source.contains("allowedContentTypes: ImportService.acceptedContentTypes"),
                "\(path): the Files picker must read the accepted content types")
        #expect(ImportService.acceptedContentTypes == [.pdf, .jpeg, .png, .heic, .heif])
        #expect(!source.contains(".image]") && !source.contains(".image,"),
                "\(path): the Files picker must not list the generic image type")
        let root = repoRoot().appendingPathComponent("Sources/ResectaApp")
        for file in try swiftFiles(under: root) {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("UTType.image") && !text.contains("[.image]") && !text.contains("matching: .images, preferredItemEncoding: .compatible"),
                    "\(file.lastPathComponent) names the generic image type or a transcoding pick")
        }
    }

    @Test("Exactly one file imports PhotosUI and mounts the Photos picker")
    func onePhotosPickerInApp() throws {
        let root = repoRoot().appendingPathComponent("Sources/ResectaApp")
        let files = try swiftFiles(under: root)
        #expect(!files.isEmpty, "no Swift sources found under Sources/ResectaApp")
        var mounts: [String] = [], importers: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains(".photosPicker(") { mounts.append(file.lastPathComponent) }
            if source.contains("import PhotosUI") { importers.append(file.lastPathComponent) }
        }
        #expect(mounts == ["PhotoImportPicker.swift"], "\(mounts)")
        #expect(importers == ["PhotoImportPicker.swift"], "\(importers)")
    }

    @Test("The unsupported-format message names PDF, JPEG, PNG and HEIC and no refused format")
    func unsupportedFormatMessageNamesTheAcceptedFormats() {
        let text = PipelineError.importError(.unsupportedFormat).localizedRecovery
        for word in ["PDF", "JPEG", "PNG", "HEIC"] {
            #expect(text.contains(word), "the unsupported-format message names \(word)")
        }
        for word in ["WEBP", "WebP", "GIF", "TIFF"] {
            #expect(!text.contains(word), "the unsupported-format message names \(word)")
        }
    }

    @Test("The drop-refusal toast reads the unsupported-format message")
    func dropRefusalMatchesUnsupportedFormat() {
        #expect(DocumentState.importRefusedNotPDFMessage
                == PipelineError.importError(.unsupportedFormat).localizedRecovery)
    }

    @Test("The empty sidebar says PDF or image")
    func emptySidebarSaysPDFOrImage() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/RedactWorkspaceView.swift")
        #expect(source.contains("Open a PDF or an image to see pages here."))
    }

    // MARK: - Helpers

    private func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }

    private func loadRepoFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
