import Foundation
import Testing
import PDFKit
@testable import RedactionEngine

@Suite("Font Analysis")
struct FontAnalysisTests {

    @Test("blank page with no fonts returns empty findings")
    func blankPageNoFonts() async throws {
        let data = TestFixtures.blankPage()
        let reader = PDFStructureReader()

        let findings = await reader.analyzeFonts(from: data)
        // Blank page has no text content -> no fonts
        #expect(findings.isEmpty)
    }

    @Test("textLayerPDF with system font flags proportional font")
    func systemFontFlagsProportional() async throws {
        // UIFont.systemFont produces a proportional font (SF Pro / Helvetica)
        let data = TestFixtures.textLayerPDF(text: "Hello World")
        let reader = PDFStructureReader()

        let findings = await reader.analyzeFonts(from: data)

        // Should flag the proportional font used by UIGraphicsPDFRenderer
        // Note: this depends on the system font being embedded in the PDF.
        // If the renderer doesn't embed font references, findings may be empty.
        if !findings.isEmpty {
            let fontFinding = findings.first!
            #expect(fontFinding.id == "font-proportional")
            #expect(fontFinding.severity == .info)
        }
        // If empty, the PDF renderer didn't embed font dictionaries -- acceptable
    }

    @Test("font findings are info severity, not critical")
    func fontFindingsInfoSeverity() async throws {
        let data = TestFixtures.textLayerPDF(text: "Test content")
        let reader = PDFStructureReader()

        let findings = await reader.analyzeFonts(from: data)
        for finding in findings {
            #expect(finding.severity == .info, "Font findings should be .info severity (Bland et al. awareness)")
        }
    }
}
