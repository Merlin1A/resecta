import Testing
import PDFKit
@testable import RedactionEngine

@Suite("AnnotationAnalyzer")
struct AnnotationAnalyzerTests {
    let analyzer = AnnotationAnalyzer()

    @Test("clean PDF returns unredacted profile and no findings")
    func cleanPDF() async throws {
        let data = TestFixtures.blankPage()
        let doc = try #require(PDFDocument(data: data))
        let result = await analyzer.analyze(document: doc)

        #expect(result.findings.isEmpty)
        if case .unredacted = result.profile {
            // expected
        } else {
            Issue.record("Expected .unredacted profile")
        }
    }

    @Test("PDF with link annotations produces findings")
    func linkAnnotations() async throws {
        let data = TestFixtures.withAnnotations(subtypes: [.link, .link, .link])
        let doc = try #require(PDFDocument(data: data))
        let result = await analyzer.analyze(document: doc)

        #expect(!result.findings.isEmpty)
        let linkFinding = result.findings.first { $0.id == "annotation-link" }
        #expect(linkFinding != nil)
    }

    @Test("black square annotations produce redacted profile")
    func blackSquareProfile() async throws {
        let data = TestFixtures.withBlackSquareAnnotations(count: 3)
        let doc = try #require(PDFDocument(data: data))
        let result = await analyzer.analyze(document: doc)

        if case .redacted(let count) = result.profile {
            #expect(count == 3)
        } else {
            Issue.record("Expected .redacted(markCount: 3), got \(result.profile)")
        }
    }

    @Test("mixed annotations produce correct type breakdown")
    func mixedAnnotations() async throws {
        let data = TestFixtures.withAnnotations(subtypes: [.link, .highlight, .square])
        let doc = try #require(PDFDocument(data: data))
        let result = await analyzer.analyze(document: doc)

        // Should have findings for each distinct type
        let ids = Set(result.findings.map(\.id))
        #expect(ids.count >= 2) // At least link and one other type
    }
}
