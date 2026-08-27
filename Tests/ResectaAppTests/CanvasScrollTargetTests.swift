import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp

// SA-3 rider (D-70): rect-level scroll-to-match seams.
// `DocumentState.requestCanvasScroll` is the writer contract every
// result-navigation site shares; `PDFDocumentView.shouldRectScroll`
// is the consumer's zoom gate. The normalized→page-space conversion
// is deliberately NOT re-pinned here — the consumer reuses the
// engine's canonical `normalizedToPDFPageCoordinates` (ENGINE
// §5B.1a), which the engine suite owns.

@Suite("Canvas scroll-to-match target")
@MainActor
struct CanvasScrollTargetTests {

    @Test("requestCanvasScroll stores the page and rect")
    func requestStoresPageAndRect() {
        let doc = DocumentState()
        let rect = CGRect(x: 0.25, y: 0.5, width: 0.1, height: 0.05)
        doc.requestCanvasScroll(toPageIndex: 3, normalizedRect: rect)
        #expect(doc.pendingCanvasScrollTarget?.pageIndex == 3)
        #expect(doc.pendingCanvasScrollTarget?.normalizedRect == rect)
    }

    @Test("re-requesting the same rect mints a fresh token — every navigation is consumable once")
    func repeatRequestMintsFreshToken() {
        let doc = DocumentState()
        let rect = CGRect(x: 0.25, y: 0.5, width: 0.1, height: 0.05)
        doc.requestCanvasScroll(toPageIndex: 3, normalizedRect: rect)
        let first = doc.pendingCanvasScrollTarget
        doc.requestCanvasScroll(toPageIndex: 3, normalizedRect: rect)
        let second = doc.pendingCanvasScrollTarget
        #expect(first != nil && second != nil)
        #expect(first?.token != second?.token,
                "Re-navigating to the same match must be a fresh consumable request.")
        #expect(first?.pageIndex == second?.pageIndex)
        #expect(first?.normalizedRect == second?.normalizedRect)
    }

    @Test("zoom gate: rect-scroll only fires meaningfully past fit scale")
    func zoomGate() {
        // At fit (and below): the whole page is visible — page-granular
        // navigation suffices; go(to:on:) would zoom unexpectedly.
        #expect(!PDFDocumentView.shouldRectScroll(scaleFactor: 1.0, fitScaleFactor: 1.0))
        #expect(!PDFDocumentView.shouldRectScroll(scaleFactor: 0.8, fitScaleFactor: 1.0))
        // Inside the 1% autoScales float-noise epsilon: still page-only.
        #expect(!PDFDocumentView.shouldRectScroll(scaleFactor: 1.005, fitScaleFactor: 1.0))
        // Meaningfully zoomed: the match can be off-screen — rect-scroll.
        #expect(PDFDocumentView.shouldRectScroll(scaleFactor: 1.02, fitScaleFactor: 1.0))
        #expect(PDFDocumentView.shouldRectScroll(scaleFactor: 2.0, fitScaleFactor: 1.0))
    }

    // UXC-50 (D-128, RB-123): the zoom intent rides the same seam.

    @Test("zoom intent defaults to .none — every existing writer is source-compatible")
    func zoomIntentDefaultsToNone() {
        let doc = DocumentState()
        doc.requestCanvasScroll(toPageIndex: 1, normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(doc.pendingCanvasScrollTarget?.zoom == DocumentState.CanvasZoomIntent.none)
    }

    @Test(".readability intent round-trips with page and rect")
    func readabilityIntentRoundTrips() {
        let doc = DocumentState()
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.02)
        doc.requestCanvasScroll(toPageIndex: 2, normalizedRect: rect, zoom: .readability)
        #expect(doc.pendingCanvasScrollTarget?.zoom == .readability)
        #expect(doc.pendingCanvasScrollTarget?.pageIndex == 2)
        #expect(doc.pendingCanvasScrollTarget?.normalizedRect == rect)
    }
}

// UXC-50 (D-128, RB-123 item 1): the readability formula is pure and
// pinned here — text ≈`textHeightTarget` on screen, width-guarded,
// clamped to [fit … min(navZoomCap × fit, maxScale)]. Constants live in
// `ReadabilityZoom` (the tuning surface); the pins read them
// symbolically so a tune does not rewrite arithmetic.
@Suite("Readability zoom policy (UXC-50)")
struct ReadabilityZoomPolicyTests {

    private let viewport = CGSize(width: 400, height: 800)

    @Test("small rect: the height rule wins and lands inside the clamp")
    func heightRuleWins() {
        // 10-pt-tall text → target/10 (2.0× at the 20-pt default);
        // width fit (400 − 2·16)/100 = 3.68 is looser.
        let s = PDFDocumentView.readabilityTargetScale(
            rectInPage: CGRect(x: 0, y: 0, width: 100, height: 10),
            viewportSize: viewport, fitScale: 1.0, maxScale: 8.0)
        #expect(s == ReadabilityZoom.textHeightTarget / 10)
    }

    @Test("page-wide rect computes below fit ⇒ clamps to fit = no zoom")
    func pageWideClampsToFit() {
        // widthFit = 368/800 = 0.46 < fit 0.5 → clamp up to fit.
        let s = PDFDocumentView.readabilityTargetScale(
            rectInPage: CGRect(x: 0, y: 0, width: 800, height: 12),
            viewportSize: viewport, fitScale: 0.5, maxScale: 8.0)
        #expect(s == 0.5)
    }

    @Test("tiny rect clamps to navZoomCap × fit")
    func tinyRectClampsToCap() {
        let s = PDFDocumentView.readabilityTargetScale(
            rectInPage: CGRect(x: 0, y: 0, width: 20, height: 2),
            viewportSize: viewport, fitScale: 1.0, maxScale: 10.0)
        #expect(s == ReadabilityZoom.navZoomCap * 1.0)
    }

    @Test("maxScale wins when it sits below the cap — never past PDFKit's ceiling")
    func maxScaleWinsBelowCap() {
        let s = PDFDocumentView.readabilityTargetScale(
            rectInPage: CGRect(x: 0, y: 0, width: 20, height: 2),
            viewportSize: viewport, fitScale: 1.0, maxScale: 2.5)
        #expect(s == 2.5)
    }

    @Test("degenerate rect or geometry yields nil — the scale is left alone")
    func degenerateYieldsNil() {
        #expect(PDFDocumentView.readabilityTargetScale(
            rectInPage: CGRect(x: 0, y: 0, width: 0, height: 10),
            viewportSize: viewport, fitScale: 1.0, maxScale: 8.0) == nil)
        #expect(PDFDocumentView.readabilityTargetScale(
            rectInPage: CGRect(x: 0, y: 0, width: 100, height: 0.0005),
            viewportSize: viewport, fitScale: 1.0, maxScale: 8.0) == nil)
        #expect(PDFDocumentView.readabilityTargetScale(
            rectInPage: CGRect(x: 0, y: 0, width: 100, height: 10),
            viewportSize: viewport, fitScale: 0, maxScale: 8.0) == nil)
        #expect(PDFDocumentView.readabilityTargetScale(
            rectInPage: CGRect(x: 0, y: 0, width: 100, height: 10),
            viewportSize: .zero, fitScale: 1.0, maxScale: 8.0) == nil)
    }

    @Test("a doubled-height (multi-line) united rect zooms strictly less than its single-line slice")
    func multiLineZoomsLess() {
        let single = PDFDocumentView.readabilityTargetScale(
            rectInPage: CGRect(x: 0, y: 0, width: 100, height: 8),
            viewportSize: viewport, fitScale: 1.0, maxScale: 8.0)
        let doubled = PDFDocumentView.readabilityTargetScale(
            rectInPage: CGRect(x: 0, y: 0, width: 100, height: 16),
            viewportSize: viewport, fitScale: 1.0, maxScale: 8.0)
        #expect(single != nil && doubled != nil)
        #expect(doubled! < single!)
        #expect(single! <= ReadabilityZoom.navZoomCap && doubled! >= 1.0)
    }
}
