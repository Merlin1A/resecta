import Testing
import SwiftUI
@testable import ResectaApp

// The brief message's structural guard — PR #148 regression gate.
//
// The dismiss crash (master 37b56c9 / PR #148) was caused by the old toast view reading
// `@Environment(ToastQueueManager.self)`: when a `toastVersion` change
// re-evaluated the body inside the synchronous transaction of a coincident
// sheet dismissal, the observable-object environment lookup could not resolve
// and trapped (EXC_BREAKPOINT — the strict-Observation "state during update"
// assertion). The fix injects the manager as a plain `let` constant from
// ContentView, sidestepping the environment read. Deferring the toast out of
// the update cycle was tried first and explicitly REJECTED — it did not fix
// the crash.
//
// This suite is the structural guard for that crash: the view that draws a
// brief message (ReceiptView) must receive its ToastQueueManager as a stored `let`, never via
// `@Environment(ToastQueueManager.self)`. A regression that re-adds the
// environment read fails here — and, because the memberwise initializer would
// then lose its `toastManager:` parameter, fails to compile this suite too.

@Suite("The brief message's structural guard (PR #148 regression gate)")
@MainActor
struct ToastManagerLetInjectionTests {

    @Test("ReceiptView receives ToastQueueManager as a let property, not via @Environment")
    func testReceiptViewReceivesManagerAsLetProperty() {
        let manager = ToastQueueManager()
        let item = ToastItem(message: "Structural guard probe", severity: .info)
        let view = ReceiptView(item: item, toastManager: manager)

        let mirror = Mirror(reflecting: view)

        // 1. The manager is a plain stored `let` named `toastManager`.
        let managerChild = mirror.children.first { $0.label == "toastManager" }
        #expect(managerChild != nil,
                "ReceiptView must store the ToastQueueManager as a `let toastManager` property")
        #expect(managerChild?.value is ToastQueueManager,
                "`toastManager` must be a plain ToastQueueManager (let-injected), not a property wrapper")

        // 2. No stored property is an @Environment wrapper over ToastQueueManager.
        //    An `@Environment(ToastQueueManager.self)` property surfaces as a
        //    child of type `Environment<ToastQueueManager>` (backing storage
        //    named `_toastManager`) — the exact read that trapped pre-PR-148.
        let hasEnvironmentManager = mirror.children.contains { child in
            String(describing: type(of: child.value)).contains("Environment<ToastQueueManager>")
        }
        #expect(!hasEnvironmentManager,
                "ReceiptView must NOT read ToastQueueManager via @Environment — that reintroduces the dismiss crash (PR #148)")
    }

    @Test("The message layer and host modifiers take ToastQueueManager as a let, never from the environment")
    func testMessageModifiersTakeTheManagerAsLet() throws {
        let root = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/ResectaApp/Views/Messages/MessageHost.swift"), encoding: .utf8)
        #expect(!source.contains("@Environment(ToastQueueManager.self)"),
                "the message modifiers must NOT read ToastQueueManager via @Environment (PR #148)")
        for name in ["MessageLayerModifier", "MessageHostModifier", "MessageHoldModifier"] {
            guard let start = source.range(of: "struct \(name): ViewModifier {") else {
                Issue.record("\(name) is missing"); continue
            }
            let rest = source[start.upperBound...]
            let body = rest[..<(rest.range(of: "\n}\n")?.lowerBound ?? rest.endIndex)]
            #expect(body.contains("let queue: ToastQueueManager"), "\(name) stores the queue as a let")
        }
    }
}
