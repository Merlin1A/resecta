import Testing
import UIKit
import PDFKit
import ObjectiveC
@testable import ResectaApp

// The canvas view and PDFKit's gesture recognizers. PDFKit sets the PDF
// view as the delegate of its own recognizers, and which delegate methods
// PDFView implements changes between iOS releases (iOS 27 dropped
// `gestureRecognizer:shouldReceiveTouch:`). An override in the subclass
// that calls `super` makes the view answer a question its superclass may
// not, so UIKit asks it and `super` throws an unrecognized selector on the
// first touch. The subclass therefore implements no gesture delegate
// method; the double tap answers through its own delegate object.

@Suite("Canvas gesture delegate")
@MainActor
struct CanvasGestureDelegateTests {

    /// The instance selectors a class implements itself, not inherited.
    private static func ownSelectors(of cls: AnyClass) -> Set<Selector> {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return [] }
        defer { free(methods) }
        return Set((0..<Int(count)).map { method_getName(methods[$0]) })
    }

    /// Every instance method the protocol declares, required or optional.
    private static func selectors(of protocolName: String) -> Set<Selector> {
        guard let proto = objc_getProtocol(protocolName) else { return [] }
        var result = Set<Selector>()
        for required in [true, false] {
            var count: UInt32 = 0
            guard let list = protocol_copyMethodDescriptionList(proto, required, true, &count) else { continue }
            defer { free(list) }
            for i in 0..<Int(count) { if let name = list[i].name { result.insert(name) } }
        }
        return result
    }

    private func makeView() -> (view: FitFlooredPDFView, window: UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 684))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.autoScales = true
        view.displayMode = .singlePage
        let size = CGSize(width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { ctx in
            ctx.beginPage()
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 36, y: 36, width: 100, height: 12))
        }
        view.document = PDFDocument(data: data)
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        return (view, window)
    }

    @Test("The PDF view subclass implements no gesture recognizer delegate method of its own")
    func subclassImplementsNoGestureDelegateMethod() throws {
        let delegateSelectors = Self.selectors(of: "UIGestureRecognizerDelegate")
        try #require(delegateSelectors.contains(Selector(("gestureRecognizer:shouldReceiveTouch:"))),
                     "the runtime serves the protocol's method list")
        let own = Self.ownSelectors(of: FitFlooredPDFView.self).intersection(delegateSelectors)
        #expect(own.isEmpty, "FitFlooredPDFView implements \(own.map(NSStringFromSelector).sorted()); PDFKit's recognizers would ask it, and its super may not answer")
    }

    @Test("The double tap's delegate is its own object, not the PDF view")
    func doubleTapHasItsOwnDelegate() throws {
        let (view, window) = makeView()
        let doubleTap = try #require((view.gestureRecognizers ?? []).first { $0.name == FitFlooredPDFView.returnToFitGestureName })
        let delegate = try #require(doubleTap.delegate, "the double tap keeps a delegate (the view holds it)")
        #expect(delegate !== view, "the PDF view is not the double tap's delegate")
        #expect(!(delegate is PDFView), "no PDF view answers for the double tap")
        withExtendedLifetime(window) {}
    }

    @Test("Every recognizer on the canvas whose delegate is asked about a touch answers it")
    func everyRecognizerDelegateAnswersShouldReceive() throws {
        let (view, window) = makeView()
        func recognizers(in v: UIView) -> [UIGestureRecognizer] {
            (v.gestureRecognizers ?? []) + v.subviews.flatMap(recognizers(in:))
        }
        let all = recognizers(in: view)
        try #require(all.contains { $0.name == FitFlooredPDFView.returnToFitGestureName })
        // The same question UIKit asks on touch-down; on iOS 27 the
        // unfixed view crashes here on PDFKit's recognizers.
        for recognizer in all {
            _ = recognizer.delegate?.gestureRecognizer?(recognizer, shouldReceive: StubTouch(location: CGPoint(x: 20, y: 20), view: view))
        }
        withExtendedLifetime(window) {}
    }
}
