import Testing
import Foundation
import SwiftUI
@testable import ResectaApp

// The text size a brief message is drawn at: the person's size while the
// message is within 40 % of the space it is read in, else the first size
// down to the third accessibility size at which it is, else the third. Every
// expectation is the case table below, written out, not derived from the
// code under test.

@Suite("Message sizing")
struct MessageSizingTests {

    /// One case: the person's size, the space, the message's height at the
    /// sizes the case names (any size it does not name is taller than any
    /// limit), and the size it must be drawn at.
    struct Row {
        let name: String
        let person: DynamicTypeSize
        let space: CGFloat
        let heights: [DynamicTypeSize: CGFloat]
        let expected: DynamicTypeSize
    }

    static let rows: [Row] = [
        Row(name: "S-1", person: .accessibility5, space: 590,
            heights: [.accessibility5: 381, .accessibility4: 300, .accessibility3: 207],
            expected: .accessibility3),
        Row(name: "S-2", person: .accessibility5, space: 590,
            heights: [.accessibility5: 381, .accessibility4: 230, .accessibility3: 207],
            expected: .accessibility4),
        // Every height over the limit: the third accessibility size, over it.
        Row(name: "S-3", person: .accessibility5, space: 590,
            heights: [.accessibility5: 381, .accessibility4: 300, .accessibility3: 255],
            expected: .accessibility3),
        // At or below the third accessibility size the person's own size,
        // whatever the height.
        Row(name: "S-4", person: .accessibility2, space: 590,
            heights: [.accessibility2: 400, .accessibility1: 400, .xxxLarge: 400, .large: 400],
            expected: .accessibility2),
        Row(name: "S-5", person: .large, space: 654,
            heights: [:],
            expected: .large),
        Row(name: "S-6", person: .accessibility4, space: 590,
            heights: [.accessibility4: 300, .accessibility3: 207],
            expected: .accessibility3),
    ]

    @Test("The size a message is drawn at, by table")
    func drawSizeByTable() {
        for row in Self.rows {
            let limit = MessageSizing.limit(space: row.space)
            let size = MessageSizing.drawSize(person: row.person, limit: limit) { step in
                row.heights[step] ?? .greatestFiniteMagnitude
            }
            #expect(size == row.expected, "\(row.name): \(size)")
        }
        #expect(Self.rows.count == 6)
    }

    @Test("The limit is 40 % of the space read from the layout")
    func limitIsFortyPercentOfTheSpace() {
        let cases: [(CGFloat, CGFloat)] = [(590, 236), (654, 261.6)]
        for (space, expected) in cases {
            let limit = MessageSizing.limit(space: space)
            #expect(abs(limit - expected) < 1e-9, "\(space) gives \(limit)")
        }
        #expect(cases.count == 2)
    }
}
