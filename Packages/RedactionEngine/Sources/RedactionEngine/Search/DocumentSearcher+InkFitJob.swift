import CoreGraphics
import Foundation
import PDFKit

// One ink fit's inputs (`DocumentSearcher+InkFit.swift`).

extension DocumentSearcher {
    /// One fit, with everything it reads taken from the page up front (the
    /// fit runs on any thread; `PDFPage` stays on its caller's).
    struct InkFitJob: @unchecked Sendable {
        let rect: CGRect
        let cgPage: CGPDFPage
        let rotation: Int
        let visual: CGSize
        let pageKey: Int
        let pageText: String
        let text: String?
        let range: NSRange?
        let paintOnly: Bool
        /// The page's reading frame (`readingFrame`).
        let frame: InkFitFrame
        /// Wide (CJK) characters on the match's line up to its end, and the
        /// points from the line's start to the match's end in the reading
        /// frame (`driftBound`).
        var wideBefore: Int = 0
        var fromLineStart: CGFloat = 0
        /// A layer character's box in the reading frame, by its index in the
        /// page text (read on the caller's thread, from its page).
        var layerBox: (Int) -> CGRect? = { _ in nil }
        /// Set by a fit that fell back on a timeout: its box is not cached.
        let uncached = Flag()
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var set = false
            func raise() { lock.lock(); set = true; lock.unlock() }
            var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return set }
        }
        func markUncached() { uncached.raise() }

        var key: Int {
            var hasher = Hasher()
            hasher.combine(pageKey)
            hasher.combine(rect.minX); hasher.combine(rect.minY); hasher.combine(rect.width); hasher.combine(rect.height)
            hasher.combine(text)
            hasher.combine(range?.location); hasher.combine(range?.length)
            hasher.combine(paintOnly)
            return hasher.finalize()
        }

        /// The selection box grown by the drift bound in the reading frame (a
        /// line height above and below its line, `inkFitDriftBound` along it),
        /// clamped to the page.
        func envelope() -> CGRect {
            markUncached()
            let box = CGRect(x: rect.minX * visual.width, y: rect.minY * visual.height,
                             width: rect.width * visual.width, height: rect.height * visual.height)
            let grown = frame.toVisual(DocumentSearcher.driftBound(around: frame.toReading(box), wideBefore: wideBefore,
                                                                   fromLineStart: fromLineStart)
                .intersection(CGRect(origin: .zero, size: frame.size)))
            return CGRect(x: grown.minX / visual.width, y: grown.minY / visual.height,
                          width: grown.width / visual.width, height: grown.height / visual.height).clampedToNormalized()
        }

        func with(_ page: CGPDFPage) -> InkFitJob {
            InkFitJob(rect: rect, cgPage: page, rotation: rotation, visual: visual, pageKey: pageKey,
                      pageText: pageText, text: text, range: range, paintOnly: paintOnly, frame: frame,
                      wideBefore: wideBefore, fromLineStart: fromLineStart, layerBox: layerBox)
        }

        func run() -> CGRect {
            DocumentSearcher.fit(self)
        }
    }
}
