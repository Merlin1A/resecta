import SwiftUI

// Where brief messages are drawn. A presented view joins the queue as a
// layer (`messageLayer`, in its presenter's closure, outside the view's own
// capture cover, so it leaves only when its sheet is dismissed); its body
// draws the receipt the queue gives that layer (`messageHost`, directly
// before the capture cover where there is one, else last); a dialog or a
// picker holds the queue while it is up (`holdsMessages`). Each modifier
// takes the queue as a `let`, never through the environment (the dismissal
// crash: `ToastManagerLetInjectionTests`). A view leaving the screen ends
// no message: the only calls on disappearing unregister a layer, mark its
// surface hidden, or release a hold.

private struct MessageLayerIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// The message layer the view is in, set by `messageLayer`.
    var messageLayerID: UUID? {
        get { self[MessageLayerIDKey.self] }
        set { self[MessageLayerIDKey.self] = newValue }
    }
}

/// The height a brief message is read in, reported by the editor's canvas
/// (from the toolbar's foot to the top of the bottom chrome) and read by
/// the root host.
struct MessageReadableSpace: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// Where a host draws its receipt.
enum MessagePlace: Equatable {
    /// The workspace's root: Home, the editor, a run, the results.
    case root
    /// Search: above its footer, which the compact float and the keyboard move.
    case sheetFooter(lift: CGFloat)
    /// Any other sheet: above its bottom edge.
    case otherSheet
}

/// The receipt's place, in points above the host's bottom safe-area edge.
enum MessagePlacement {
    /// Above the bottom chrome while editing.
    static let aboveChrome: CGFloat = 8
    /// Above the screen's foot everywhere else at the root.
    static let aboveScreenFoot: CGFloat = 44
    /// Above a sheet's footer or bottom edge.
    static let aboveSheetFooter: CGFloat = 12

    /// At the root: `bottomClearance + 8` while editing; otherwise 44 above
    /// the screen's foot, which is `44 − safeAreaBottom` above the edge.
    static func rootLift(editing: Bool, bottomClearance: CGFloat, safeAreaBottom: CGFloat) -> CGFloat {
        editing ? bottomClearance + aboveChrome : max(0, aboveScreenFoot - safeAreaBottom)
    }

    /// In a sheet: 12 above its footer's lift (`sheetToastLift`), or above
    /// its bottom edge.
    static func sheetLift(footerLift: CGFloat) -> CGFloat {
        footerLift + aboveSheetFooter
    }
}

extension View {
    /// Joins the queue as a layer while this view is presented.
    func messageLayer(_ queue: ToastQueueManager, role: MessageLayerRole) -> some View {
        modifier(MessageLayerModifier(queue: queue, role: role))
    }

    /// Draws the receipt the queue gives this view's layer, at `place`.
    func messageHost(_ queue: ToastQueueManager, place: MessagePlace, yields: Bool = false) -> some View {
        modifier(MessageHostModifier(queue: queue, place: place, yields: yields))
    }

    /// Holds the queue while `held`: nothing new is shown and the shown
    /// receipt's clock stops; releasing only restarts the clock.
    func holdsMessages(_ queue: ToastQueueManager, while held: Bool) -> some View {
        modifier(MessageHoldModifier(queue: queue, held: held))
    }
}

struct MessageLayerModifier: ViewModifier {
    let queue: ToastQueueManager
    let role: MessageLayerRole
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.messageLayerID, id)
            .onAppear { queue.registerLayer(id, role: role) }
            .onDisappear { queue.unregisterLayer(id) }
    }
}

struct MessageHostModifier: ViewModifier {
    let queue: ToastQueueManager
    let place: MessagePlace
    let yields: Bool
    @Environment(\.messageLayerID) private var layerID
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hostSize: CGSize = .zero
    @State private var safeAreaBottom: CGFloat = 0
    @State private var canvasSpace: CGFloat?

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(MessageReadableSpace.self) { canvasSpace = $0 }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { hostSize = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { safeAreaBottom = $0 }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    if let layerID, let item = queue.receipt(drawnBy: layerID) {
                        ReceiptView(item: item, toastManager: queue)
                            .dynamicTypeSize(drawSize(for: item))
                            .accessibilitySortPriority(1)
                            .transition(ResectaTokens.Anim.resolvedTransition(
                                standard: .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity),
                                reduceMotion: reduceMotion)
                                .combined(with: .leavingTakesNoTouches))
                            .id(item.id)
                    }
                }
                .padding(.bottom, lift)
                .animation(
                    ResectaTokens.Anim.resolved(ResectaTokens.Anim.toastIn, reduceMotion: reduceMotion),
                    value: queue.toastVersion)
            }
            .onChange(of: yields, initial: true) { _, value in
                if let layerID { queue.setLayerYields(layerID, value) }
            }
            .onAppear { if let layerID { queue.setLayerSurface(layerID, visible: true) } }
            .onDisappear { if let layerID { queue.setLayerSurface(layerID, visible: false) } }
    }

    private var lift: CGFloat {
        switch place {
        case .root:
            MessagePlacement.rootLift(editing: queue.documentPhase == .editing,
                                      bottomClearance: queue.bottomClearance, safeAreaBottom: safeAreaBottom)
        case .sheetFooter(let lift):
            MessagePlacement.sheetLift(footerLift: lift)
        case .otherSheet:
            MessagePlacement.sheetLift(footerLift: 0)
        }
    }

    /// The space the receipt is read in: the editor's canvas while editing
    /// at the root, else the host's own height.
    private var readableSpace: CGFloat {
        if place == .root, queue.documentPhase == .editing, let canvasSpace { return canvasSpace }
        return hostSize.height
    }

    private func drawSize(for item: ToastItem) -> DynamicTypeSize {
        guard hostSize.width > 0 else { return dynamicTypeSize }
        return MessageSizing.drawSize(person: dynamicTypeSize, limit: MessageSizing.limit(space: readableSpace)) {
            ReceiptView.height(of: item, size: $0, width: hostSize.width)
        }
    }
}

/// A receipt that is leaving takes no touches: while it fades, a tap or
/// a drag meant for what lies under it reaches that view instead.
private struct TakesTouches: ViewModifier {
    let takes: Bool
    func body(content: Content) -> some View {
        content.allowsHitTesting(takes)
    }
}

private extension AnyTransition {
    static var leavingTakesNoTouches: AnyTransition {
        .asymmetric(
            insertion: .identity,
            removal: .modifier(active: TakesTouches(takes: false), identity: TakesTouches(takes: true)))
    }
}

struct MessageHoldModifier: ViewModifier {
    let queue: ToastQueueManager
    let held: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: held, initial: true) { _, value in queue.setHold(id, value) }
            .onDisappear { queue.setHold(id, false) }
    }
}
