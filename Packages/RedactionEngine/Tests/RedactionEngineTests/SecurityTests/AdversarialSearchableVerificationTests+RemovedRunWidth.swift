import Testing
import Foundation
@testable import RedactionEngine

// The width-fingerprint case of the adversarial Searchable suite, in a file
// of its own so the suite's main file stays under the test-file length limit.

extension AdversarialSearchableVerificationTests {

    @Test("RT-2: A removed run's width reaches the text layer only in whole cells of its band",
          .tags(.critical))
    func rt2RemovedRunWidthReachesLayerOnlyInWholeCells() throws {
        // The writer derives one quantized pitch per line band from source
        // metrics: the content-dependent channel this re-opens is the band's
        // quantized size class — bounded bits, redundant with the visible
        // raster (`TextLayerReconstructor.swift`'s header).
        //
        // The same kept letters ("AB", a box, "CD") are laid out with boxes
        // of many widths. The band's size and the first line never move; the
        // run after the box starts on a whole cell of its band; moved by
        // less than a cell without crossing a cell edge its line is the
        // same, and across one edge its start moves by exactly one cell.
        func letters(boxWidth: CGFloat) -> (entries: [CharacterInfo], box: CGRect) {
            let box = CGRect(x: 90, y: 698, width: boxWidth, height: 16)
            let after = box.maxX + 2
            let entries = [
                CharacterInfo(character: "A", bounds: CGRect(x: 72, y: 700, width: 7, height: 12), stringIndex: 0),
                CharacterInfo(character: "B", bounds: CGRect(x: 79, y: 700, width: 7, height: 12), stringIndex: 1),
                CharacterInfo(character: "C", bounds: CGRect(x: after, y: 700, width: 7, height: 12), stringIndex: 2),
                CharacterInfo(character: "D", bounds: CGRect(x: after + 7, y: 700, width: 7, height: 12), stringIndex: 3),
            ]
            return (entries, box)
        }
        func lines(boxWidth: CGFloat) -> [TextLayerLine] {
            let (entries, box) = letters(boxWidth: boxWidth)
            return TextLayerReconstructor.layoutLinesWithSources(
                entries, pageWidth: 612, redactionRects: [box]).map(\.line)
        }

        let reference = lines(boxWidth: 20)
        try #require(reference.map(\.text) == ["AB", "CD"],
                     "a box between the runs splits the line")
        let size = reference[0].fontSize
        let cw = SandwichMetrics.courierAdvancePerPoint * size

        // Every box width: same size, same first line, and the run after the
        // box starts on the whole cell its first letter stands in.
        for i in 0..<100 {
            let width = 10 + CGFloat(i) * 0.37
            let drawn = lines(boxWidth: width)
            try #require(drawn.map(\.text) == ["AB", "CD"], "box \(width): two lines")
            #expect(drawn.map(\.fontSize) == [size, size],
                    "box \(width): the band's size does not move")
            #expect(drawn[0].origin == reference[0].origin,
                    "box \(width): the line before the box does not move")
            let sourceX = 90 + width + 2
            let start = drawn[1].origin.x
            let cells = start / cw
            #expect(abs(cells - cells.rounded()) < 1e-9,
                    "box \(width): start \(start) is not a whole cell of \(cw)")
            #expect(start <= sourceX + 1e-9 && sourceX < start + cw,
                    "box \(width): start \(start) is not the cell \(sourceX) stands in")
        }

        // Within one cell, then across its edge.
        let cell = ((90 + 20 + 2) / cw).rounded(.down)
        let near = lines(boxWidth: cell * cw + 0.1 * cw - 92)
        let far = lines(boxWidth: cell * cw + 0.9 * cw - 92)
        let next = lines(boxWidth: (cell + 1) * cw + 0.1 * cw - 92)
        try #require(near.count == 2 && far.count == 2 && next.count == 2)
        #expect(near.map(\.origin) == far.map(\.origin),
                "moved by less than a cell inside one cell: the drawn lines are the same")
        #expect(near.map(\.text) == far.map(\.text))
        #expect(abs((next[1].origin.x - near[1].origin.x) - cw) < 1e-9,
                "across one cell edge the start moves by exactly one cell")
        #expect(next[0].origin == near[0].origin)
    }
}
