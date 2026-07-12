import Testing
import CoreGraphics
@testable import RedactionEngine

// Plan Phase 2 / §G6 — unit tests for Vision line-box merging.
// xGap = 0.015, yGap = 0.020 (normalized). Placeholders per plan §5.

@Suite("BoundingBoxMerger (G6)")
struct BoundingBoxMergerTests {

    private let merger = BoundingBoxMerger()

    /// Make a synthetic TextLine at a given normalized rect with plain text.
    private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.1, h: CGFloat = 0.02) -> OCREngine.TextLine {
        OCREngine.TextLine(
            text: text,
            normalizedRect: CGRect(x: x, y: y, width: w, height: h),
            confidence: 1.0
        )
    }

    @Test("Empty input yields empty output")
    func empty() {
        #expect(merger.merge([]).isEmpty)
    }

    @Test("Single line passes through unchanged")
    func singleLine() {
        let input = [line("Hello", x: 0.1, y: 0.5)]
        let output = merger.merge(input)
        #expect(output.count == 1)
        #expect(output[0].text == "Hello")
        #expect(output[0].sourceLineIndices == [0])
    }

    @Test("Two horizontally adjacent lines on same row merge when x-gap ≤ xGap")
    func intraRowMerge() {
        // Line A at x=0.1, width 0.1 → maxX 0.2
        // Line B at x=0.21 → gap 0.01 (≤ 0.015 xGap) → merge
        let a = line("Hello", x: 0.10, y: 0.5, w: 0.1)
        let b = line("World", x: 0.21, y: 0.5, w: 0.1)
        let output = merger.merge([a, b])
        #expect(output.count == 1)
        #expect(output[0].text == "Hello World")
        #expect(output[0].sourceLineIndices.sorted() == [0, 1])
    }

    @Test("Two horizontally separated lines on same row do NOT merge when x-gap > xGap")
    func intraRowSplit() {
        // Line A maxX 0.2; line B minX 0.3 → gap 0.1 (> 0.015) → separate.
        let a = line("Hello", x: 0.10, y: 0.5, w: 0.1)
        let b = line("World", x: 0.30, y: 0.5, w: 0.1)
        let output = merger.merge([a, b])
        #expect(output.count == 2)
    }

    @Test("Two lines on different rows (y-gap > yGap) stay in separate regions")
    func interRowSplit() {
        // Row 1 at y=0.50; row 2 at y=0.45 → Δy 0.05 (> 0.020 yGap) → separate rows.
        let a = line("Top", x: 0.1, y: 0.50)
        let b = line("Bottom", x: 0.1, y: 0.45)
        let output = merger.merge([a, b])
        #expect(output.count == 2)
    }

    @Test("Two lines with small y-delta group into one row")
    func intraRowYTolerance() {
        // Δy = 0.01 ≤ 0.020 yGap → same row. x-gap also small → merge.
        let a = line("A", x: 0.10, y: 0.500, w: 0.05)
        let b = line("B", x: 0.16, y: 0.510, w: 0.05)
        let output = merger.merge([a, b])
        #expect(output.count == 1)
        #expect(output[0].sourceLineIndices.count == 2)
    }

    @Test("Union rect covers all participants")
    func unionRectSpansParticipants() {
        let a = line("A", x: 0.10, y: 0.500, w: 0.05, h: 0.02)
        let b = line("B", x: 0.16, y: 0.500, w: 0.05, h: 0.02)
        let output = merger.merge([a, b])
        #expect(output.count == 1)
        let rect = output[0].unionRect
        #expect(abs(rect.minX - 0.10) < 1e-9)
        #expect(abs(rect.maxX - 0.21) < 1e-9)
    }

    @Test("Row sort is top-to-bottom (descending minY in Vision coords)")
    func rowOrderTopToBottom() {
        // Vision normalized: y=0 bottom, y=1 top. Top row has larger minY.
        let top = line("Top", x: 0.1, y: 0.80)
        let bottom = line("Bottom", x: 0.1, y: 0.20)
        let output = merger.merge([bottom, top])
        #expect(output.count == 2)
        // First emitted region is the top one (descending minY sort).
        #expect(output[0].text == "Top")
        #expect(output[1].text == "Bottom")
    }

    @Test("sourceLineIndices reference the original input ordering")
    func sourceIndicesPreserveInputPositions() {
        // Provide lines out-of-order; indices should still map back correctly.
        let lines = [
            line("B", x: 0.16, y: 0.5, w: 0.05), // index 0, right
            line("A", x: 0.10, y: 0.5, w: 0.05), // index 1, left
        ]
        let output = merger.merge(lines)
        #expect(output.count == 1)
        // Merged text is in x-order: "A B" (left-to-right within row).
        #expect(output[0].text == "A B")
        // Indices preserved: left=1, right=0.
        #expect(output[0].sourceLineIndices == [1, 0])
    }
}
