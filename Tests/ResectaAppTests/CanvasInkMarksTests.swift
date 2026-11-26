import Testing
import UIKit
@testable import ResectaApp

// The marks drawn while a finger moves and the tag of a box at rest: the
// box being drawn, the lasso, the rejected band, the alignment guides and
// the tag's rule and place. Sizes are on-screen points; a rectangle here
// is drawn at `fingerScale` overlay points per on-screen point.

@Suite("Canvas ink: the marks of drawing and choosing, and the tag")
@MainActor
struct CanvasInkMarksTests {
    typealias C = ResectaTokens.Canvas

    /// 1 (the page at 100 %), fit (0.64) and 2× zoom.
    nonisolated static let scales: [CGFloat] = [1, 1 / 0.64, 0.5]
    static let plain = CanvasDisplaySettings()
    static let contrast = CanvasDisplaySettings(increaseContrast: true)
    static let white90 = C.Tone(red: 1, green: 1, blue: 1, alpha: 0.9)

    private static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }
    private static func close(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { close($0, $1) }
    }

    @Test("The box being drawn is teal dashes over a white under-stroke, with no label")
    func bandIsTealDashesOverAWhiteUnderStroke() {
        let rect = CGRect(x: 40, y: 60, width: 120, height: 24)
        for f in Self.scales {
            let steps = RedactionOverlayView.bandSteps(rect, settings: Self.plain, fingerScale: f)
            #expect(steps.map(\.layer) == [.bandUnder, .bandFill, .band], "under-stroke, fill, stroke; no text step")
            #expect(steps.allSatisfy { $0.rects == [rect] && $0.words.isEmpty && !$0.roundCaps })
            #expect(steps[0].tone == Self.white90)
            #expect(Self.close(steps[0].width, 3.35 * f), "1.75 + 1.6 on screen")
            #expect(Self.close(steps[0].dash, [6 * f, 3.5 * f]))
            #expect(steps[1].tone == C.Tone(red: C.pageTeal.red, green: C.pageTeal.green, blue: C.pageTeal.blue, alpha: 0.1))
            #expect(steps[1].width == 0)
            #expect(steps[2].tone == C.pageTeal)
            #expect(Self.close(steps[2].width, 1.75 * f))
            #expect(steps[2].dash == steps[0].dash, "the same dash and phase")
        }
        let ink = RedactionOverlayView.bandSteps(rect, settings: Self.contrast)
        #expect(ink[2].tone == C.ink, "Increase Contrast: the dashes are ink")
        #expect(ink[0].tone == Self.white90)
    }

    @Test("The lasso is teal dots over a white under-stroke")
    func lassoIsTealDotsOverAWhiteUnderStroke() {
        let rect = CGRect(x: 10, y: 10, width: 200, height: 90)
        for f in Self.scales {
            let steps = RedactionOverlayView.lassoSteps(rect, settings: Self.plain, fingerScale: f)
            #expect(steps.map(\.layer) == [.lassoUnder, .lassoFill, .lasso])
            #expect(steps[0].roundCaps && steps[2].roundCaps, "round caps make the dots")
            #expect(steps[0].tone == Self.white90)
            #expect(Self.close(steps[0].width, 3.1 * f))
            #expect(steps[1].tone == C.Tone(red: C.pageTeal.red, green: C.pageTeal.green, blue: C.pageTeal.blue, alpha: 0.05))
            #expect(steps[2].tone == C.pageTeal)
            #expect(Self.close(steps[2].width, 1.5 * f))
            for step in [steps[0], steps[2]] {
                #expect(step.dash.count == 2 && step.dash[0] < 0.02 * f)
                #expect(Self.close(step.dash.reduce(0, +) / f, 3.61), "a dot every 3.6 on-screen points")
            }
        }
        #expect(RedactionOverlayView.lassoSteps(rect, settings: Self.contrast)[2].tone == C.ink)
    }

    @Test("A rejected band fades in page teal")
    func rejectedBandFadesInPageTeal() {
        for f in Self.scales {
            let style = RedactionOverlayView.rejectedBandStyle(fingerScale: f)
            #expect(style.border == C.pageTeal.uiColor)
            #expect(style.fill == C.Tone(red: C.pageTeal.red, green: C.pageTeal.green, blue: C.pageTeal.blue, alpha: 0.1).uiColor)
            #expect(Self.close(style.width, 1.75 * f))
        }
        #expect(C.rejectedBand.dash.isEmpty, "no dash")
    }

    // MARK: - The tag

    private static let page = CGRect(x: 0, y: 0, width: 612, height: 792)

    private static func box(_ tight: CGRect, selected: Bool = false, tag: String? = "Email") -> InkBox {
        InkBox(id: UUID(), tight: tight, paint: tight, isSelected: selected, tag: tag)
    }

    private static func tags(_ boxes: [InkBox], selectionCount: Int? = nil, handlesActive: Bool = true,
                             moving: Set<UUID> = [], fingerScale f: CGFloat = 1) -> [InkStep] {
        RedactionOverlayView.inkSteps(
            boxes: boxes, selectionCount: selectionCount ?? boxes.filter(\.isSelected).count,
            handlesActive: handlesActive, moving: moving, settings: plain, fingerScale: f, page: page)
            .filter { $0.layer == .tag || $0.layer == .tagKeyline }
    }

    @Test("The tag shows only on a box at rest, tall and wide enough on screen")
    func tagShowsOnlyOnABoxAtRestTallAndWideEnough() throws {
        let width = RedactionOverlayView.tagWidth("Email")
        #expect(width > 10)
        for f in Self.scales {
            func tight(height: CGFloat, width w: CGFloat = 120) -> CGRect {
                CGRect(x: 100, y: 300, width: w * f, height: height * f)
            }
            #expect(Self.tags([Self.box(tight(height: 14.9))], fingerScale: f).isEmpty, "14.9 on screen: no tag")
            let shown = Self.tags([Self.box(tight(height: 15))], fingerScale: f)
            #expect(shown.map(\.layer) == [.tagKeyline, .tag], "15.0 on screen: a tag")
            let fill = try #require(shown.last)
            let r = try #require(fill.rects.first)
            #expect(fill.tone == C.ink, "the tag is always ink")
            #expect(fill.words == ["Email"])
            #expect(Self.close(r.minX, 100 - 0.7 * f), "flush with the resting line's outer edge")
            #expect(Self.close(r.maxY, 300 - 1.5 * f), "its foot 1.5 above the box")
            #expect(Self.close(r.height, 15 * f))
            #expect(Self.close(r.width, width * f), "words plus 5 each side")
            #expect(Self.close(fill.corner, 3.5 * f))
            let key = shown[0]
            #expect(key.rects == [r.insetBy(dx: -0.4 * f, dy: -0.4 * f)])
            #expect(Self.close(key.corner, 3.9 * f))
            #expect(Self.close(key.width, 0.8 * f))
            #expect(key.tone == Self.white90)
            #expect(Self.tags([Self.box(tight(height: 20, width: width - 0.5))], fingerScale: f).isEmpty,
                    "narrower on screen than its tag: none")
        }
        let tall = CGRect(x: 100, y: 300, width: 120, height: 20)
        #expect(Self.tags([Self.box(tall, tag: nil)]).isEmpty, "a box drawn by hand never")
        #expect(Self.tags([Self.box(tall, selected: true)]).isEmpty, "selected with handles: none")
        let two = [Self.box(tall, selected: true), Self.box(tall.offsetBy(dx: 0, dy: 60), selected: true)]
        #expect(Self.tags(two).isEmpty, "several selected: none")
        #expect(Self.tags([Self.box(tall, selected: true)], handlesActive: false).isEmpty, "Add to Selection: none")
        let moved = Self.box(tall)
        #expect(Self.tags([moved], moving: [moved.id]).isEmpty, "being moved: none")
        let atRest = Self.tags([Self.box(tall), Self.box(tall.offsetBy(dx: 0, dy: 60), selected: true)])
        #expect(atRest.last?.rects.count == 1, "beside a selected box, the box at rest keeps its tag")
    }

    @Test("A tag that would leave the page's top sits below its box, or nowhere")
    func tagAtThePageTopSitsBelow() throws {
        let nearTop = CGRect(x: 100, y: 10, width: 120, height: 20)
        let below = try #require(Self.tags([Self.box(nearTop)]).last?.rects.first)
        #expect(Self.close(below.minY, nearTop.maxY + 1.5), "its top 1.5 under the box's bottom edge")
        #expect(Self.close(below.minX, nearTop.minX - 0.7), "the same leading edge")
        let pageTall = CGRect(x: 100, y: 0, width: 120, height: 792)
        #expect(Self.tags([Self.box(pageTall)]).isEmpty, "fits neither above nor below: none")
        for step in Self.tags([Self.box(nearTop), Self.box(CGRect(x: 300, y: 400, width: 120, height: 20))]) {
            #expect(step.rects.allSatisfy { Self.page.insetBy(dx: -1, dy: -1).contains($0) }, "never past the page's edge")
        }
    }

    @Test("Tags come after every box's layers and before handles and dots")
    func tagsComeBetweenTheBoxesAndTheMarks() {
        let a = Self.box(CGRect(x: 100, y: 300, width: 120, height: 20))
        let b = Self.box(CGRect(x: 100, y: 400, width: 120, height: 20), selected: true)
        let layers = RedactionOverlayView.inkSteps(boxes: [a, b], selectionCount: 1, handlesActive: true,
                                                   settings: Self.plain, page: Self.page).map(\.layer)
        let tag = layers.firstIndex(of: .tagKeyline)
        #expect(tag != nil && tag == layers.lastIndex(of: .line).map { $0 + 1 }, "the tags follow the last line")
        #expect(layers.last == .handles)
    }

    // MARK: - Guides

    @Test("A guide is page teal over a white under-stroke")
    func guideIsPageTealOverAWhiteUnderStroke() {
        let lines = [CGPoint(x: 0, y: 120), CGPoint(x: 612, y: 120)]
        for f in Self.scales {
            let steps = RedactionOverlayView.guideSteps(lines: lines, settings: Self.plain, fingerScale: f)
            #expect(steps.map(\.layer) == [.guideUnder, .guide])
            #expect(steps.allSatisfy { $0.lines == lines && $0.rects.isEmpty && $0.dash.isEmpty })
            #expect(steps[0].tone == Self.white90)
            #expect(Self.close(steps[0].width, 2.6 * f))
            #expect(steps[1].tone == C.pageTeal, "opaque page teal")
            #expect(Self.close(steps[1].width, 1 * f))
        }
        #expect(RedactionOverlayView.guideSteps(lines: lines, settings: Self.contrast)[1].tone == C.ink,
                "Increase Contrast: ink")
        #expect(RedactionOverlayView.guideSteps(lines: [], settings: Self.plain).isEmpty)
    }

    // MARK: - No size label

    @Test("The overlay's sources hold no size label")
    func overlaySourcesHoldNoSizeLabel() throws {
        let words = ["dimensionLabel", "DimensionLabel", "dimension label", "dimension-label", "resize label", "size label"]
        for file in ["RedactionOverlayView+Draw.swift", "RedactionOverlayView+CanvasPolish.swift",
                     "RedactionOverlayView.swift", "RedactionOverlayView+Touches.swift"] {
            let source = try loadRepoFile("Sources/ResectaApp/Overlay/" + file)
            for word in words { #expect(!source.contains(word), "\(file) names \"\(word)\"") }
        }
    }

    private func loadRepoFile(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: "\(file)")
        let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
