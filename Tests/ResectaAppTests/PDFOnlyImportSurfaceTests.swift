import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// Resecta opens PDF files only. These pins cover the input surfaces that
// have no pure-function seam: the two Files pickers declare the PDF type
// alone, no Photos picker is mounted anywhere in the app, and the
// unsupported-format message and the drop-refusal toast read the same
// words and name PDF without naming an image format. Source files are
// read the way `DocumentEditorViewSourceContractsTests` reads them.

@Suite("PDF-only import surfaces", .tags(.importFlow))
struct PDFOnlyImportSurfaceTests {

    @Test("Both Files pickers list PDF files only")
    func filePickersDeclarePDFOnly() throws {
        for path in [
            "Sources/ResectaApp/Views/HomeView.swift",
            "Sources/ResectaApp/Views/RedactWorkspaceView.swift",
        ] {
            let source = try loadRepoFile(path)
            #expect(source.contains("allowedContentTypes: [.pdf]"),
                    "\(path): the Files picker must declare [.pdf]")
            #expect(!source.contains(".image]") && !source.contains(".image,"),
                    "\(path): the Files picker must not list an image type")
        }
    }

    @Test("No Photos picker is mounted in the app")
    func noPhotosPickerInApp() throws {
        let root = repoRoot().appendingPathComponent("Sources/ResectaApp")
        let files = try swiftFiles(under: root)
        #expect(!files.isEmpty, "no Swift sources found under Sources/ResectaApp")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains(".photosPicker("),
                    "\(file.lastPathComponent) mounts a Photos picker")
            #expect(!source.contains("import PhotosUI"),
                    "\(file.lastPathComponent) imports PhotosUI")
        }
    }

    @Test("The unsupported-format message names PDF and no image format")
    func unsupportedFormatMessageNamesPDFOnly() {
        let text = PipelineError.importError(.unsupportedFormat).localizedRecovery
        #expect(text.contains("PDF"))
        for word in ["image", "JPEG", "PNG", "HEIC", "WEBP"] {
            #expect(!text.localizedCaseInsensitiveContains(word),
                    "the unsupported-format message names \(word)")
        }
    }

    @Test("The drop-refusal toast reads the unsupported-format message")
    func dropRefusalMatchesUnsupportedFormat() {
        #expect(DocumentState.importRefusedNotPDFMessage
                == PipelineError.importError(.unsupportedFormat).localizedRecovery)
    }

    @Test("The empty iPad sidebar says PDF")
    func emptySidebarSaysPDF() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/RedactWorkspaceView.swift")
        #expect(source.contains("Open a PDF to see pages here."))
        #expect(!source.contains("PDF or image"))
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
