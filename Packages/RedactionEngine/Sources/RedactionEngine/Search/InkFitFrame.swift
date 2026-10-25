import CoreGraphics
import Foundation
import PDFKit

/// The frame the ink fit works in: the page's visual frame turned so that the
/// hidden layer's text runs left to right and its lines top to bottom. A page
/// whose picture and layer were turned together (an export that baked a
/// rotation into the page) reads sideways or upside down in the visual
/// frame; read rows, glyph columns and ink rows are all found in this one.
struct InkFitFrame: Sendable, Equatable {
    enum Turn: Int, Sendable {
        /// Text runs left to right.
        case upright
        /// Text runs top to bottom, its lines right to left.
        case down
        /// Text runs bottom to top, its lines left to right.
        case up
        /// Text runs right to left, upside down.
        case flipped
    }

    let turn: Turn
    /// The page's visual size.
    let visual: CGSize

    static func upright(_ visual: CGSize) -> InkFitFrame { InkFitFrame(turn: .upright, visual: visual) }

    /// The page's size in this frame.
    var size: CGSize {
        switch turn {
        case .upright, .flipped: visual
        case .down, .up: CGSize(width: visual.height, height: visual.width)
        }
    }

    /// Visual points to this frame's points.
    var transform: CGAffineTransform {
        switch turn {
        case .upright: .identity
        case .down: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: visual.height, ty: 0)
        case .up: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: visual.width)
        case .flipped: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: visual.width, ty: visual.height)
        }
    }

    func toReading(_ rect: CGRect) -> CGRect { turn == .upright ? rect : rect.applying(transform) }
    func toVisual(_ rect: CGRect) -> CGRect { turn == .upright ? rect : rect.applying(transform.inverted()) }
}

extension DocumentSearcher {
    /// The way the page's hidden layer reads in the visual frame: from the
    /// first and last letters of up to two dozen of its words, the direction
    /// most of them run. Upright when the words do not agree.
    nonisolated static func readingFrame(of page: PDFPage, visual: CGSize) -> InkFitFrame {
        if let known = InkFitFrameCache.shared.value(for: page) { return InkFitFrame(turn: known, visual: visual) }
        let text = (page.string ?? "") as NSString
        let searcher = DocumentSearcher()
        var sum = CGVector(dx: 0, dy: 0), counted = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byWords) { word, range, _, stop in
            guard let word, word.count >= 3, range.length >= 3 else { return }
            guard let first = page.selection(for: NSRange(location: range.location, length: 1))
                    .flatMap({ searcher.normalizedRect(for: $0, page: page) }),
                  let last = page.selection(for: NSRange(location: NSMaxRange(range) - 1, length: 1))
                    .flatMap({ searcher.normalizedRect(for: $0, page: page) }) else { return }
            let dx = (last.midX - first.midX) * visual.width, dy = (last.midY - first.midY) * visual.height
            let length = hypot(dx, dy)
            guard length > 0 else { return }
            sum.dx += dx / length; sum.dy += dy / length
            counted += 1
            if counted >= 24 { stop.pointee = true }
        }
        let turn: InkFitFrame.Turn
        if counted == 0 || hypot(sum.dx, sum.dy) < 0.5 * CGFloat(counted) {
            turn = .upright
        } else if abs(sum.dx) >= abs(sum.dy) {
            turn = sum.dx > 0 ? .upright : .flipped
        } else {
            turn = sum.dy < 0 ? .down : .up
        }
        InkFitFrameCache.shared.set(turn, for: page)
        return InkFitFrame(turn: turn, visual: visual)
    }
}

/// Per-page answers of `readingFrame`, held weakly by page.
final class InkFitFrameCache: @unchecked Sendable {
    static let shared = InkFitFrameCache()
    private let lock = NSLock()
    private let table = NSMapTable<PDFPage, NSNumber>.weakToStrongObjects()

    func value(for page: PDFPage) -> InkFitFrame.Turn? {
        lock.lock(); defer { lock.unlock() }
        return table.object(forKey: page).flatMap { InkFitFrame.Turn(rawValue: $0.intValue) }
    }

    func set(_ turn: InkFitFrame.Turn, for page: PDFPage) {
        lock.lock(); defer { lock.unlock() }
        table.setObject(NSNumber(value: turn.rawValue), forKey: page)
    }
}
