import UIKit
import RedactionEngine

// The long-press menu's highlight preview: the held region itself, lifted
// in place with its own outline, rather than the whole canvas floating
// behind the menu. The menu's configuration carries the region's id
// (`RedactionOverlayView+ContextMenu.swift`).

extension RedactionOverlayView {

    @objc func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        regionPreview(for: configuration)
    }

    @objc func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        regionPreview(for: configuration)
    }

    /// A preview of this view clipped to the held region's rect.
    private func regionPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let id = configuration.identifier as? UUID,
              let region = regions.first(where: { $0.id == id })
        else { return nil }
        let rect = pdfNormalizedToOverlay(region.normalizedRect)
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: rect, cornerRadius: 4)
        parameters.backgroundColor = .clear
        let target = UIPreviewTarget(container: self, center: CGPoint(x: rect.midX, y: rect.midY))
        return UITargetedPreview(view: self, parameters: parameters, target: target)
    }
}
