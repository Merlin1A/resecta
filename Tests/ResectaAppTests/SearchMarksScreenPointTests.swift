import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp

// The Search highlight's border and the result walk's ring are one size on
// screen at every zoom. Their widths and the ring's outset come from
// `searchMarkStrokes(fingerScale:)`, read here at the fit zoom (`fingerScale`
// 1) and at three and a half times it; the search layer's drawing takes all
// three from it, read from its source.

@Suite("Search marks in screen points")
struct SearchMarksScreenPointTests {

    @Test("The picked highlight's border is 2 screen points wide at every zoom",
          arguments: [CGFloat(1), CGFloat(1) / 3.5])
    func borderInScreenPoints(fingerScale: CGFloat) {
        let strokes = RedactionOverlayView.searchMarkStrokes(fingerScale: fingerScale)
        #expect(abs(strokes.border - 2 * fingerScale) < 0.0001, "\(strokes.border) at \(fingerScale)")
    }

    @Test("The walk's ring is 2 screen points wide and 3 outside its highlight at every zoom",
          arguments: [CGFloat(1), CGFloat(1) / 3.5])
    func ringInScreenPoints(fingerScale: CGFloat) {
        let strokes = RedactionOverlayView.searchMarkStrokes(fingerScale: fingerScale)
        #expect(abs(strokes.ring - 2 * fingerScale) < 0.0001, "\(strokes.ring) at \(fingerScale)")
        #expect(abs(strokes.ringOutset - 3 * fingerScale) < 0.0001, "\(strokes.ringOutset) at \(fingerScale)")
    }

    /// The search layer draws in a graphics context, so its widths are read
    /// from its source: every line width and the ring's inset in its body
    /// come from the screen-point strokes.
    @Test("The search layer draws its border and ring from the screen-point strokes")
    func searchLayerUsesTheStrokes() throws {
        let file = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp/Overlay/RedactionOverlayView+Draw.swift")
        let code = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(code.range(of: "func drawSearchLayer("))
        let end = try #require(code.range(of: "func drawInProgressShapes(", range: start.upperBound..<code.endIndex))
        let body = code[start.upperBound..<end.lowerBound]
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
        #expect(body.contains("let strokes = Self.searchMarkStrokes(fingerScale: fingerScale)"))
        #expect(body.filter { $0.hasPrefix("ctx.setLineWidth(") }
                == ["ctx.setLineWidth(strokes.border)", "ctx.setLineWidth(strokes.ring)"])
        #expect(body.filter { $0.hasPrefix(".insetBy(") }
                == [".insetBy(dx: -strokes.ringOutset, dy: -strokes.ringOutset)"])
    }
}
