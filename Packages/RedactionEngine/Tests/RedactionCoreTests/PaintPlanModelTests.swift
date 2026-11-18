import Foundation
import Testing
import RedactionCore

/// A layout model of the plan, as a regression check: a greedy typesetter in
/// test code sets five templates for 200 values (40 each), and the gate's
/// counting rule is applied to the planned paint of the value's box. Off and
/// on are the switch's two arms; D is the number of different paints in an
/// arm. A template FAILS when two values paint the same with the switch off
/// and differently with it on; it REDUCES when 2 × D_on ≤ D_off. Letters
/// here are uniform boxes, so two values of equal width are the same page to
/// the plan. This is a model of the plan's rectangles, not of any export.
@Suite struct PaintPlanModelTests {
    typealias Sheet = ComplementReadingTests.Sheet
    static let left = 72.0, right = 540.0, pitch = 14.0

    /// Fixed words of the page, the same on every page.
    static func fixedWords(_ count: Int, seed: Int) -> [String] {
        let lengths = [3, 5, 2, 7, 4, 6, 8, 3, 5, 9, 4, 2, 6]
        return (0..<count).map { String(repeating: "f", count: lengths[($0 * 7 + seed) % lengths.count]) }
    }

    /// Words set left to right from `left`, broken greedily at `right`, from
    /// `top` down; justified, every line but the last is spread to end at
    /// `right`: its gaps in whole sixty-fourths and its last word flush with
    /// the margin. Returns each word's offsets
    /// and the line it was set on.
    @discardableResult
    static func set(_ words: [String], on sheet: inout Sheet, top: Double, justified: Bool = false) -> [(offsets: Set<Int>, line: Int)] {
        var lines: [[String]] = [[]]
        var x = left
        for w in words {
            let width = Double(w.count) * 6
            if x > left && x + width > right { lines.append([]); x = left }
            lines[lines.count - 1].append(w)
            x += width + 4
        }
        var placed: [(offsets: Set<Int>, line: Int)] = []
        for (k, line) in lines.enumerated() {
            let ink = line.reduce(0) { $0 + Double($1.count) * 6 }
            let gaps = Double(max(line.count - 1, 1))
            let gap = justified && k < lines.count - 1 && line.count > 1
                ? ((right - left - ink) / gaps * 64).rounded(.down) / 64 : 4
            var at = left
            let spread = justified && k < lines.count - 1 && line.count > 1
            for (i, w) in line.enumerated() {
                // A justified line's last word stands flush with the margin.
                let x = spread && i == line.count - 1 ? right - Double(w.count) * 6 : at
                placed.append((sheet.word(w, x: x, y: top - pitch * Double(k)), k))
                at += Double(w.count) * 6 + gap
            }
        }
        return placed
    }

    /// The fixed text above and below every template: three full lines each.
    static func frame(_ sheet: inout Sheet, above: Double, below: Double) {
        set(fixedWords(48, seed: 1), on: &sheet, top: above)
        set(fixedWords(48, seed: 2), on: &sheet, top: below)
    }

    static let values: [String] = (0..<40).map { k in
        let a = 3 + (k * 5) % 7, b = 3 + (k * 3 + k / 7) % 10
        return String(repeating: "v", count: a) + " " + String(repeating: "w", count: b)
    }

    enum Template: CaseIterable { case raggedParagraph, justifiedParagraph, labelRows, fixedTable, autoSizedTable }

    /// A template set with a value: the page and the value's offsets, or nil
    /// when the value does not fit (it leaves its line or its room).
    static func page(_ template: Template, _ value: String) -> (Sheet, Set<Int>)? {
        var sheet = Sheet()
        frame(&sheet, above: 740, below: 560)
        let parts = value.split(separator: " ").map(String.init)
        switch template {
        case .raggedParagraph, .justifiedParagraph:
            var words = fixedWords(60, seed: 3)
            words.insert(contentsOf: parts, at: 20)
            let placed = set(words, on: &sheet, top: 680, justified: template == .justifiedParagraph)
            let mine = placed[20..<(20 + parts.count)]
            guard mine.allSatisfy({ $0.line == 1 }) else { return nil }
            return (sheet, mine.reduce(into: Set<Int>()) { $0.formUnion($1.offsets) })
        case .labelRows:
            let others = [10, 14, 8, 0, 12, 9]
            var box: Set<Int> = []
            for (k, n) in others.enumerated() {
                let y = 680 - pitch * Double(k)
                sheet.word("Abcd:", x: 72, y: y)
                if k == 2 {
                    var x = 108.0
                    for p in parts { box.formUnion(sheet.word(p, x: x, y: y)); x += Double(p.count) * 6 + 4 }
                } else {
                    sheet.word(String(repeating: "a", count: n), x: 108, y: y)
                }
            }
            return (sheet, box)
        case .fixedTable, .autoSizedTable:
            let valueWidth = Double(value.count - 1) * 6 + 4
            let third = template == .fixedTable ? 420.0 : 200 + valueWidth + 24
            var box: Set<Int> = []
            for k in 0..<5 {
                let y = 680 - pitch * Double(k)
                sheet.word("abcdefg", x: 72, y: y)
                if k == 2 {
                    var x = 200.0
                    for p in parts { box.formUnion(sheet.word(p, x: x, y: y)); x += Double(p.count) * 6 + 4 }
                } else {
                    let n = template == .fixedTable && k == 0 ? 30 : 3
                    sheet.word(String(repeating: "c", count: n), x: 200, y: y)
                }
                sheet.word("abcd", x: third, y: y)
            }
            return (sheet, box)
        }
    }

    struct Verdict: CustomStringConvertible {
        var counted = 0, dOff = 0, dOn = 0, failed = false
        var reduces: Bool { !failed && 2 * dOn <= dOff }
        var description: String { "counted \(counted), D_off \(dOff), D_on \(dOn)\(failed ? ", FAIL" : "")" }
    }

    static func judge(_ template: Template) -> Verdict {
        var offPaints: [PageRect64] = [], onPaints: [PageRect64] = []
        for value in values {
            guard let (sheet, offsets) = page(template, value) else { continue }
            let region = PaintPlanMakeTests.matched(sheet, offsets)
            let off = PaintPlanMakeTests.plan(sheet, [region]).box(region)
            let on = PaintPlanMakeTests.plan(sheet, [region], on: true).box(region)
            offPaints.append(off.paint)
            onPaints.append(on.paint)
        }
        var verdict = Verdict(counted: offPaints.count, dOff: Set(offPaints).count, dOn: Set(onPaints).count)
        var onFor: [PageRect64: PageRect64] = [:]
        for (off, on) in zip(offPaints, onPaints) {
            if let seen = onFor[off], seen != on { verdict.failed = true }
            onFor[off] = on
        }
        return verdict
    }

    @Test("Every template counts at least 36 of its 40 values, none fails, and the switch never adds a difference")
    func noTemplateFails() {
        for template in Template.allCases {
            let v = Self.judge(template)
            #expect(v.counted >= 36, "\(template): \(v)")
            #expect(!v.failed, "\(template): \(v)")
            #expect(v.dOff >= 10, "\(template): the off arm shows differences")
            #expect(v.dOn <= v.dOff, "\(template): \(v)")
        }
    }

    @Test("The justified paragraph, the label rows and the fixed table reduce; the ragged paragraph and the auto-sized table do not")
    func whichTemplatesReduce() {
        for template in [Template.justifiedParagraph, .labelRows, .fixedTable] {
            let v = Self.judge(template)
            #expect(v.reduces, "\(template): \(v)")
        }
        // A ragged line's end moves with the words set before it, and the
        // band is the whole line; a column sized to the value is the value.
        for template in [Template.raggedParagraph, .autoSizedTable] {
            let v = Self.judge(template)
            #expect(!v.reduces, "\(template): \(v)")
        }
    }
}
