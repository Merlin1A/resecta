import Testing
import SwiftUI
@testable import ResectaApp

// Smoke tests for the home-screen choice card. The view is exercised
// via direct property access + body evaluation rather than through a
// UIHostingController; this is the same lightweight pattern the rest
// of the app-test suite uses for view-shape coverage (cf. the broader
// suite — full snapshot/interaction coverage is out of scope here).

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

    @Test("Primary style builds a body without crashing")
    func primaryRenders() {
        let card = HomeChoiceCard(
            symbol: "doc.badge.plus",
            style: .primary,
            title: "Title",
            bodyText: "Body",
            affordance: "Affordance →",
            action: {}
        )
        _ = card.body
    }

    @Test("Subtle style builds a body without crashing")
    func subtleRenders() {
        let card = HomeChoiceCard(
            symbol: "sparkles",
            style: .subtle,
            title: "Title",
            bodyText: "Body",
            affordance: "Affordance →",
            action: {}
        )
        _ = card.body
    }
}
