import Testing
import PDFKit
@testable import RedactionEngine

@Suite("PDFStructureReader")
struct PDFStructureReaderTests {
    let reader = PDFStructureReader()

    // MARK: - Metadata

    @Test("readMetadata finds Author and Title")
    func metadataFindsAuthorAndTitle() async throws {
        let data = TestFixtures.withMetadata(["Author": "John Doe", "Title": "Secret Report"])
        let doc = try #require(PDFDocument(data: data))
        let findings = await reader.readMetadata(from: doc)

        let ids = findings.map(\.id)
        #expect(ids.contains("metadata-author"))
        #expect(ids.contains("metadata-title"))
    }

    @Test("readMetadata classifies Author as warning")
    func metadataAuthorIsWarning() async throws {
        let data = TestFixtures.withMetadata(["Author": "Jane Sample"])
        let doc = try #require(PDFDocument(data: data))
        let findings = await reader.readMetadata(from: doc)

        let authorFinding = findings.first { $0.id == "metadata-author" }
        #expect(authorFinding?.severity == .warning)
    }

    @Test("readMetadata returns empty for clean PDF")
    func metadataCleanPDF() async throws {
        let data = TestFixtures.blankPage()
        let doc = try #require(PDFDocument(data: data))
        let findings = await reader.readMetadata(from: doc)

        #expect(findings.isEmpty)
    }

    // MARK: - Active Content

    @Test("checkActiveContent detects JavaScript")
    func activeContentDetectsJavaScript() async throws {
        let data = TestFixtures.withJavaScript()
        let findings = await reader.checkActiveContent(from: data)

        let ids = findings.map(\.id)
        #expect(ids.contains("active-javascript"))
    }

    @Test("checkActiveContent detects AcroForm")
    func activeContentDetectsAcroForm() async throws {
        let data = TestFixtures.withCatalogKey("AcroForm")
        let findings = await reader.checkActiveContent(from: data)

        let ids = findings.map(\.id)
        #expect(ids.contains("active-acroform"))
    }

    @Test("checkActiveContent clean PDF produces no findings")
    func activeContentCleanPDF() async throws {
        let data = TestFixtures.blankPage()
        let findings = await reader.checkActiveContent(from: data)

        #expect(findings.isEmpty)
    }

    // MARK: - Embedded Files

    @Test("checkEmbeddedFiles detects embedded file")
    func embeddedFilesDetects() async throws {
        let data = TestFixtures.withEmbeddedFile(filename: "test.txt")
        let findings = await reader.checkEmbeddedFiles(from: data)

        #expect(!findings.isEmpty)
        let fileFinding = findings.first { $0.id == "embedded-files" }
        #expect(fileFinding?.severity == .critical)
    }

    @Test("checkEmbeddedFiles clean PDF produces no findings")
    func embeddedFilesCleanPDF() async throws {
        let data = TestFixtures.blankPage()
        let findings = await reader.checkEmbeddedFiles(from: data)

        #expect(findings.isEmpty)
    }

    // MARK: - Hidden Layers

    @Test("checkHiddenLayers detects OCG hidden layers")
    func hiddenLayersDetectsOCG() async throws {
        let data = TestFixtures.ocgHiddenLayerPDF()
        let findings = await reader.checkHiddenLayers(from: data)

        #expect(!findings.isEmpty)
        let layerFinding = findings.first { $0.id == "hidden-layers-off" }
        #expect(layerFinding != nil)
        #expect(layerFinding?.severity == .warning)
    }

    @Test("checkHiddenLayers clean PDF produces no findings")
    func hiddenLayersCleanPDF() async throws {
        let data = TestFixtures.blankPage()
        let findings = await reader.checkHiddenLayers(from: data)

        #expect(findings.isEmpty)
    }
}
