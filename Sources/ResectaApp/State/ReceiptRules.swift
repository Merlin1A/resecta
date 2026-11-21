import Foundation

// The brief message's rules, as pure decisions over plain values: how long a
// receipt lives, what an arrival does to the receipt on screen and to the
// ones waiting, what a layer over a receipt does to it, and which layer
// draws it. `ToastQueueManager` holds the state and the timer and asks these
// functions; the tests read them directly, with explicit instants.

/// What the arrival rules read of a message: the event it reports, and
/// whether it must be seen (it reports a loss or carries an action).
struct ReceiptFacts: Equatable {
    let event: MessageEvent
    let mustBeSeen: Bool
}

/// What an arrival does to the receipt on screen.
enum ReceiptArrival: Equatable {
    /// Nothing is on screen: the arrival is shown now.
    case showNow
    /// The same event: the shown receipt takes the arrival's content, and
    /// its clock starts again.
    case replaceInPlace
    /// The shown receipt is a plain one: it ends once it has been on screen
    /// this many seconds, and the next one is shown in its place.
    case replaceAt(Double)
    /// The shown receipt keeps its whole life; the arrival waits.
    case wait
}

/// What a layer registered over a receipt's layer does to that receipt.
enum ReceiptCover: Equatable {
    /// A plain receipt ends.
    case ends
    /// One that must be seen stops its clock and is drawn again when its own
    /// layer is in front, for what is left of its life.
    case pauses
}

/// One registered layer, as the layer rules read it.
struct MessageLayerFacts: Equatable {
    let id: UUID
    let role: MessageLayerRole
    var yields = false
    var surfaceVisible = true
}

enum ReceiptRules {

    // MARK: - Named limits (seconds)

    /// The shortest life of any receipt.
    static let shortestLife: Double = 2.5
    /// A receipt's life is this, plus `lifePerWord` for each word.
    static let baseLife: Double = 1
    static let lifePerWord: Double = 0.5
    /// The shortest life while VoiceOver is running when it is shown.
    static let voiceOverLife: Double = 5
    /// The shortest life of a receipt with an action: the time to notice
    /// the button, reach for it and tap it.
    static let actionLife: Double = 8
    /// A plain receipt on screen gets this long before a different message
    /// replaces it.
    static let plainMinimumOnScreen: Double = 1.5
    /// A plain receipt that has waited longer than this (hidden time
    /// counts) is dropped at its turn.
    static let plainWaitLimit: Double = 10
    /// The gap between one receipt leaving and the next being shown.
    static let gapBetweenReceipts: Double = 0.3
    /// A receipt drawn again after its layer was covered or its surface
    /// hidden has at least this long left.
    static let shortestReturn: Double = 2.5
    /// An announcement that never reports its end gives way to the next
    /// after this long.
    static let announcementFallback: Double = 3

    // MARK: - Life

    /// The longer of 2.5 seconds and one second plus half a second a word;
    /// at least 5 with VoiceOver running; at least 8 with an action. There
    /// is no upper limit.
    static func life(words: Int, hasAction: Bool, voiceOverRunning: Bool) -> Double {
        var life = max(shortestLife, baseLife + lifePerWord * Double(words))
        if voiceOverRunning { life = max(life, voiceOverLife) }
        if hasAction { life = max(life, actionLife) }
        return life
    }

    // MARK: - Arrivals

    /// What an arriving message does to the receipt on screen, `onScreenFor`
    /// seconds after it was first drawn. Identity is the event: the same
    /// event replaces in place; a plain receipt gives way once it has had
    /// its minimum; one that must be seen keeps its whole life.
    static func arrival(shown: ReceiptFacts?, onScreenFor: Double, arriving: ReceiptFacts) -> ReceiptArrival {
        guard let shown else { return .showNow }
        if shown.event == arriving.event { return .replaceInPlace }
        if shown.mustBeSeen { return .wait }
        return .replaceAt(max(plainMinimumOnScreen, onScreenFor))
    }

    /// Whether a waiting message gives way to any newer brief message: a
    /// plain one does; one that must be seen is never dropped, only delayed.
    static func givesWayToANewerMessage(_ waiting: ReceiptFacts) -> Bool {
        !waiting.mustBeSeen
    }

    /// The waiting list after a message arrives: the same event takes its
    /// own place (it never waits twice); otherwise a waiting plain message
    /// is dropped, every one that must be seen stays, oldest first, and the
    /// arrival joins the end when it waits.
    static func waiting(_ waiting: [ReceiptFacts], after arriving: ReceiptFacts, arrivalWaits: Bool) -> [ReceiptFacts] {
        if let index = waiting.firstIndex(where: { $0.event == arriving.event }) {
            var kept = waiting
            kept[index] = arriving
            return kept
        }
        var kept = waiting.filter { !givesWayToANewerMessage($0) }
        if arrivalWaits { kept.append(arriving) }
        return kept
    }

    /// Whether a waiting message is shown when its turn comes, after
    /// `waitedFor` seconds: a plain one that has waited over the limit is
    /// dropped instead.
    static func showsAtItsTurn(_ waiting: ReceiptFacts, waitedFor: Double) -> Bool {
        waiting.mustBeSeen || waitedFor <= plainWaitLimit
    }

    // MARK: - Layers

    /// What a layer registered over a receipt's layer does to the receipt.
    static func whenCovered(mustBeSeen: Bool) -> ReceiptCover {
        mustBeSeen ? .pauses : .ends
    }

    /// What is left of a receipt's life when it is drawn again after its
    /// layer was covered or its surface hidden.
    static func remainingOnReturn(_ remaining: Double) -> Double {
        max(remaining, shortestReturn)
    }

    /// The layer that draws a receipt belonging to `layer`: the layer
    /// itself, or, while it yields, the nearest layer below it that does not.
    /// Nil when it and every layer below it yield, or it is not registered.
    static func drawingLayer(for layer: UUID, in stack: [MessageLayerFacts]) -> MessageLayerFacts? {
        guard let index = stack.firstIndex(where: { $0.id == layer }) else { return nil }
        return stack[...index].last { !$0.yields }
    }

    /// The layer a message about leaving a layer belongs to from its post:
    /// the one just below the front, or the front when it is the only one.
    /// Nil with no layer registered.
    static func remainingLayer(in stack: [MessageLayerFacts]) -> UUID? {
        stack.count >= 2 ? stack[stack.count - 2].id : stack.last?.id
    }

    /// The layer a message belongs to from its post. A message raised by a
    /// run belongs to the layer that ran it, named at the post, while that
    /// layer is registered: a sheet opened over it, or leaving, does not
    /// take the message. Else a message about leaving a layer belongs to the
    /// remaining layer; else to none yet (it takes the front when shown).
    static func layerAtPost(named runLayer: UUID?, showsInRemainingLayer: Bool,
                            in stack: [MessageLayerFacts]) -> UUID? {
        if let runLayer, stack.contains(where: { $0.id == runLayer }) { return runLayer }
        return showsInRemainingLayer ? remainingLayer(in: stack) : nil
    }

    /// Whether a receipt belonging to `layer` is drawn, or a waiting one may
    /// be shown (a waiting one that belongs to no layer yet takes the front):
    /// only while no hold is set, its layer is in front and draws, and the
    /// drawing layer's surface is visible. With no layer registered the
    /// queue behaves as one drawing root.
    static func isDrawn(belongingTo layer: UUID?, in stack: [MessageLayerFacts], held: Bool) -> Bool {
        if held { return false }
        guard let front = stack.last else { return true }
        guard front.role != .holdsOnly else { return false }
        if let layer, layer != front.id { return false }
        return drawingLayer(for: front.id, in: stack)?.surfaceVisible ?? false
    }
}

/// One receipt's clock: it runs only while the receipt is drawn and nothing
/// holds it. Every reading takes its instant, so a test can read it at
/// instants of its own.
struct ReceiptClock: Equatable {
    /// The receipt's whole life, in seconds.
    private(set) var life: Double
    /// Seconds run before the current run.
    private(set) var ran: Double = 0
    /// When the current run started; nil while the clock is stopped.
    private(set) var since: ContinuousClock.Instant?

    init(life: Double) {
        self.life = life
    }

    var isRunning: Bool { since != nil }

    /// Starts a clock that has not run, or resumes a stopped one.
    mutating func start(at now: ContinuousClock.Instant) {
        guard since == nil else { return }
        since = now
    }

    mutating func resume(at now: ContinuousClock.Instant) {
        start(at: now)
    }

    mutating func stop(at now: ContinuousClock.Instant) {
        guard let since else { return }
        ran += Self.seconds(since.duration(to: now))
        self.since = nil
    }

    /// Seconds the receipt has been on screen with its clock running.
    func elapsed(at now: ContinuousClock.Instant) -> Double {
        ran + (since.map { Self.seconds($0.duration(to: now)) } ?? 0)
    }

    /// What is left of its life.
    func remaining(at now: ContinuousClock.Instant) -> Double {
        life - elapsed(at: now)
    }

    /// Lengthens the life so that at least `seconds` are left.
    mutating func keepAtLeast(_ seconds: Double, at now: ContinuousClock.Instant) {
        let left = remaining(at: now)
        if left < seconds { life += seconds - left }
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
