import Testing
import Foundation
import PDFKit
import UIKit
@testable import ResectaApp

// The sidebar's page thumbnail is rendered on the main actor, behind the
// cache: the page belongs to the document the canvas is drawing, and a
// PDFKit page is not safe to draw from another thread while the view draws
// it. The render helper is main-actor isolated (the compiler holds that);
// this suite pins that the file keeps no detached render and that the
// helper renders a page at the requested size.

@Suite("Page thumbnail render")
@MainActor
struct ThumbnailRenderTests {

    @Test("The render helper draws the page at the requested pixel size, on the main actor")
    func rendersAtTheRequestedSize() throws {
        let document = makeTestPDFDocument()
        let page = try #require(document.page(at: 0))
        let size = CGSize(width: 120, height: 160)
        let image = PageThumbnailView.render(page, size: size)
        #expect(image.size.width > 0 && image.size.height > 0)
        #expect(image.size.width <= size.width + 1 && image.size.height <= size.height + 1,
                "the thumbnail fits the requested box: \(image.size)")
    }

    @Test("The thumbnail file keeps no detached render over a shared page (source pin)")
    func noDetachedRender() throws {
        let source = try String(contentsOf: repoFile("Sources/ResectaApp/Views/PageThumbnailList.swift"), encoding: .utf8)
        #expect(!source.contains("Task.detached"), "a detached render draws a page the canvas may be drawing")
        #expect(!source.contains("nonisolated(unsafe) let unsafePage"), "no page bridged off the main actor")
        #expect(source.contains("static func render(_ page: PDFPage, size: CGSize) -> UIImage"), "the one render helper")
    }

    private func repoFile(_ relativePath: String, file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent(relativePath)
    }
}
