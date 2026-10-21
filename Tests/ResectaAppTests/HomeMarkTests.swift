import Testing
import Foundation
import CoreGraphics
import SwiftUI
import UIKit
@testable import ResectaApp

// The mark is the icon's drawing: fifteen shapes on the 821 × 434 unit
// grid whose union is the whole grid, three bars and twelve runs, and a
// hosted height of 48 gives the ink box 90.8 × 48.

@Suite("The home mark")
struct HomeMarkTests {

    @Test("Fifteen shapes: three bars and twelve runs")
    func fifteenShapes() {
        let shapes = HomeMark.shapes
        #expect(shapes.count == 15)
        #expect(shapes.filter { $0.kind == .bar }.count == 3)
        #expect(shapes.filter { $0.kind == .run }.count == 12)
        #expect(shapes.filter { $0.kind == .bar }.allSatisfy { $0.height == 102 && $0.radius == 22 && $0.x == 0 })
        #expect(shapes.filter { $0.kind == .run }.allSatisfy { $0.width == 35 && $0.height == 44 && $0.radius == 8 })
    }

    @Test("The union of the shapes is the whole grid, so the frame is the ink box")
    func unionIsTheGrid() {
        let union = HomeMark.shapes.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            .reduce(CGRect.null) { $0.union($1) }
        #expect(union == CGRect(x: 0, y: 0, width: HomeMark.gridWidth, height: HomeMark.gridHeight), "\(union)")
    }

    @Test("At a height of 48 the mark is 90.8 × 48")
    @MainActor
    func hostedSizeAt48() {
        #expect(abs(HomeMark.width(forHeight: 48) - 90.8) < 0.1)
        // The host rounds the fitted size to whole points; the declared
        // frame is the exact ink box.
        let host = UIHostingController(rootView: HomeMark(height: 48))
        let size = host.sizeThatFits(in: CGSize(width: 1000, height: 1000))
        #expect(abs(size.width - 90.8) <= 0.5, "\(size)")
        #expect(abs(size.height - 48) <= 0.5, "\(size)")
    }
}
