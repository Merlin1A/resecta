import Testing
import Foundation
import SwiftUI
import UIKit
@testable import ResectaApp

// The colours and lines of the message surfaces, resolved under the light
// and the dark trait, with and without Increase Contrast. Every expected
// value is the design's, written out here, never read from the tokens.

@Suite("Message surface ink")
struct InkTokensTests {

    typealias Ink = ResectaTokens.Ink

    /// One expected colour: a 24-bit hex value and its opacity.
    struct Value {
        let hex: UInt32
        let alpha: CGFloat
        init(_ hex: UInt32, _ alpha: CGFloat = 1) {
            self.hex = hex
            self.alpha = alpha
        }
    }

    static var sources: URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
    }

    static func trait(_ style: UIUserInterfaceStyle, highContrast: Bool = false) -> UITraitCollection {
        let base = UITraitCollection(userInterfaceStyle: style)
        return highContrast ? base.modifyingTraits { $0.accessibilityContrast = .high } : base
    }

    // Component equality within 1/255: the values are authored as 8-bit
    // sRGB; the tolerance only absorbs float rounding.
    static func expectColor(_ color: Color, under trait: UITraitCollection, _ expected: Value, _ label: String) {
        let resolved = UIColor(color).resolvedColor(with: trait)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #expect(resolved.getRed(&r, green: &g, blue: &b, alpha: &a), "\(label)")
        let er = CGFloat((expected.hex >> 16) & 0xFF) / 255
        let eg = CGFloat((expected.hex >> 8) & 0xFF) / 255
        let eb = CGFloat(expected.hex & 0xFF) / 255
        let tolerance: CGFloat = 1.0 / 255.0
        #expect(abs(r - er) <= tolerance && abs(g - eg) <= tolerance && abs(b - eb) <= tolerance
                && abs(a - expected.alpha) <= tolerance,
                "\(label): \(r * 255), \(g * 255), \(b * 255), \(a)")
    }

    @Test("The ink tokens hold the frame's values, light, dark and with Increase Contrast")
    func tokensHoldTheFramesValues() {
        // Each two-valued name: its value under the light scheme, then
        // under the dark scheme.
        let twoValued: [(String, Color, Value, Value)] = [
            ("cautionMark", Ink.cautionMark, Value(0x9A5B00), Value(0xFF9F0A)),
            ("stopMark", Ink.stopMark, Value(0xC2262E), Value(0xFF7A72)),
            ("noteMark", Ink.noteMark, Value(0x111214, 0.72), Value(0xFFFFFF, 0.82)),
            ("words", Ink.words, Value(0x111214), Value(0xFFFFFF)),
            ("secondaryWords", Ink.secondaryWords, Value(0x4A4A52), Value(0xB8B8C3)),
            ("innerEdge", Ink.innerEdge, Value(0x000000, 0.12), Value(0xFFFFFF, 0.20)),
            ("outerEdge", Ink.outerEdge, Value(0x000000, 0.24), Value(0xFFFFFF, 0.10)),
            ("quietPill", Ink.quietPill, Value(0x111214, 0.10), Value(0xFFFFFF, 0.16)),
            ("solidPill", Ink.solidPill, Value(0x16181A), Value(0xFFFFFF)),
            ("solidPillWords", Ink.solidPillWords, Value(0xFFFFFF), Value(0x16181A)),
        ]
        var resolved = 0
        for (name, color, light, dark) in twoValued {
            Self.expectColor(color, under: Self.trait(.light), light, "\(name), light")
            Self.expectColor(color, under: Self.trait(.dark), dark, "\(name), dark")
            resolved += 2
        }
        #expect(twoValued.count == 10)
        #expect(resolved == 20)

        // Increase Contrast doubles the two edges' strength and changes no
        // other colour.
        let doubled: [(String, Color, Value, Value)] = [
            ("innerEdge", Ink.innerEdge, Value(0x000000, 0.24), Value(0xFFFFFF, 0.40)),
            ("outerEdge", Ink.outerEdge, Value(0x000000, 0.48), Value(0xFFFFFF, 0.20)),
        ]
        for (name, color, light, dark) in doubled {
            Self.expectColor(color, under: Self.trait(.light, highContrast: true), light, "\(name), light, Increase Contrast")
            Self.expectColor(color, under: Self.trait(.dark, highContrast: true), dark, "\(name), dark, Increase Contrast")
        }
        #expect(doubled.count == 2)
        let edgeNames: Set<String> = ["innerEdge", "outerEdge"]
        var unchanged = 0
        for (name, color, light, dark) in twoValued where !edgeNames.contains(name) {
            Self.expectColor(color, under: Self.trait(.light, highContrast: true), light, "\(name), light, Increase Contrast")
            Self.expectColor(color, under: Self.trait(.dark, highContrast: true), dark, "\(name), dark, Increase Contrast")
            unchanged += 1
        }
        #expect(unchanged == 8)

        #expect(Ink.edgeWidth == 0.5)

        // The surface takes the app's appearance, not the content's scheme,
        // so it is resolved under both traits and gives the same value.
        let surfaces: [(String, ColorScheme, Bool, Value)] = [
            ("light appearance", .light, false, Value(0x16181A, 0.94)),
            ("light appearance, Increase Contrast", .light, true, Value(0x16181A, 1)),
            ("dark appearance", .dark, false, Value(0xF2F2F4, 0.96)),
            ("dark appearance, Increase Contrast", .dark, true, Value(0xF2F2F4, 1)),
        ]
        for (name, appearance, contrast, expected) in surfaces {
            let color = Ink.surface(for: appearance, increasedContrast: contrast)
            for style in [UIUserInterfaceStyle.light, .dark] {
                Self.expectColor(color, under: Self.trait(style, highContrast: contrast), expected,
                                 "surface, \(name), under the \(style == .dark ? "dark" : "light") trait")
            }
        }
        #expect(surfaces.count == 4)

        // Two black shadows for each appearance; blur is the drawing's own
        // figure.
        #expect(Ink.shadows(for: .light) == [
            ResectaTokens.InkShadow(y: 4, blur: 16, opacity: 0.18),
            ResectaTokens.InkShadow(y: 1, blur: 3, opacity: 0.14),
        ])
        #expect(Ink.shadows(for: .dark) == [
            ResectaTokens.InkShadow(y: 6, blur: 22, opacity: 0.55),
            ResectaTokens.InkShadow(y: 1, blur: 3, opacity: 0.40),
        ])
    }

    @Test("The message surface's marks keep their own two values")
    func marksKeepTheirOwnTwoValues() throws {
        let marks: [(String, Color, Value, Value)] = [
            ("stopMark", Ink.stopMark, Value(0xC2262E), Value(0xFF7A72)),
            ("noteMark", Ink.noteMark, Value(0x111214, 0.72), Value(0xFFFFFF, 0.82)),
        ]
        for (name, color, light, dark) in marks {
            Self.expectColor(color, under: Self.trait(.light), light, "\(name), light")
            Self.expectColor(color, under: Self.trait(.dark), dark, "\(name), dark")
        }
        #expect(marks.count == 2)

        // The whole token file, comments included, names no semantic colour:
        // each value is written out, none is an alias.
        let text = try String(contentsOf: Self.sources.appendingPathComponent("Design/ResectaTokens+Ink.swift"),
                              encoding: .utf8)
        #expect(text.split(separator: "\n").count > 100, "the token file was not read")
        #expect(text.contains("enum Ink"))
        #expect(!text.contains("SemanticColor."))
    }

    @Test("The message surfaces' token group holds its thirteen names")
    func tokenGroupHoldsItsThirteenNames() throws {
        let text = try String(contentsOf: Self.sources.appendingPathComponent("Design/ResectaTokens+Ink.swift"),
                              encoding: .utf8)
        // The names declared directly inside `enum Ink`, read from the source
        // by brace depth: one level in, a line that starts `static let` or
        // `static func`.
        var names: [String] = []
        var depth = 0
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inside, trimmed.contains("enum Ink {") { inside = true; depth = 0 }
            guard inside else { continue }
            if depth == 1, !trimmed.hasPrefix("//") {
                for head in ["static let ", "static func "] where trimmed.hasPrefix(head) {
                    let rest = trimmed.dropFirst(head.count)
                    names.append(String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }))
                }
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if depth == 0, trimmed.contains("}") { break }
        }
        #expect(names == ["cautionMark", "stopMark", "noteMark", "words", "secondaryWords", "innerEdge", "outerEdge",
                          "edgeWidth", "quietPill", "solidPill", "solidPillWords", "surface", "shadows"])
    }
}
