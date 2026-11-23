import Testing
import UIKit
@testable import ResectaApp

// The canvas's resize handles and corner dots: the tokens they are drawn
// with, where the one function for handle centres puts them, where the
// corner dots go, and the hit test reading the same function the drawing
// reads. Sizes are on-screen points; a rectangle here is drawn at
// `fingerScale` overlay points per on-screen point.

@Suite("Canvas ink: handles and corner dots")
@MainActor
struct CanvasInkLookTests {
    typealias C = ResectaTokens.Canvas
    typealias Handle = RedactionOverlayView.ResizeHandle

    /// 1 (the page at 100 %), fit (0.64) and 2× zoom.
    nonisolated static let scales: [CGFloat] = [1, 1 / 0.64, 0.5]

    private static func components(_ color: UIColor, _ style: UIUserInterfaceStyle = .light) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a]
    }

    private static func near(_ x: [CGFloat], _ y: [CGFloat]) -> Bool {
        x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) <= 1.0 / 255 }
    }

    private static func centres(_ size: CGSize, _ s: CGFloat) -> [Handle: CGPoint] {
        let rect = CGRect(x: 0, y: 0, width: size.width * s, height: size.height * s)
        return Dictionary(uniqueKeysWithValues: RedactionOverlayView.handleCentres(for: rect, fingerScale: s))
    }

    @Test("The canvas tokens hold the ruled values")
    func tokensHoldTheRuledValues() {
        let teal: [CGFloat] = [0x0B / 255, 0x64 / 255, 0x6F / 255, 1]
        #expect(Self.near(Self.components(C.pageTeal.uiColor), teal))
        #expect(Self.near(Self.components(C.pageTeal.uiColor, .dark), teal), "page teal is the same in dark appearance")

        #expect(C.handle.radius == 4.5)
        #expect(Self.near(Self.components(C.handle.fill.uiColor), [1, 1, 1, 1]), "a handle is a white disc")
        #expect(C.handle.ring == C.pageTeal, "with a page-teal ring")
        #expect(C.handle.ringWidth == 1.75)
        #expect(Self.near(Self.components(C.handleShadow.uiColor), [0, 0, 0, 0.12]))
        #expect(C.handleShadowGrowth == 1.2 && C.handleShadowDrop == 0.6)

        #expect(C.selectionDot.radius == 2.75)
        #expect(C.selectionDot.fill == C.pageTeal)
        #expect(Self.near(Self.components(C.selectionDot.ring.uiColor), [1, 1, 1, 0.9]))
        #expect(C.selectionDot.ringWidth == 0.8)

        #expect(C.handlesStepOutBelow == 22 && C.handleLargestStep == 6.5 && C.edgeHandleShortestSide == 60)
        #expect(C.dotsStepOutBelow == 12 && C.dotLargestStep == 4)
    }

    @Test("Handle centres: four corners, an edge handle only on a side of 60 on-screen points, corners stepped clear of a thin box",
          arguments: scales)
    func handleCentresFollowTheRule(_ s: CGFloat) throws {
        // On a short axis the handles at its two ends step out by half the
        // shortfall under 22, at most 6.5.
        for (height, out) in [(9, 6.5), (20, 1), (22, 0), (100, 0)] as [(CGFloat, CGFloat)] {
            let c = Self.centres(CGSize(width: 120, height: height), s)
            let label = "120 x \(height) at \(s)"
            let topLeft = try #require(c[.topLeft], "\(label): a corner"), bottomRight = try #require(c[.bottomRight])
            #expect(abs(topLeft.y + out * s) < 1e-9, "\(label): the top corners \(out) above")
            #expect(abs(bottomRight.y - (height + out) * s) < 1e-9, "\(label): the bottom corners \(out) below")
            #expect(topLeft.x == 0 && bottomRight.x == 120 * s, "\(label): a long axis does not step")
            let top = try #require(c[.topCenter], "\(label): the long top side has its middle handle")
            #expect(abs(top.y + out * s) < 1e-9, "\(label): the middle handle steps with its axis")
        }
        // A middle handle only on a side of at least 60.
        #expect(Self.centres(CGSize(width: 59.9, height: 200), s)[.topCenter] == nil, "59.9: no edge handle")
        #expect(Self.centres(CGSize(width: 59.9, height: 200), s)[.leftCenter] != nil)
        #expect(Self.centres(CGSize(width: 60, height: 200), s)[.topCenter] != nil, "60: one")
        #expect(Self.centres(CGSize(width: 105, height: 200), s)[.bottomCenter] != nil, "105: one")
        #expect(Self.centres(CGSize(width: 200, height: 59.9), s)[.rightCenter] == nil)
        #expect(Self.centres(CGSize(width: 59.9, height: 59.9), s).count == 4, "a small box: the corners alone")
        #expect(Self.centres(CGSize(width: 60, height: 60), s).count == 8)
    }

    @Test("Corner dots step out under 12 points, at most 4", arguments: scales)
    func cornerDotsStepOut(_ s: CGFloat) {
        for (height, out) in [(8, 2), (11.9, 0.05), (12, 0), (30, 0), (2, 4)] as [(CGFloat, CGFloat)] {
            let dots = RedactionOverlayView.selectionDotCentres(
                for: CGRect(x: 0, y: 0, width: 120 * s, height: height * s), fingerScale: s)
            #expect(dots.count == 4, "four dots")
            #expect(dots.allSatisfy { $0.x == 0 || $0.x == 120 * s }, "\(height) at \(s): a long axis does not step")
            #expect(dots.filter { abs($0.y + out * s) < 1e-9 }.count == 2, "\(height) at \(s): two dots \(out) above")
            #expect(dots.filter { abs($0.y - (height + out) * s) < 1e-9 }.count == 2, "\(height) at \(s): two dots \(out) below")
        }
    }

    @Test("The hit test reads the drawing's handle centres", arguments: scales)
    func hitTestReadsTheDrawnCentres(_ s: CGFloat) {
        let sizes = [CGSize(width: 9, height: 120), CGSize(width: 40, height: 40), CGSize(width: 59.9, height: 200),
                     CGSize(width: 60, height: 60), CGSize(width: 200, height: 200)]
        let edges: Set<Handle> = [.topCenter, .bottomCenter, .leftCenter, .rightCenter]
        for size in sizes {
            let rect = CGRect(x: 100, y: 100, width: size.width * s, height: size.height * s)
            func resolve(_ p: CGPoint) -> Handle? {
                RedactionOverlayView.resolveResizeHandle(
                    at: p, regionRect: rect, targetHandleSize: ResectaTokens.TouchTarget.minimum * s,
                    minimumHandleSize: 22 * s, fingerScale: s)
            }
            for (handle, centre) in RedactionOverlayView.handleCentres(for: rect, fingerScale: s) {
                #expect(resolve(centre) == handle, "\(size) at \(s): the drawn \(handle) is that handle")
            }
            var shortMiddles: [CGPoint] = []
            if size.width < 60 { shortMiddles += [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY)] }
            if size.height < 60 { shortMiddles += [CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)] }
            for p in shortMiddles {
                #expect(resolve(p).map { !edges.contains($0) } ?? true, "\(size) at \(s): a short side's middle \(p) is no edge handle")
            }
        }
    }
}
