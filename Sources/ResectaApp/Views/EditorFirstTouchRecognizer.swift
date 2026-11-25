import SwiftUI
import UIKit

/// Reports a touch beginning anywhere in the editor's window, then fails at
/// once. It never begins, so it never cancels, delays or prevents anything:
/// every other recognizer and the canvas's own touch handling see the same
/// touch as if it were not there.
final class EditorFirstTouchRecognizer: UIGestureRecognizer {

    private let onTouchDown: () -> Void

    init(onTouchDown: @escaping () -> Void) {
        self.onTouchDown = onTouchDown
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        onTouchDown()
        state = .failed
    }
}

/// Puts the recognizer on the window it is shown in while it is mounted and
/// takes it off when it leaves. It draws nothing and takes no touches.
struct EditorFirstTouchInstaller: UIViewRepresentable {
    let onTouchDown: () -> Void

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.onTouchDown = onTouchDown
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        view.onTouchDown = onTouchDown
    }

    static func dismantleUIView(_ view: InstallerView, coordinator: ()) {
        view.uninstall()
    }

    final class InstallerView: UIView {
        var onTouchDown: () -> Void = {}
        private var recognizer: EditorFirstTouchRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            uninstall()
            guard let window else { return }
            let recognizer = EditorFirstTouchRecognizer { [weak self] in self?.onTouchDown() }
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }

        func uninstall() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }
    }
}
