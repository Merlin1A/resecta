import Testing
import SwiftUI
@testable import ResectaApp

// ToastView structural guard — PR #148 regression gate (CAT-235).
//
// The dismiss crash (master 37b56c9 / PR #148) was caused by ToastView reading
// `@Environment(ToastQueueManager.self)`: when a `toastVersion` change
// re-evaluated the body inside the synchronous transaction of a coincident
// sheet dismissal, the observable-object environment lookup could not resolve
// and trapped (EXC_BREAKPOINT — the strict-Observation "state during update"
// assertion). The fix injects the manager as a plain `let` constant from
// ContentView, sidestepping the environment read. Deferring the toast out of
// the update cycle was tried first and explicitly REJECTED — it did not fix
// the crash.
//
// The shipped UI test (DetectionTriageDismissUITests) exercises the crash PATH
// (tap Dismiss → assert the app survived) but does not pin the STRUCTURAL
// property that prevents it. This suite is that structural guard: ToastView
// must receive its ToastQueueManager as a stored `let`, never via
// `@Environment(ToastQueueManager.self)`. A regression that re-adds the
// environment read fails here — and, because the memberwise initializer would
// then lose its `toastManager:` parameter, fails to compile this suite too.

@Suite("ToastView structural guard (PR #148 regression gate)")
@MainActor
struct ToastManagerLetInjectionTests {

    @Test("ToastView receives ToastQueueManager as a let property, not via @Environment")
    func testToastViewReceivesManagerAsLetProperty() {
        let manager = ToastQueueManager()
        let item = ToastItem(message: "Structural guard probe", severity: .info)
        let view = ToastView(item: item, toastManager: manager)

        let mirror = Mirror(reflecting: view)

        // 1. The manager is a plain stored `let` named `toastManager`.
        let managerChild = mirror.children.first { $0.label == "toastManager" }
        #expect(managerChild != nil,
                "ToastView must store the ToastQueueManager as a `let toastManager` property")
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
                "ToastView must NOT read ToastQueueManager via @Environment — that reintroduces the dismiss crash (PR #148)")
    }
}
