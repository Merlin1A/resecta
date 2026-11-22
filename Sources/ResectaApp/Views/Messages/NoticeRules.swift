import Foundation
import CoreGraphics

// The pure rules of the editor's notice band: when a notice lies over a
// page, how it folds to its mark and opens again, how long it stays open
// before it folds, and when the folded mark is drawn. Nothing here reads
// a view, the message queue or the document; the band's view feeds these
// rules what it measures and draws what they answer.

/// A rectangle on the canvas in whole points. Made from a measured
/// rectangle by rounding outward (the minimums down, the maximums up), so
/// rounding can only make a notice meet a page, never leave it open over
/// one.
nonisolated struct CanvasRect: Equatable, Sendable {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int
}

extension CanvasRect {
    /// The largest coordinate magnitude a measured rectangle may have. A
    /// canvas is a few thousand points across; past this the value is not
    /// a frame on screen, and its whole-point form could overflow `Int`.
    nonisolated static let coordinateLimit: CGFloat = 1_000_000

    /// The rectangle rounded outward; nil for the null rectangle, an
    /// infinite one, or one with a coordinate that is not finite or lies
    /// past `coordinateLimit`.
    nonisolated init?(outward rect: CGRect) {
        guard !rect.isNull, !rect.isInfinite else { return nil }
        let edges = [rect.minX, rect.minY, rect.maxX, rect.maxY]
        guard edges.allSatisfy({ $0.isFinite && abs($0) <= Self.coordinateLimit }) else { return nil }
        self.init(minX: Int(rect.minX.rounded(.down)), minY: Int(rect.minY.rounded(.down)),
                  maxX: Int(rect.maxX.rounded(.up)), maxY: Int(rect.maxY.rounded(.up)))
    }
}

/// How an open notice in the band is drawn: whole, and either on a clock
/// (`timed`, it folds when its reading time is over) or not; or folded to
/// its mark. A fold is how the notice is drawn, not whether it holds:
/// folding ends nothing.
nonisolated enum BandFold: Equatable, Sendable {
    case open(timed: Bool)
    case folded
}

/// What happens to a band notice: it arrives (it becomes the shown
/// occupant, or the band shows again), its reading time runs out, the page
/// under the band moves (a zoom, a scroll, a page change), or the person
/// taps its folded mark.
nonisolated enum BandEvent: Equatable, Sendable {
    case arrived
    case readingTimeElapsed
    case pageMoved
    case tapped
}

nonisolated enum NoticeRules {

    // MARK: - Meeting a page

    /// Whether two rectangles share a point inside both. Touching edges do
    /// not meet.
    static func meets(_ a: CanvasRect, _ b: CanvasRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    /// Whether the notice meets any of the visible pages.
    static func meetsAnyPage(_ notice: CanvasRect, pages: [CanvasRect]) -> Bool {
        pages.contains { meets(notice, $0) }
    }

    // MARK: - The fold

    /// The band's fold after an event. `meets` is whether the notice's
    /// rectangle meets a visible page at that moment.
    /// - arrived: open, on a clock only when it meets a page;
    /// - the reading time over: folded, if it was on a clock and meets a page;
    /// - the page moved: folded, if it meets a page;
    /// - a tap on the folded mark: open, with no clock.
    /// Every other pair leaves the fold as it was.
    static func next(_ fold: BandFold, _ event: BandEvent, meets: Bool) -> BandFold {
        switch event {
        case .arrived:
            return .open(timed: meets)
        case .readingTimeElapsed:
            return fold == .open(timed: true) && meets ? .folded : fold
        case .pageMoved:
            return meets ? .folded : fold
        case .tapped:
            return fold == .folded ? .open(timed: false) : fold
        }
    }

    /// Whether the band runs the reading-time clock: only for a notice
    /// open on a clock, and never while VoiceOver is running (a VoiceOver
    /// user's notice folds when the page moves under it, not by time).
    static func readingClockRuns(fold: BandFold, voiceOverRunning: Bool) -> Bool {
        fold == .open(timed: true) && !voiceOverRunning
    }

    /// The event a publish of the canvas's page frames stands for. The
    /// canvas publishes frames only while the band has a notice, so the
    /// first frames after that start are the notice's arrival, measured;
    /// every later change is the page moving.
    static func frameEvent(firstSinceWanted: Bool) -> BandEvent {
        firstSinceWanted ? .arrived : .pageMoved
    }

    /// The folded mark is drawn only while the notice is folded and no
    /// drawing tool is on. With a tool on, the notice is neither open nor
    /// marked; turning the tool off brings the mark back.
    static func foldedMarkIsShown(fold: BandFold, toolOn: Bool) -> Bool {
        fold == .folded && !toolOn
    }

    // MARK: - Reading time

    /// The shortest reading time, in seconds.
    static let readingTimeFloor: TimeInterval = 2.5
    /// The reading time before the first word, in seconds.
    static let readingTimeBase: TimeInterval = 1
    /// The reading time each word adds, in seconds.
    static let readingTimePerWord: TimeInterval = 0.5
    /// The shortest reading time of a notice with an action, in seconds.
    static let readingTimeWithAction: TimeInterval = 8

    /// How long an open notice that meets a page stays whole before it
    /// folds: one second and half a second a word, at least 2.5 seconds,
    /// and at least 8 when the notice has an action.
    static func readingTime(words: Int, hasAction: Bool) -> TimeInterval {
        let byWords = max(readingTimeFloor, readingTimeBase + readingTimePerWord * Double(max(0, words)))
        return hasAction ? max(readingTimeWithAction, byWords) : byWords
    }

    /// The words of a notice's text: the runs between spaces and line breaks.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
