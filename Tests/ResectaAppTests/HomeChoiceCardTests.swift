import Testing
import SwiftUI
import UIKit
@testable import ResectaApp

// The home-screen choice card, checked two ways per style. Rendered: the
// card is hosted in a `UIHostingController` inside a key `UIWindow`, laid
// out, and must fit to a non-zero size. Structural: the card's body is a
// `Button` whose label is `HomeChoiceCardContent` carrying the symbol, the
// style, and the title / body / affordance strings the card was given — the
// same `Mirror` pin `ToastManagerLetInjectionTests` uses. The strings are
// not read back through the accessibility tree because a unit-test host
// receives no accessibility elements from SwiftUI on the iOS 26.5 simulator
// runtime (measured 2026-08-27; the 26.4 runtime does publish them), and the
// batched runner picks the newest runtime.

@Suite("HomeChoiceCard")
@MainActor
struct HomeChoiceCardTests {

    @Test("Action closure fires when invoked")
    func actionFires() {
        var fired = false
        let card = HomeChoiceCard(
            symbol: "doc.badge.plus",
            style: .primary,
            title: "Title",
            bodyText: "Body",
            affordance: "Affordance →",
            action: { fired = true }
        )
        card.action()
        #expect(fired)
    }

    @Test("Primary style hosts at a non-zero size and composes its content with the given strings")
    func primaryRenders() {
        let card = Self.makeCard(style: .primary, symbol: "doc.badge.plus")
        let size = Self.hostedSize(of: card)
        #expect(size.width > 0 && size.height > 0, "hosted primary card fitted to \(size)")
        Self.expectContent(of: card, style: .primary, symbol: "doc.badge.plus")
    }

    @Test("Subtle style hosts at a non-zero size and composes its content with the given strings")
    func subtleRenders() {
        let card = Self.makeCard(style: .subtle, symbol: "sparkles")
        let size = Self.hostedSize(of: card)
        #expect(size.width > 0 && size.height > 0, "hosted subtle card fitted to \(size)")
        Self.expectContent(of: card, style: .subtle, symbol: "sparkles")
    }

    // MARK: - Fixture

    private static let title = "Card title"
    private static let bodyText = "Card body"
    private static let affordance = "Card affordance"

    private static func makeCard(style: HomeChoiceCard.Style, symbol: String) -> HomeChoiceCard {
        HomeChoiceCard(
            symbol: symbol,
            style: style,
            title: LocalizedStringKey(title),
            bodyText: LocalizedStringKey(bodyText),
            affordance: LocalizedStringKey(affordance),
            action: {}
        )
    }

    // MARK: - Rendered fact

    /// Host the card in a key window at the iPhone editor width, let the
    /// render loop commit once, and return the fitted size.
    private static func hostedSize(of card: HomeChoiceCard) -> CGSize {
        let controller = UIHostingController(rootView: card)
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let size = controller.sizeThatFits(
            in: CGSize(width: frame.width, height: UIView.layoutFittingExpandedSize.height))
        window.isHidden = true
        return size
    }

    // MARK: - Structural pin

    /// `card.body` is `ModifiedContent<Button<HomeChoiceCardContent>, …>`:
    /// its `content` child is the button, whose `label` child is the content
    /// view. A `LocalizedStringKey` exposes the literal it was built from as
    /// its `key` child.
    private static func expectContent(of card: HomeChoiceCard, style: HomeChoiceCard.Style, symbol: String) {
        guard let button = child(of: card.body, named: "content"),
              let content = child(of: button, named: "label") as? HomeChoiceCardContent else {
            Issue.record("HomeChoiceCard.body no longer composes a Button whose label is HomeChoiceCardContent")
            return
        }
        #expect(content.symbol == symbol)
        #expect(content.style == style)
        #expect(literal(of: content.title) == title)
        #expect(literal(of: content.bodyText) == bodyText)
        #expect(literal(of: content.affordance) == affordance)
    }

    private static func child(of value: Any, named label: String) -> Any? {
        Mirror(reflecting: value).children.first { $0.label == label }?.value
    }

    private static func literal(of key: LocalizedStringKey) -> String? {
        child(of: key, named: "key") as? String
    }
}
