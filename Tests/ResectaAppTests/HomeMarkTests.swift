import Testing
import Foundation
import CoreGraphics
import SwiftUI
import UIKit
@testable import ResectaApp

// The mark is the icon's drawing: fifteen shapes on the 821 × 435 unit
// grid whose union is the whole grid, three bars and twelve runs, placed at
// the icon's (106, 286) on its 1024 canvas, on a square tile; a hosted size
// of 96 gives a 96 × 96 tile. The colours are the icon's, measured from the
// 1024 px icons.

@Suite("The home mark")
struct HomeMarkTests {

    @Test("Fifteen shapes: three bars and twelve runs, at the icon's sizes")
    func fifteenShapes() {
        let shapes = HomeMark.shapes
        #expect(shapes.count == 15)
        #expect(shapes.filter { $0.kind == .bar }.count == 3)
        #expect(shapes.filter { $0.kind == .run }.count == 12)
        #expect(shapes.filter { $0.kind == .bar }.allSatisfy { $0.height == 103 && $0.radius == 25 && $0.x == 0 })
        #expect(shapes.filter { $0.kind == .run }.allSatisfy { $0.width == 35 && $0.height == 45 && $0.radius == 9 })
    }

    @Test("The union of the shapes is the whole grid, so the grid is the ink box")
    func unionIsTheGrid() {
        let union = HomeMark.shapes.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            .reduce(CGRect.null) { $0.union($1) }
        #expect(union == CGRect(x: 0, y: 0, width: HomeMark.gridWidth, height: HomeMark.gridHeight), "\(union)")
    }

    @Test("The ink box sits where the icon's does, inside the canvas")
    func inkBoxOnTheCanvas() {
        let box = CGRect(origin: HomeMark.inkOrigin, size: CGSize(width: HomeMark.gridWidth, height: HomeMark.gridHeight))
        #expect(box == CGRect(x: 106, y: 286, width: 821, height: 435))
        #expect(CGRect(x: 0, y: 0, width: HomeMark.canvas, height: HomeMark.canvas).contains(box))
        #expect(HomeMark.cornerFraction == 0.26)
    }

    @Test("At a size of 96 the tile is 96 × 96")
    @MainActor
    func hostedSizeAt96() {
        let host = UIHostingController(rootView: HomeMark(size: 96))
        let size = host.sizeThatFits(in: CGSize(width: 1000, height: 1000))
        #expect(abs(size.width - 96) <= 0.5, "\(size)")
        #expect(abs(size.height - 96) <= 0.5, "\(size)")
    }

    @Test("The colours are the icon's, light and dark", arguments: [
        UIUserInterfaceStyle.light, UIUserInterfaceStyle.dark
    ])
    func iconColours(style: UIUserInterfaceStyle) {
        let dark = style == .dark
        let expected: [(String, Color, UInt32)] = [
            ("field", ResectaTokens.BrandMark.field, dark ? 0x000000 : 0xFBFAF6),
            ("ink", ResectaTokens.BrandMark.ink, dark ? 0xF2F1EC : 0x0E0E14),
            ("teal", ResectaTokens.BrandMark.teal, dark ? 0x1799AC : 0x128697),
            ("runs", ResectaTokens.BrandMark.runs, dark ? 0xA5A39B : 0x8B887F),
        ]
        let trait = UITraitCollection(userInterfaceStyle: style)
        for (name, color, hex) in expected {
            expectColor(color, trait: trait, hex: hex, "\(name) (\(dark ? "dark" : "light"))")
        }
    }

    @Test("Under Increase Contrast the ink is pure black or white", arguments: [
        UIUserInterfaceStyle.light, UIUserInterfaceStyle.dark
    ])
    func highContrastInk(style: UIUserInterfaceStyle) {
        let trait = UITraitCollection(userInterfaceStyle: style).modifyingTraits {
            $0.accessibilityContrast = .high
        }
        expectColor(ResectaTokens.BrandMark.ink, trait: trait, hex: style == .dark ? 0xFFFFFF : 0x000000,
                    "ink at Increase Contrast (\(style == .dark ? "dark" : "light"))")
    }

    @Test("The edge: a black hairline in light, a white rim in dark, stronger at Increase Contrast", arguments: [
        UIUserInterfaceStyle.light, UIUserInterfaceStyle.dark
    ])
    func edgeStops(style: UIUserInterfaceStyle) {
        let dark = style == .dark
        let standard: [CGFloat] = dark ? [0.32, 0.14, 0.20] : [0.07, 0.07, 0.07]
        let high: [CGFloat] = dark ? [0.55, 0.40, 0.45] : [0.20, 0.20, 0.20]
        let base = UITraitCollection(userInterfaceStyle: style)
        let contrast = base.modifyingTraits { $0.accessibilityContrast = .high }
        #expect(ResectaTokens.BrandMark.edge.count == 3)
        for (trait, alphas) in [(base, standard), (contrast, high)] {
            for (stop, alpha) in zip(ResectaTokens.BrandMark.edge, alphas) {
                expectColor(stop, trait: trait, hex: dark ? 0xFFFFFF : 0x000000, alpha: alpha,
                            "edge (\(dark ? "dark" : "light"))")
            }
        }
    }

    // Component equality within 1/255: the tokens are authored as sRGB
    // 8-bit hex; the tolerance only absorbs float rounding.
    private func expectColor(_ color: Color, trait: UITraitCollection, hex: UInt32, alpha: CGFloat = 1, _ label: String) {
        let resolved = UIColor(color).resolvedColor(with: trait)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #expect(resolved.getRed(&r, green: &g, blue: &b, alpha: &a), "\(label)")
        let er = CGFloat((hex >> 16) & 0xFF) / 255
        let eg = CGFloat((hex >> 8) & 0xFF) / 255
        let eb = CGFloat(hex & 0xFF) / 255
        let tolerance: CGFloat = 1.0 / 255.0
        #expect(abs(r - er) <= tolerance && abs(g - eg) <= tolerance && abs(b - eb) <= tolerance && abs(a - alpha) <= tolerance,
                "\(label): \(r * 255), \(g * 255), \(b * 255), \(a)")
    }
}
