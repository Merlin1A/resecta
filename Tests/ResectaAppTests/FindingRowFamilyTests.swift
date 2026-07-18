import Testing
import Foundation
import CoreGraphics
import SwiftUI
@testable import ResectaApp
@testable import RedactionEngine

// The unified row family's adapter contracts: one `FindingRowModel`
// renders BOTH result origins (engine `SearchResult`s and staged
// `DetectionResult`s), carrying each origin's deliberate asymmetries —
// the a11y content policy (detection review rows speak matched text per
// F-7; search rows never do) and the per-origin secondary line.

@Suite("FindingRow family — adapter contracts")
@MainActor
struct FindingRowFamilyTests {

    private func makeSearchResult(
        matchedText: String = "alpha",
        pageIndex: Int = 2
    ) -> SearchResult {
        SearchResult(
            pageIndex: pageIndex,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: matchedText,
            contextSnippet: "…the \(matchedText) sits here…",
            source: .textLayer,
            term: matchedText
        )
    }

    private func makeDetection(
        kind: DetectionResult.Kind,
        confidence: Double = 0.87,
        matchedText: String? = nil
    ) -> DetectionResult {
        DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.04),
            kind: kind,
            confidence: confidence,
            matchedText: matchedText
        )
    }

    // MARK: - Search origin

    @Test("search adapter — title is matched text, secondary is the context snippet")
    func searchAdapterShape() {
        let result = makeSearchResult()
        let model = FindingRowModel(result: result)
        #expect(model.id == result.id)
        #expect(model.pageIndex == 2)
        #expect(model.title == "alpha")
        #expect(model.titleIsContent)
        #expect(model.secondaryText == result.contextSnippet)
        #expect(model.secondaryIsContent)
        #expect(!model.showsAmbiguousSurnameHint)
    }

    @Test("search adapter — a11y label names the page only, never matched text")
    func searchAdapterAccessibilityPolicy() {
        let model = FindingRowModel(result: makeSearchResult(matchedText: "123-45-6789"))
        #expect(model.accessibilityDescription == "Search match, page 3")
        #expect(!model.accessibilityDescription.contains("123-45-6789"))
    }

    // MARK: - Detection origin (text kinds)

    @Test("detection adapter — text kind: title is matched text, secondary carries the confidence noun")
    func detectionTextAdapterShape() {
        let det = makeDetection(kind: .pii(.ssn), confidence: 0.97, matchedText: "123-45-6789")
        let model = FindingRowModel(
            page: 0, detection: det, isSelected: false, isAmbiguousSurname: false
        )
        #expect(model.id == det.id)
        #expect(model.title == "123-45-6789")
        #expect(model.titleIsContent)
        #expect(model.secondaryText == "97% confidence")
        #expect(!model.secondaryIsContent)
    }

    @Test("detection adapter — a11y label speaks status, kind, matched text, page, confidence (F-7)")
    func detectionAdapterAccessibilityPolicy() {
        let det = makeDetection(kind: .pii(.ssn), confidence: 0.97, matchedText: "123-45-6789")
        let deselected = FindingRowModel(
            page: 0, detection: det, isSelected: false, isAmbiguousSurname: false
        )
        // F-7 deliberate asymmetry: the review context speaks content.
        #expect(deselected.accessibilityDescription
                == "Deselected. Social Security Number, 123-45-6789. Page 1. 97% confidence.")
        let selected = FindingRowModel(
            page: 0, detection: det, isSelected: true, isAmbiguousSurname: false
        )
        #expect(selected.accessibilityDescription.hasPrefix("Selected."))
    }

    @Test("detection adapter — ambiguous-surname hint carries through")
    func detectionAdapterAmbiguousHint() {
        let det = makeDetection(kind: .pii(.name), confidence: 0.71, matchedText: "Avery")
        let model = FindingRowModel(
            page: 0, detection: det, isSelected: false, isAmbiguousSurname: true
        )
        #expect(model.showsAmbiguousSurnameHint)
    }

    // MARK: - Detection origin (non-text kinds)

    @Test("detection adapter — face kind renders its kind name, no content flag")
    func faceAdapterShape() {
        let det = makeDetection(kind: .face, confidence: 0.8, matchedText: nil)
        let model = FindingRowModel(
            page: 1, detection: det, isSelected: false, isAmbiguousSurname: false
        )
        #expect(model.title == DetectionResult.Kind.face.fullName)
        #expect(!model.titleIsContent)
        #expect(model.secondaryText == "80% confidence")
        // No matched text → the a11y label has no content clause.
        #expect(model.accessibilityDescription
                == "Deselected. \(DetectionResult.Kind.face.fullName). Page 2. 80% confidence.")
    }

    @Test("detection adapter — signature candidate and barcode render their kind names honestly")
    func nonTextKindAdapterShapes() {
        for kind: DetectionResult.Kind in [.pii(.signatureCandidate), .pii(.barcode)] {
            let det = makeDetection(kind: kind, confidence: 0.66, matchedText: nil)
            let model = FindingRowModel(
                page: 0, detection: det, isSelected: false, isAmbiguousSurname: false
            )
            #expect(model.title == kind.fullName)
            #expect(!model.titleIsContent)
            #expect(model.secondaryText == "66% confidence")
        }
    }
}
