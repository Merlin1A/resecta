import Testing
import Foundation
@testable import ResectaApp

// The brief message's rules as pure decisions: a receipt's life, what an
// arrival does to the receipt on screen and to the ones waiting, the clock
// that keeps the time left, and what a layer over a receipt does to it.
// Every expectation is a number or a decision written out here, never read
// from the implementation.

@Suite("Receipt rules")
@MainActor
struct ReceiptRulesTests {

    // MARK: - Life

    struct LifeRow {
        let message: String
        let hasAction: Bool
        let voiceOverRunning: Bool
        let expected: Double
    }

    static let lifeRows: [LifeRow] = [
        LifeRow(message: "Shared.", hasAction: false, voiceOverRunning: false, expected: 2.5),
        LifeRow(message: "Marked 3 for redaction. Not redacted until you tap Redact.",
                hasAction: false, voiceOverRunning: false, expected: 6.0),
        LifeRow(message: "This PDF carries usage restrictions set with an owner password. "
                    + "The redacted copy is built without a password and without those restrictions.",
                hasAction: false, voiceOverRunning: false, expected: 12.0),
        LifeRow(message: "Selection limited to 500 regions", hasAction: false, voiceOverRunning: false, expected: 3.5),
        LifeRow(message: "Deleted 3 regions.", hasAction: true, voiceOverRunning: false, expected: 8.0),
        LifeRow(message: "Shared.", hasAction: false, voiceOverRunning: true, expected: 5.0),
    ]

    @Test("A receipt's life is the longer of 2.5 seconds and one second plus half a second a word, with no upper limit")
    func lifeByWords() {
        #expect(Self.lifeRows.count == 6)
        for row in Self.lifeRows {
            // Words are counted as the queue counts them.
            let words = ToastItem(message: row.message, severity: .info).wordCount
            let life = ReceiptRules.life(
                words: words, hasAction: row.hasAction, voiceOverRunning: row.voiceOverRunning)
            #expect(life == row.expected, "\(row.message)")
        }
        // The owner-password line is the shipped sentence of 22 words.
        #expect(RedactWorkspaceView.encryptedSourceMessage(hadRestrictions: true) == Self.lifeRows[2].message)
        #expect(ToastItem(message: Self.lifeRows[2].message, severity: .warning).wordCount == 22)
        #expect(RedactionState.lassoSelectionCapToastMessage == Self.lifeRows[3].message)
    }

    // MARK: - Arrivals

    enum Expected: Equatable {
        /// What the arrival does to the receipt on screen.
        case arrival(ReceiptArrival)
        /// The events waiting once the arrival is in.
        case waitingAfter([MessageEvent])
        /// Whether a waiting one is shown at its turn.
        case shownAtItsTurn(Bool)
    }

    struct ArrivalRow {
        let name: String
        let shown: ReceiptFacts?
        let onScreenFor: Double
        let waiting: [ReceiptFacts]
        let waitedFor: Double
        let arriving: ReceiptFacts
        let expected: Expected
    }

    static func plain() -> ReceiptFacts { ReceiptFacts(event: MessageEvent(), mustBeSeen: false) }
    static func mustBeSeen() -> ReceiptFacts { ReceiptFacts(event: MessageEvent(), mustBeSeen: true) }

    static func arrivalRows() -> [ArrivalRow] {
        let shownEvent = plain()
        let undo = mustBeSeen()
        let waitingPlain = plain()
        let newer = plain()
        let first = mustBeSeen(), second = mustBeSeen(), third = mustBeSeen()
        let deletedOnce = mustBeSeen(), deletedAgain = mustBeSeen()
        return [
            ArrivalRow(name: "nothing shown, no hold: shown now", shown: nil, onScreenFor: 0, waiting: [],
                       waitedFor: 0, arriving: plain(), expected: .arrival(.showNow)),
            ArrivalRow(name: "the same event: replaced in place", shown: shownEvent, onScreenFor: 2, waiting: [],
                       waitedFor: 0, arriving: shownEvent, expected: .arrival(.replaceInPlace)),
            ArrivalRow(name: "a plain confirmation up 0.4 s: the arrival shows at 1.5 s", shown: plain(),
                       onScreenFor: 0.4, waiting: [], waitedFor: 0, arriving: plain(),
                       expected: .arrival(.replaceAt(1.5))),
            ArrivalRow(name: "an Undo up 3 s: the arrival waits out its 8 s", shown: undo, onScreenFor: 3,
                       waiting: [], waitedFor: 0, arriving: plain(), expected: .arrival(.wait)),
            ArrivalRow(name: "one that must be seen, without an action: the arrival waits its whole life",
                       shown: mustBeSeen(), onScreenFor: 1, waiting: [], waitedFor: 0, arriving: mustBeSeen(),
                       expected: .arrival(.wait)),
            ArrivalRow(name: "a plain one waiting: dropped when anything newer arrives", shown: mustBeSeen(),
                       onScreenFor: 1, waiting: [waitingPlain], waitedFor: 0, arriving: newer,
                       expected: .waitingAfter([newer.event])),
            ArrivalRow(name: "a plain one that waited over 10 s: dropped at its turn", shown: nil, onScreenFor: 0,
                       waiting: [], waitedFor: 10.5, arriving: plain(), expected: .shownAtItsTurn(false)),
            ArrivalRow(name: "two that must be seen waiting and a third: all wait, oldest first", shown: mustBeSeen(),
                       onScreenFor: 1, waiting: [first, second], waitedFor: 0, arriving: third,
                       expected: .waitingAfter([first.event, second.event, third.event])),
            ArrivalRow(name: "two events with the same words: both shown, one after the other", shown: deletedOnce,
                       onScreenFor: 1, waiting: [], waitedFor: 0, arriving: deletedAgain, expected: .arrival(.wait)),
        ]
    }

    @Test("Arrivals by table")
    func arrivalsByTable() {
        let rows = Self.arrivalRows()
        #expect(rows.count == 9)
        for row in rows {
            switch row.expected {
            case .arrival(let want):
                let got = ReceiptRules.arrival(shown: row.shown, onScreenFor: row.onScreenFor, arriving: row.arriving)
                #expect(got == want, "\(row.name)")
            case .waitingAfter(let want):
                let decision = ReceiptRules.arrival(
                    shown: row.shown, onScreenFor: row.onScreenFor, arriving: row.arriving)
                let after = ReceiptRules.waiting(
                    row.waiting, after: row.arriving, arrivalWaits: decision != .showNow)
                #expect(after.map(\.event) == want, "\(row.name)")
            case .shownAtItsTurn(let want):
                #expect(ReceiptRules.showsAtItsTurn(row.arriving, waitedFor: row.waitedFor) == want, "\(row.name)")
            }
        }
        // The edges of the two limits.
        #expect(ReceiptRules.arrival(shown: Self.plain(), onScreenFor: 2, arriving: Self.plain()) == .replaceAt(2))
        #expect(ReceiptRules.showsAtItsTurn(Self.plain(), waitedFor: 10))
        #expect(ReceiptRules.showsAtItsTurn(Self.mustBeSeen(), waitedFor: 60))
        // The same event never waits twice: it takes its own place.
        let waiting = [Self.mustBeSeen(), Self.plain()]
        #expect(ReceiptRules.waiting(waiting, after: waiting[1], arrivalWaits: true).map(\.event)
                == waiting.map(\.event))
    }

    // MARK: - The clock

    @Test("A paused clock keeps the time left")
    func pausedClockKeepsTheTimeLeft() {
        let start = ContinuousClock.now
        func at(_ seconds: Int) -> ContinuousClock.Instant { start.advanced(by: .seconds(seconds)) }
        var clock = ReceiptClock(life: 8)
        #expect(!clock.isRunning)
        #expect(clock.remaining(at: at(30)) == 8, "a clock that has not started has used nothing")
        clock.start(at: start)
        #expect(clock.remaining(at: at(3)) == 5)
        clock.stop(at: at(3))
        #expect(!clock.isRunning)
        #expect(clock.remaining(at: at(40)) == 5, "stopped, it keeps the time left")
        clock.resume(at: at(40))
        #expect(clock.remaining(at: at(41)) == 4)
        #expect(clock.elapsed(at: at(41)) == 4)
        clock.stop(at: at(47))
        #expect(clock.remaining(at: at(50)) == -2)
        clock.keepAtLeast(2.5, at: at(50))
        #expect(clock.remaining(at: at(50)) == 2.5)
        clock.keepAtLeast(1, at: at(50))
        #expect(clock.remaining(at: at(50)) == 2.5, "a life is never shortened")
    }

    // MARK: - Layers

    @Test("A layer over a receipt ends a plain one and pauses one that must be seen")
    func layerOverAReceipt() {
        #expect(ReceiptRules.whenCovered(mustBeSeen: false) == .ends)
        #expect(ReceiptRules.whenCovered(mustBeSeen: true) == .pauses)
        // Drawn again for what is left, and at least 2.5 s.
        #expect(ReceiptRules.remainingOnReturn(5) == 5)
        #expect(ReceiptRules.remainingOnReturn(1) == 2.5)

        let root = MessageLayerFacts(id: UUID(), role: .root)
        var search = MessageLayerFacts(id: UUID(), role: .draws)
        let saved = MessageLayerFacts(id: UUID(), role: .draws)
        let asking = MessageLayerFacts(id: UUID(), role: .holdsOnly)
        // A receipt of Search is drawn by Search, and by the root while Search yields.
        #expect(ReceiptRules.drawingLayer(for: search.id, in: [root, search])?.id == search.id)
        search.yields = true
        #expect(ReceiptRules.drawingLayer(for: search.id, in: [root, search])?.id == root.id)
        #expect(ReceiptRules.isDrawn(belongingTo: search.id, in: [root, search], held: false))
        search.yields = false
        // Covered by the saved list: not drawn; under a layer that only holds: not drawn.
        #expect(!ReceiptRules.isDrawn(belongingTo: search.id, in: [root, search, saved], held: false))
        #expect(!ReceiptRules.isDrawn(belongingTo: search.id, in: [root, search, asking], held: false))
        #expect(!ReceiptRules.isDrawn(belongingTo: search.id, in: [root, search], held: true))
        // With no layer registered the queue is one drawing root.
        #expect(ReceiptRules.isDrawn(belongingTo: nil, in: [], held: false))
        // A message about leaving a layer belongs to the one below the front.
        #expect(ReceiptRules.remainingLayer(in: [root, search]) == root.id)
        #expect(ReceiptRules.remainingLayer(in: [root]) == root.id)
        #expect(ReceiptRules.remainingLayer(in: []) == nil)
    }
}
