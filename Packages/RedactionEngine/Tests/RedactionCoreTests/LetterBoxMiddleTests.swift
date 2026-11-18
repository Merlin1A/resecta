import Foundation
import Testing
import RedactionCore

@Suite("The middle of a letter's box")
struct LetterBoxMiddleTests {

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let box: CGRect
        let rotation: Int
        let expected: CGRect?
        var testDescription: String { name }
    }

    /// Built from origin and size alone, as the core reads them.
    static func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }

    /// A 20 × 10 box at (100, 200) on an upright page, and the same letter's
    /// box as a page turned a quarter shows it (10 × 20: the line runs along
    /// the frame's height there). The two signed rows are the upright box
    /// given from its far corner, which must give the upright row's middle.
    static let cases: [Case] = [
        Case(name: "upright", box: rect(100, 200, 20, 10), rotation: 0,
             expected: rect(105, 203.5, 10, 3)),
        Case(name: "turned a quarter", box: rect(100, 200, 10, 20), rotation: 90,
             expected: rect(103.5, 205, 3, 10)),
        Case(name: "turned a half", box: rect(100, 200, 20, 10), rotation: 180,
             expected: rect(105, 203.5, 10, 3)),
        Case(name: "turned three quarters", box: rect(100, 200, 10, 20), rotation: 270,
             expected: rect(103.5, 205, 3, 10)),
        Case(name: "negative width", box: rect(120, 200, -20, 10), rotation: 0,
             expected: rect(105, 203.5, 10, 3)),
        Case(name: "negative height", box: rect(100, 210, 20, -10), rotation: 0,
             expected: rect(105, 203.5, 10, 3)),
        Case(name: "no width", box: rect(100, 200, 0, 10), rotation: 0,
             expected: nil),
        Case(name: "no height", box: rect(100, 200, 20, 0), rotation: 0,
             expected: nil),
    ]

    @Test("The table holds eight cases")
    func tableLength() {
        #expect(Self.cases.count == 8)
    }

    @Test("The middle is drawn in 25 % along the line and 35 % across it, turned with the page",
          arguments: cases)
    func middle(_ c: Case) {
        let got = LetterBoxMiddle.middle(of: c.box, rotation: c.rotation)
        guard let expected = c.expected else {
            #expect(got == nil, "\(c.name): \(String(describing: got))")
            return
        }
        guard let got else {
            Issue.record("\(c.name): got nil, expected \(expected)")
            return
        }
        #expect(abs(got.origin.x - expected.origin.x) < 1e-9
                && abs(got.origin.y - expected.origin.y) < 1e-9
                && abs(got.size.width - expected.size.width) < 1e-9
                && abs(got.size.height - expected.size.height) < 1e-9,
                "\(c.name): got \(got), expected \(expected)")
    }
}
