import UIKit
import RedactionEngine

// The overlay's accessibility, moved out of `RedactionOverlayView.swift` (the
// hub) from its `// MARK: - Accessibility` seam: the overlay as a container,
// the layout pass that drops its cached elements, one element a region and
// one a search highlight, and each region's spoken value. The element cache
// is stored on the hub (an extension adds no storage).

extension RedactionOverlayView {
    // MARK: - Accessibility

    override var isAccessibilityElement: Bool {
        get { false }  // Container, not a direct element
        set { _ = newValue }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cachedAccessibilityElements = nil
        cachedPageRectOnCanvas = nil
        reportBoxPlaceProbeOnce()
    }

    override var accessibilityElements: [Any]? {
        get {
            if let cached = cachedAccessibilityElements { return cached }
            var elements: [UIAccessibilityElement] = regions.enumerated().map { index, region in
                makeAccessibilityElement(for: region, index: index)
            }
            // Search highlight accessibility elements (read-only)
            for highlight in searchHighlights {
                let element = UIAccessibilityElement(accessibilityContainer: self)
                let viewRect = pdfNormalizedToOverlay(highlight.normalizedRect)
                element.accessibilityFrameInContainerSpace = viewRect
                // NEVER include matched text — announce page only.
                // The walk's current match carries a
                // ", current" suffix — still no matched text.
                element.accessibilityLabel = highlight.id == focusedHighlightID
                    ? "Search highlight, page \(pageIndex + 1), current"
                    : "Search highlight, page \(pageIndex + 1)"
                element.accessibilityTraits = .staticText
                elements.append(element)
            }
            cachedAccessibilityElements = elements
            return elements
        }
        set { _ = newValue }
    }

    private func makeAccessibilityElement(
        for region: RedactionRegion, index: Int
    ) -> UIAccessibilityElement {
        let element = UIAccessibilityElement(accessibilityContainer: self)
        let viewRect = pdfNormalizedToOverlay(region.normalizedRect)
        element.accessibilityFrameInContainerSpace = viewRect

        // Numbered label — "Redaction region N"
        element.accessibilityLabel = "Redaction region \(index + 1)"

        // Value describes the region source type
        element.accessibilityValue = accessibilityValue(for: region)

        // Hint based on selection state
        let isSelected = region.id == selectedID
        element.accessibilityHint = isSelected
            ? "Selected. Use delete to remove."
            : "Double tap to select."

        element.accessibilityTraits = .button

        // Custom delete action for selected regions
        if isSelected {
            element.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Delete region") { [weak self] _ in
                    self?.coordinator?.deleteRegion(region.id, page: self?.pageIndex ?? 0)
                    return true
                }
            ]
        }

        return element
    }

    // Accessible description by region source.
    // Appends confidence from metadata when available.
    // Security: matchedText is NOT included in VoiceOver announcements.
    private func accessibilityValue(for region: RedactionRegion) -> String {
        let base: String = switch region.source {
        case .manual: "Manual redaction region"
        case .detectedPII(let kind, _): "Detected \(kind.accessibilityName)"
        case .detectedFace: "Detected face region"
        case .searchMatch: "Search match redaction region"
        }

        if let metadata = coordinator?.redactionState?.regionMetadata[region.id] {
            // Qualitative descriptor replaces the raw
            // percent; same one threshold source as every other site.
            let descriptor = SearchResultRow.absoluteConfidenceTier(metadata.confidence).descriptor
            return "\(base), \(descriptor)"
        }
        return base
    }
}
