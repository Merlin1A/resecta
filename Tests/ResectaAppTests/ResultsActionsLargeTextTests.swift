import Testing
import Foundation
import SwiftUI
import UIKit
@testable import ResectaApp

// The results screen's buttons at the largest text size, measured in a
// hosting controller: the row's symbol stays inside its 28-pt tile while the
// row's words keep growing, and the capsule keeps clear space around a label
// that takes more than one line. The tile is hidden from accessibility, so a
// UI test cannot read its frame; these measurements stand in for that, and
// the captures at the largest size show the same by eye.

@Suite("Results buttons at large text", .tags(.display))
@MainActor
struct ResultsActionsLargeTextTests {

    static let symbols = ["checkmark.shield", "pencil.and.outline", "eye"]
    /// A phone's width less the card's insets.
    static let rowWidth: CGFloat = 390 - 2 * ResectaTokens.Spacing.md

    static func size(_ view: some View, _ type: DynamicTypeSize, width: CGFloat? = nil) -> CGSize {
        UIHostingController(rootView: view.environment(\.dynamicTypeSize, type))
            .sizeThatFits(in: CGSize(width: width ?? 4_000, height: 4_000))
    }

    @Test("The symbol stays inside its tile at every text size, and is unchanged at the default size")
    func symbolStaysInsideItsTile() {
        let tile = ResectaTokens.Results.actionTile
        for symbol in Self.symbols {
            for type in DynamicTypeSize.allCases {
                let s = Self.size(ResultsActionRow.tileSymbol(symbol), type)
                #expect(s.width <= tile && s.height <= tile, "\(symbol) at \(type): \(s)")
            }
            let plain = Self.size(Image(systemName: symbol).font(.callout.weight(.semibold)), .large)
            #expect(Self.size(ResultsActionRow.tileSymbol(symbol), .large) == plain, "\(symbol)")
        }
    }

    @Test("The row's words keep growing past the symbol's limit")
    func rowWordsKeepGrowing() {
        let row = ResultsActionRow(symbol: "pencil.and.outline", title: "Keep Editing",
                                   subtitle: VerificationResultsView.undoFootnote)
        let atLimit = Self.size(row, ResultsActionRow.symbolSizeLimit, width: Self.rowWidth).height
        let largest = Self.size(row, .accessibility5, width: Self.rowWidth).height
        #expect(largest > atLimit, "limit \(atLimit), largest \(largest)")
        #expect(Self.size(row, .large, width: Self.rowWidth).height >= ResectaTokens.Results.rowMinHeight)
    }

    @Test("The capsule keeps clear space around a label of more than one line, and 50 pt at the default size")
    func capsuleLabelHasRoom() {
        let label = Label("Share Document", systemImage: "square.and.arrow.up")
            .font(.body.weight(.semibold)).labelStyle(.titleAndIcon).multilineTextAlignment(.center)
        let capsule = Button {} label: { Label("Share Document", systemImage: "square.and.arrow.up") }
            .buttonStyle(ResultsCapsuleButtonStyle(kind: .filled(.teal)))
        let inset = ResectaTokens.Results.capsuleLabelInset
        let vertical = ResectaTokens.Results.capsuleLabelInsetVertical
        #expect(Self.size(capsule, .large, width: Self.rowWidth).height == ResectaTokens.Results.capsuleHeight)
        let labelLargest = Self.size(label, .accessibility5, width: Self.rowWidth - 2 * inset)
        let capsuleLargest = Self.size(capsule, .accessibility5, width: Self.rowWidth)
        #expect(labelLargest.width <= Self.rowWidth - 2 * inset)
        #expect(capsuleLargest.height >= labelLargest.height + 2 * vertical,
                "label \(labelLargest), capsule \(capsuleLargest)")
        #expect(capsuleLargest.height > ResectaTokens.Results.capsuleHeight)
    }
}
