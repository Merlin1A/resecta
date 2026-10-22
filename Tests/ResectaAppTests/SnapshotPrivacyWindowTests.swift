import Testing
import UIKit
@testable import ResectaApp

// The snapshot cover's own window: attached to the foreground scene, above
// every other window of that scene (so above the main window's presented
// sheets), passing no touches; hidden again on reveal. Hosted in the app,
// so the host's scene is the scene under test.

@Suite("Snapshot privacy cover window")
@MainActor
struct SnapshotPrivacyWindowTests {

    @Test("Shown, the cover sits above every other window of the scene and takes no touches; hidden on reveal")
    func coverSitsAboveTheScene() throws {
        let scene = try #require(SnapshotPrivacyWindowController.foregroundScene(), "the host app's scene")
        let controller = SnapshotPrivacyWindowController()
        #expect(controller.window == nil)

        controller.show(in: scene)
        let cover = try #require(controller.window)
        #expect(!cover.isHidden)
        #expect(cover.windowScene === scene)
        #expect(cover.windowLevel == SnapshotPrivacyWindowController.level)
        #expect(cover.windowLevel.rawValue > UIWindow.Level.alert.rawValue)
        #expect(scene.windows.filter { $0 !== cover }.allSatisfy { $0.windowLevel < cover.windowLevel },
                "every other window of the scene, the main window and its presentations included, lies below")
        #expect(!cover.isUserInteractionEnabled)
        #expect(cover.rootViewController != nil)

        controller.hide()
        #expect(cover.isHidden)
        controller.show(in: scene)
        #expect(controller.window === cover, "the same window is reused")
        controller.hide()
    }

    @Test("The policy that drives the window is the overlay's own")
    func policyIsShared() {
        #expect(SnapshotPrivacyPolicy.action(for: .inactive) == .obscureSynchronously)
        #expect(SnapshotPrivacyPolicy.action(for: .background) == .obscureSynchronously)
        #expect(SnapshotPrivacyPolicy.action(for: .active) == .revealAnimated)
    }
}
