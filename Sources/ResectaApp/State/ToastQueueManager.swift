import SwiftUI
import UIKit

// The brief messages' queue: one receipt at a time, each the message of one
// event, with a life on a clock that runs only while it is drawn. Injected
// via .environment(toastManager) at the ContentView level. Its rules are
// pure decisions in `ReceiptRules`; this type holds the state and the timer.

// MARK: - Severity Enum

enum ToastSeverity: Equatable {
    case info
    case success
    case warning
    case error
}

/// The event a brief message reports. Two posts are the same message only
/// when they carry the same event.
struct MessageEvent: Hashable {
    let id = UUID()
}

/// A layer's part in the brief messages: the app's root, a sheet that draws
/// its own receipts, or one that only holds them (an asking sheet, a system
/// page) while it is up.
enum MessageLayerRole: Equatable {
    case root, draws, holdsOnly
}

/// What stops one shown receipt's clock: a finger on it, or VoiceOver's focus.
enum ClockStop: Hashable {
    case touch, voiceOverFocus
}

// MARK: - ToastItem

struct ToastItem: Identifiable, Equatable {
    let id: UUID
    let message: String
    let severity: ToastSeverity
    let wordCount: Int
    /// Optional action button on the toast — used
    /// for undo affordances. `actionLabel` is the user-visible button
    /// text; `actionHandler` is a @MainActor closure
    /// invoked when the user taps the button. The closure captures
    /// snapshot state at enqueue time; it expires when the toast dismisses.
    let actionLabel: String?
    let actionHandler: (@MainActor () -> Void)?
    /// The message's voice: its row's, or for an item built directly its
    /// severity's.
    let tone: MessageTone
    /// The event the message reports; equality is by it.
    let event: MessageEvent
    /// The row the message was posted by; nil for an item built directly.
    let messageID: MessageID?
    /// It reports a loss or carries an action: never dropped, only delayed.
    let mustBeSeen: Bool
    /// The producer's guard: false once the action no longer means what it
    /// offered. The queue ends the message then.
    let stillValid: (@MainActor () -> Bool)?
    /// The document phases the message is true in.
    let phases: Set<DocumentState.PhaseKind>
    /// Whether its action changes state.
    let actionChangesState: Bool
    // Icon is derived from severity — no optional icon field

    /// An item built directly, with no row: a new event, its tone from its
    /// severity, true in every phase, and to be seen exactly when it has an
    /// action.
    init(
        message: String,
        severity: ToastSeverity,
        actionLabel: String? = nil,
        actionHandler: (@MainActor () -> Void)? = nil
    ) {
        self.init(
            id: UUID(), message: message, severity: severity,
            actionLabel: actionLabel, actionHandler: actionHandler,
            tone: Self.tone(for: severity), event: MessageEvent(), messageID: nil,
            mustBeSeen: actionHandler != nil, stillValid: nil,
            phases: MessageCatalog.allPhases, actionChangesState: actionHandler != nil)
    }

    fileprivate init(
        id: UUID, message: String, severity: ToastSeverity,
        actionLabel: String?, actionHandler: (@MainActor () -> Void)?,
        tone: MessageTone, event: MessageEvent, messageID: MessageID?,
        mustBeSeen: Bool, stillValid: (@MainActor () -> Bool)?,
        phases: Set<DocumentState.PhaseKind>, actionChangesState: Bool
    ) {
        self.id = id
        self.message = message
        self.severity = severity
        self.wordCount = message.split(separator: " ").count
        self.actionLabel = actionLabel
        self.actionHandler = actionHandler
        self.tone = tone
        self.event = event
        self.messageID = messageID
        self.mustBeSeen = mustBeSeen
        self.stillValid = stillValid
        self.phases = phases
        self.actionChangesState = actionChangesState
    }

    /// The tone of an item built directly.
    static func tone(for severity: ToastSeverity) -> MessageTone {
        switch severity {
        case .success: .done
        case .info: .note
        case .warning: .caution
        case .error: .stop
        }
    }

    /// This item with another's content and its own id, so a view and a
    /// hold that name it keep naming it.
    fileprivate func taking(_ other: ToastItem) -> ToastItem {
        ToastItem(
            id: id, message: other.message, severity: other.severity,
            actionLabel: other.actionLabel, actionHandler: other.actionHandler,
            tone: other.tone, event: other.event, messageID: other.messageID,
            mustBeSeen: other.mustBeSeen, stillValid: other.stillValid,
            phases: other.phases, actionChangesState: other.actionChangesState)
    }

    var facts: ReceiptFacts { ReceiptFacts(event: event, mustBeSeen: mustBeSeen) }

    /// Equality is by event: closures are not comparable, and two messages
    /// with the same words are two messages when they report two events.
    static func == (lhs: ToastItem, rhs: ToastItem) -> Bool {
        lhs.event == rhs.event
    }
}

// MARK: - ToastQueueManager

/// The brief messages' lifecycle: one receipt shown at a time and the rest
/// waiting in one list; identity by event; life by words on a clock that
/// stops while the receipt is not drawn or is held; layers, holds and
/// phases that end, pause or delay it; announcements spoken one after
/// another.
@Observable @MainActor
final class ToastQueueManager {
    /// The current receipt, shown or paused in place: at most one.
    private(set) var activeToasts: [ToastItem] = []

    /// Stable version counter for animation tracking. Cheaper than hashing
    /// activeToasts.map(\.id) on every render cycle.
    private(set) var toastVersion: Int = 0

    /// Extra bottom inset the bottom toast hosts apply so a toast clears
    /// the bottom chrome — the page bar while it is up and uncovered,
    /// and a Search/Scan sheet parked at the compact float (the sheet's
    /// own host yields there; the app-level copy, no longer covered,
    /// would otherwise sit beneath the strip). The value is the
    /// bottom-chrome model's (`ParkedChromeLayout.toastClearance`),
    /// written by the editor's page-bar inset as the bar comes and goes
    /// and by the sheet on its detent changes and disappearance.
    var bottomClearance: CGFloat = 0

    /// The page bar's measured layout height, written by the editor where
    /// the bar mounts and read by both places that build the bottom-chrome
    /// model (the editor and the Search sheet), so the lift follows the
    /// bar when its counter stacks at the larger text sizes. 0 until the
    /// bar is first measured; the model never lifts by less than the
    /// one-line bar's height.
    var pageBarHeight: CGFloat = 0


    /// The document phase last pushed; nil until one is (and at Home).
    private(set) var documentPhase: DocumentState.PhaseKind?

    // MARK: - State

    private struct Entry: Equatable {
        var item: ToastItem
        let postedAt: ContinuousClock.Instant
        /// The layer it belongs to: the one named at its post (a run's sheet,
        /// or the remaining layer for a message about leaving one), else nil
        /// until it is shown in the front layer; nil again when its layer
        /// leaves before it was shown. Nil while no layer is registered.
        var layer: UUID?
        /// Nil until it is first shown.
        var clock: ReceiptClock?
        var clockStops: Set<ClockStop> = []
        var awaitingFocus = false
        var focusedOnce = false
        /// Its layer was covered or its surface hidden since it was drawn.
        var returning = false
        /// A plain one's point of replacement, in seconds on screen.
        var endsWhenOnScreen: Double?
        var atSlotSince: ContinuousClock.Instant?
    }

    private var current: Entry?
    private var waiting: [Entry] = []
    private var layers: [MessageLayerFacts] = []
    private var holds: Set<UUID> = []
    private var gapEndsAt: ContinuousClock.Instant?
    @ObservationIgnored private var whenGoneActions: [(name: MessageID.Name, perform: @MainActor () -> Void)] = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var announcementLines: [String] = []
    @ObservationIgnored private var speaking: (line: String, since: ContinuousClock.Instant)?
    @ObservationIgnored private var announcementObserver: (any NSObjectProtocol)?

    /// The clock, the assistive-technology checks and the announcement
    /// poster, injectable for tests.
    @ObservationIgnored var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    @ObservationIgnored var voiceOverRunning: @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning }
    @ObservationIgnored var switchControlRunning: @MainActor () -> Bool = { UIAccessibility.isSwitchControlRunning }
    @ObservationIgnored var postAnnouncement: @MainActor (String) -> Void = {
        AccessibilityNotification.Announcement($0).post()
    }

    private var entries: [Entry] { (current.map { [$0] } ?? []) + waiting }

    /// The messages waiting, in order (a paused one among them).
    var waitingToasts: [ToastItem] { waiting.map(\.item) }

    /// The clock of a shown, paused or waiting receipt; nil before it is
    /// first shown.
    func receiptClock(of item: ToastItem.ID) -> ReceiptClock? {
        entries.first { $0.item.id == item }?.clock
    }

    var registeredLayerCount: Int { layers.count }

    // MARK: - Life

    /// The receipt's life, from its words, its action and VoiceOver.
    func displayDuration(for item: ToastItem) -> Double {
        ReceiptRules.life(
            words: item.wordCount, hasAction: item.actionHandler != nil, voiceOverRunning: voiceOverRunning())
    }

    // MARK: - Posting

    /// Add a message built directly. It is a new event each time.
    func enqueue(_ item: ToastItem) {
        admit(item, layer: nil)
    }

    /// Post a message by its row: the row's text, today's severity, and the
    /// row's action label with `action`. A row without a label takes no
    /// action. `action` runs from MainActor when the user taps the button;
    /// the toast is dismissed after it runs. With `stillValid`, a tap runs
    /// the action only while it holds, and `revalidate()` ends the message
    /// once it does not. No `event` means a new one, except for a row that
    /// coalesces repeats: the same row with the same words already shown,
    /// paused or waiting is that message, and nothing restarts. With
    /// `runLayer`, the layer whose run raised the message, the message
    /// belongs to that layer while it is registered (`layerAtPost`).
    @discardableResult
    func post(_ id: MessageID, event: MessageEvent? = nil, runLayer: UUID? = nil,
              action: (@MainActor () -> Void)? = nil,
              stillValid: (@MainActor () -> Bool)? = nil) -> MessageEvent {
        let row = MessageCatalog.row(for: id)
        // A notice drawn in its own place has no severity and is never
        // posted: a post of one shows nothing (and stops a debug build).
        guard let severity = row.todaySeverity else {
            assertionFailure("\(id.name.rawValue) is drawn in its place and is never posted")
            return event ?? MessageEvent()
        }
        if event == nil, row.coalescesRepeats,
           let same = entries.first(where: { $0.item.messageID?.name == id.name && $0.item.message == row.text }) {
            return same.item.event
        }
        var handler = row.actionLabel == nil ? nil : action
        if let given = handler, let stillValid {
            handler = { if stillValid() { given() } }
        }
        let item = ToastItem(
            id: UUID(), message: row.text, severity: severity,
            actionLabel: handler == nil ? nil : row.actionLabel, actionHandler: handler,
            tone: row.tone, event: event ?? MessageEvent(), messageID: id,
            mustBeSeen: row.mustBeSeen, stillValid: stillValid,
            phases: row.phases, actionChangesState: row.actionChangesState)
        admit(item, layer: ReceiptRules.layerAtPost(
            named: runLayer, showsInRemainingLayer: row.showsInRemainingLayer, in: layers))
        return item.event
    }

    private func admit(_ item: ToastItem, layer: UUID?) {
        let at = now()
        if var shown = current, shown.item.event == item.event {
            shown.item = shown.item.taking(item)
            shown.clock = ReceiptClock(life: displayDuration(for: shown.item))
            if shown.endsWhenOnScreen != nil { shown.endsWhenOnScreen = ReceiptRules.plainMinimumOnScreen }
            current = shown
            setShown(shown.item)
            announce(item.message)
            reconcile()
            return
        }
        if let index = waiting.firstIndex(where: { $0.item.event == item.event }) {
            waiting[index].item = waiting[index].item.taking(item)
            reconcile()
            return
        }
        let kept = Set(ReceiptRules.waiting(
            waiting.map(\.item.facts), after: item.facts, arrivalWaits: false).map(\.event))
        waiting.removeAll { !kept.contains($0.item.event) }
        let entry = Entry(item: item, postedAt: at, layer: layer)
        waiting.append(entry)
        if var shown = current, layer == nil || layer == layers.last?.id {
            let decision = ReceiptRules.arrival(
                shown: shown.item.facts, onScreenFor: shown.clock?.elapsed(at: at) ?? 0, arriving: item.facts)
            if case .replaceAt(let point) = decision {
                shown.endsWhenOnScreen = min(shown.endsWhenOnScreen ?? point, point)
                current = shown
            }
        }
        reconcile()
    }

    // MARK: - Ends

    /// Dismiss a specific toast; the next is shown after the gap.
    func dismiss(_ item: ToastItem) {
        if current?.item.id == item.id {
            endCurrent()
        } else {
            waiting.removeAll { $0.item.id == item.id }
        }
        reconcile()
    }

    /// Withdraw every toast that carries an action, shown or queued. The
    /// start of a full run calls it: an action offered before the run (an
    /// Undo, a Mark, a Re-run) no longer means what it offered once the
    /// run owns the document. A toast without an action stays.
    func dropActionToasts() {
        waiting.removeAll { $0.item.actionHandler != nil }
        if current?.item.actionHandler != nil { endCurrent() }
        reconcile()
    }

    /// Clear all active and queued toasts. Called on document close to prevent
    /// stale context toasts from displaying after a new document opens.
    func clearAll() {
        timer?.cancel()
        timer = nil
        gapEndsAt = nil
        waiting.removeAll()
        current = nil
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        withAnimation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.toastOut, reduceMotion: reduceMotion)) {
            activeToasts.removeAll()
        }
        reconcile()
    }

    /// Ends the current receipt. After a replacement the next is shown at
    /// once; after any other end, after the gap.
    private func endCurrent(replaced: Bool = false) {
        guard current != nil else { return }
        current = nil
        // Route through `Anim.resolved` so Reduce Motion swaps the
        // toast-out easing to the opacity-only fallback. The queue
        // manager is a non-View service, so we read
        // `UIAccessibility.isReduceMotionEnabled` directly — same posture
        // RedactionOverlayView's CADisplayLink-driven handle animation uses
        // for its Reduce-Motion gate.
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        withAnimation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.toastOut, reduceMotion: reduceMotion)) {
            activeToasts.removeAll()
        }
        toastVersion &+= 1
        gapEndsAt = replaced ? nil : now().advanced(by: .seconds(ReceiptRules.gapBetweenReceipts))
    }

    private func endEntries(where shouldEnd: (Entry) -> Bool) {
        waiting.removeAll(where: shouldEnd)
        if let shown = current, shouldEnd(shown) { endCurrent() }
    }

    // MARK: - Phases and guards

    /// The document's phase changed. Leaving editing withdraws every message
    /// whose action changes state; every message whose row's phases leave
    /// out the new phase ends; then every guard is asked again. A post in a
    /// phase its row leaves out stays until the next change. Nil (no
    /// document) is stored and ends nothing by phase.
    func documentPhaseDidChange(to phase: DocumentState.PhaseKind?) {
        guard phase != documentPhase else { return }
        documentPhase = phase
        if let phase {
            endEntries { entry in
                (phase != .editing && entry.item.actionChangesState) || !entry.item.phases.contains(phase)
            }
        }
        revalidate()
    }

    /// Ends every message whose producer's guard no longer holds.
    func revalidate() {
        endEntries { $0.item.stillValid?() == false }
        reconcile()
    }

    // MARK: - Holds

    /// While a system dialog or system sheet is up nothing new is shown and
    /// the shown receipt is not drawn and its clock stops; waiting ones age.
    func setHold(_ hold: UUID, _ on: Bool) {
        if on { holds.insert(hold) } else { holds.remove(hold) }
        reconcile()
    }

    /// A finger on the receipt, or VoiceOver's focus on it, stops its clock.
    func holdClock(_ item: ToastItem.ID, _ reason: ClockStop, _ on: Bool) {
        update(item) { entry in
            if on { entry.clockStops.insert(reason) } else { entry.clockStops.remove(reason) }
        }
    }

    /// The receipt has had VoiceOver's or Switch Control's focus once: from
    /// now on it leaves on its clock.
    func noteFocused(_ item: ToastItem.ID) {
        update(item) { entry in
            entry.focusedOnce = true
            entry.awaitingFocus = false
        }
    }

    private func update(_ item: ToastItem.ID, _ change: (inout Entry) -> Void) {
        if var shown = current, shown.item.id == item {
            change(&shown)
            current = shown
        } else if let index = waiting.firstIndex(where: { $0.item.id == item }) {
            change(&waiting[index])
        }
        reconcile()
    }

    // MARK: - Layers

    /// The layer registered last is in front. A receipt belongs to the
    /// layer named at its post, else to the layer in front when it is
    /// shown, and moves only when that layer leaves before it was shown; a
    /// layer registered over it ends a plain one and pauses one that must
    /// be seen.
    /// A layer that only holds draws nothing: receipts wait under it.
    func registerLayer(_ layer: UUID, role: MessageLayerRole) {
        guard !layers.contains(where: { $0.id == layer }) else { return }
        let wasEmpty = layers.isEmpty
        layers.append(MessageLayerFacts(id: layer, role: role))
        if var shown = current, role != .holdsOnly {
            if wasEmpty {
                shown.layer = layer
                current = shown
            } else if shown.layer != layer {
                switch ReceiptRules.whenCovered(mustBeSeen: shown.item.mustBeSeen) {
                case .ends:
                    endCurrent()
                case .pauses:
                    shown.clock?.stop(at: now())
                    shown.returning = true
                    shown.endsWhenOnScreen = nil
                    endCurrent()
                    waiting.insert(shown, at: 0)
                }
            }
        }
        reconcile()
    }

    /// The layer is gone: its receipts end, shown, paused or waiting, except
    /// one that must be seen and was never shown, which is handed on and
    /// takes the front when shown.
    func unregisterLayer(_ layer: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == layer }) else { return }
        layers.remove(at: index)
        endEntries { entry in
            entry.layer == layer && !ReceiptRules.handedOnWhenItsLayerLeaves(
                mustBeSeen: entry.item.mustBeSeen, everShown: entry.clock != nil)
        }
        // What is left of that layer's messages is handed on.
        for index in waiting.indices where waiting[index].layer == layer { waiting[index].layer = nil }
        reconcile()
    }

    /// While a layer yields (Search parked), its receipt is drawn by the
    /// nearest layer below it that does not; the time left is kept.
    func setLayerYields(_ layer: UUID, _ yields: Bool) {
        guard let index = layers.firstIndex(where: { $0.id == layer }) else { return }
        layers[index].yields = yields
        reconcile()
    }

    /// A layer's surface is hidden (a capture cover over its content) or
    /// visible again. Hidden, its receipt is not drawn and its clock stops;
    /// nothing ends, and arrivals wait and age. Visible again, the receipt
    /// is drawn for what is left of its life, and at least 2.5 seconds.
    func setLayerSurface(_ layer: UUID, visible: Bool) {
        guard let index = layers.firstIndex(where: { $0.id == layer }),
              layers[index].surfaceVisible != visible else { return }
        if !visible, var shown = current, isDrawn(shown), drawingLayer(of: shown)?.id == layer {
            shown.returning = true
            current = shown
        }
        layers[index].surfaceVisible = visible
        reconcile()
    }

    /// The receipt a layer draws now, if any. With no layer registered the
    /// queue is one drawing root, and any layer reads its receipt.
    func receipt(drawnBy layer: UUID) -> ToastItem? {
        guard let shown = current, isDrawn(shown) else { return nil }
        if layers.isEmpty { return shown.item }
        return drawingLayer(of: shown)?.id == layer ? shown.item : nil
    }

    private func isDrawn(_ entry: Entry) -> Bool {
        ReceiptRules.isDrawn(belongingTo: entry.layer, in: layers, held: !holds.isEmpty)
    }

    private func mayShow(_ entry: Entry) -> Bool {
        isDrawn(entry)
    }

    private func drawingLayer(of entry: Entry) -> MessageLayerFacts? {
        guard let own = entry.layer ?? layers.last?.id else { return nil }
        return ReceiptRules.drawingLayer(for: own, in: layers)
    }

    // MARK: - The slot shared with the editor's furniture

    /// A receipt is drawn by the root layer: false while no root layer is
    /// registered.
    var receiptAtSlot: Bool {
        guard let shown = current, isDrawn(shown) else { return false }
        return drawingLayer(of: shown)?.role == .root
    }

    /// When the receipt at the slot was first drawn there; nil when none is.
    var receiptAtSlotSince: ContinuousClock.Instant? {
        receiptAtSlot ? current?.atSlotSince : nil
    }

    /// A selection takes the slot back: the receipt at the slot's place
    /// ends, if there is one. Nothing else; its Undo is still the toolbar's.
    func yieldSlotToSelection() {
        guard receiptAtSlot else { return }
        endCurrent()
        reconcile()
    }

    // MARK: - The review request

    /// Runs `perform` at once when no message of that row is shown, paused
    /// or waiting; otherwise once the last of them has ended, for any reason.
    func whenGone(_ name: MessageID.Name, perform: @escaping @MainActor () -> Void) {
        if entries.contains(where: { $0.item.messageID?.name == name }) {
            whenGoneActions.append((name: name, perform: perform))
        } else {
            perform()
        }
    }

    private func runWhenGone() {
        guard !whenGoneActions.isEmpty else { return }
        let names = Set(entries.compactMap { $0.item.messageID?.name })
        let due = whenGoneActions.filter { !names.contains($0.name) }
        whenGoneActions.removeAll { !names.contains($0.name) }
        for action in due { action.perform() }
    }

    // MARK: - Announcements

    /// Speaks lines one after another: each waits for the last to report
    /// its end, or for 3 seconds, whichever is first.
    func announce(_ line: String) {
        announcementLines.append(line)
        speakNextLine()
        schedule(at: now())
    }

    /// The system reports that an announcement ended; `line` is its words
    /// when it says them.
    func announcementDidFinish(_ line: String?) {
        guard let spoken = speaking, line == nil || line == spoken.line else { return }
        speaking = nil
        speakNextLine()
        schedule(at: now())
    }

    private func speakNextLine() {
        guard speaking == nil else { return }
        guard !announcementLines.isEmpty else {
            if let observer = announcementObserver {
                NotificationCenter.default.removeObserver(observer)
                announcementObserver = nil
            }
            return
        }
        let line = announcementLines.removeFirst()
        speaking = (line: line, since: now())
        if announcementObserver == nil {
            let key = UIAccessibility.announcementStringValueUserInfoKey
            announcementObserver = NotificationCenter.default.addObserver(
                forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main
            ) { [weak self] note in
                let words = note.userInfo?[key] as? String
                MainActor.assumeIsolated { self?.announcementDidFinish(words) }
            }
        }
        postAnnouncement(line)
    }

    // MARK: - Show, clock and timer

    /// Acts on everything due at `now()`: a receipt whose life is over or
    /// whose replacement point has come, the gap, an announcement's
    /// fallback. The timer calls it; a test calls it after moving its clock.
    func settleClocks() {
        let at = now()
        if let spoken = speaking,
           ReceiptClock.seconds(spoken.since.duration(to: at)) >= ReceiptRules.announcementFallback {
            speaking = nil
            speakNextLine()
        }
        reconcile()
    }

    private func reconcile() {
        let at = now()
        if let shown = current, let clock = shown.clock, !shown.awaitingFocus {
            if let point = shown.endsWhenOnScreen, clock.elapsed(at: at) >= point {
                if waiting.contains(where: mayShow) {
                    endCurrent(replaced: true)
                } else {
                    current?.endsWhenOnScreen = nil
                }
            } else if clock.remaining(at: at) <= 0 {
                endCurrent()
            }
        }
        if let gap = gapEndsAt, at >= gap { gapEndsAt = nil }
        if current == nil, gapEndsAt == nil {
            while let index = waiting.firstIndex(where: mayShow) {
                let next = waiting.remove(at: index)
                let waited = ReceiptClock.seconds(next.postedAt.duration(to: at))
                if next.clock != nil || ReceiptRules.showsAtItsTurn(next.item.facts, waitedFor: waited) {
                    show(next)
                    break
                }
            }
        }
        if var shown = current, var clock = shown.clock {
            let drawn = isDrawn(shown)
            if drawn, shown.returning {
                clock.keepAtLeast(ReceiptRules.remainingOnReturn(clock.remaining(at: at)), at: at)
                shown.returning = false
            }
            if drawn, shown.clockStops.isEmpty, !shown.awaitingFocus {
                clock.resume(at: at)
            } else {
                clock.stop(at: at)
            }
            shown.clock = clock
            if shown.atSlotSince == nil, drawn, drawingLayer(of: shown)?.role == .root {
                shown.atSlotSince = at
            }
            if shown != current { current = shown }
        }
        schedule(at: at)
        runWhenGone()
    }

    private func show(_ entry: Entry) {
        var next = entry
        if next.layer == nil, let front = layers.last { next.layer = front.id }
        let first = next.clock == nil
        if first {
            next.clock = ReceiptClock(life: displayDuration(for: next.item))
            next.awaitingFocus = next.item.actionHandler != nil && !layers.isEmpty && !next.focusedOnce
                && (voiceOverRunning() || switchControlRunning())
        }
        current = next
        setShown(next.item)
        guard first else { return }
        // Light haptic on toast appearance
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // VoiceOver hears the message's own words, through the one queue
        // of announcements.
        announce(next.item.message)
    }

    private func setShown(_ item: ToastItem) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        withAnimation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.toastIn, reduceMotion: reduceMotion)) {
            activeToasts = [item]
        }
        toastVersion &+= 1
    }

    private func schedule(at now: ContinuousClock.Instant) {
        timer?.cancel()
        timer = nil
        var due: [ContinuousClock.Instant] = []
        if let shown = current, let clock = shown.clock, clock.isRunning, !shown.awaitingFocus {
            due.append(now.advanced(by: .seconds(max(0, clock.remaining(at: now)))))
            if let point = shown.endsWhenOnScreen {
                due.append(now.advanced(by: .seconds(max(0, point - clock.elapsed(at: now)))))
            }
        }
        if let gap = gapEndsAt { due.append(gap) }
        if let spoken = speaking {
            due.append(spoken.since.advanced(by: .seconds(ReceiptRules.announcementFallback)))
        }
        guard let next = due.min() else { return }
        let wait = max(now.duration(to: next), .zero)
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.settleClocks()
        }
    }
}

// MARK: - Commit-feedback contract

/// One commit-feedback contract. Every path that promotes marks
/// into redaction regions — triage "Apply N", "Apply Group", Search &
/// Redact's "Apply N" (including PII Scan mode), and the
/// auto-apply-ON detection completion — builds its count message here, so
/// the number the user sees is the count of regions actually created,
/// never the raw detection or selection total.
enum CommitFeedback {
    /// Appended to every non-nil `markedMessage` result —
    /// "Marked" on its own reads as already-redacted, so the suffix
    /// names the step that still has to happen. Its own `static let` so
    /// the pin below is exact-text. The covered form drops "for
    /// redaction" so the whole message fits the 2-line toast at the
    /// default text size.
    static let notYetRedactedSuffix = ". Not redacted until you tap Redact."

    /// "Marked 3 for redaction. Not redacted until you tap Redact." /
    /// "Marked 19 (9 already covered). Not redacted until you tap
    /// Redact." Returns nil when nothing was created and
    /// nothing was skipped — callers suppress the toast rather than
    /// announce a no-op.
    static func markedMessage(applied: Int, alreadyCovered: Int = 0) -> String? {
        guard applied > 0 || alreadyCovered > 0 else { return nil }
        var message = "Marked \(applied)"
        if alreadyCovered > 0 {
            message += " (\(alreadyCovered) already covered)"
        } else {
            message += " for redaction"
        }
        message += notYetRedactedSuffix
        return message
    }
}
