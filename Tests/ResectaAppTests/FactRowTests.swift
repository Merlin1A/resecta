import Testing
import Foundation
import SwiftUI
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// The card of facts about the PDF: its order, the run's own lines shown
// whole, when a fact opens, one row open at a time across the screen, the
// link row's height and colour, and that the card's rows carry no symbol.

@Suite("The card of facts", .tags(.display))
@MainActor
struct FactRowTests {

    typealias Fact = ResultsFact
    typealias Item = ResultsCardItem

    static func fact(_ id: String, _ place: Fact.Place) -> Fact { Fact(id: id, shown: id, place: place) }
    static let line0 = Fact(id: "runFactsStrip", shown: "a run line")
    static let line1 = Fact(id: "runFactsLine_1", shown: "another run line")
    static let deselection = Fact(id: "deselectionRow", shown: "You left 1 of 3 detected items unredacted.")

    // MARK: - The order

    @Test("The card's order: first, the run's lines, not read, pictures, Page Modes, items left, last")
    func cardOrder() {
        let first = Self.fact("first", .first), notRead = Self.fact("notRead", .notRead)
        let pictures = Self.fact("pictures", .pictures), last = Self.fact("last", .last)
        let first2 = Self.fact("first2", .first), last2 = Self.fact("last2", .last)
        // (handed in, run lines, Page Modes, items left, expected)
        let rows: [([Fact], [Fact], Bool, Fact?, [Item])] = [
            ([], [], false, nil, []),
            ([], [Self.line0], false, nil, [.fact(Self.line0)]),
            ([], [Self.line0, Self.line1], false, nil, [.fact(Self.line0), .fact(Self.line1)]),
            ([], [Self.line0], true, nil, [.fact(Self.line0), .pageModes]),
            ([], [], true, Self.deselection, [.pageModes, .fact(Self.deselection)]),
            ([last, pictures, notRead, first], [Self.line0, Self.line1], true, Self.deselection,
             [.fact(first), .fact(Self.line0), .fact(Self.line1), .fact(notRead), .fact(pictures), .pageModes,
              .fact(Self.deselection), .fact(last)]),
            ([last2, first, notRead, last, first2, pictures], [Self.line0], true, Self.deselection,
             [.fact(first), .fact(first2), .fact(Self.line0), .fact(notRead), .fact(pictures), .pageModes,
              .fact(Self.deselection), .fact(last2), .fact(last)]),
            ([pictures, last, first], [], false, nil, [.fact(first), .fact(pictures), .fact(last)]),
        ]
        var ran = 0
        for (handedIn, lines, pageModes, deselection, expected) in rows {
            #expect(ResultsFactCard.items(handedIn: handedIn, runLines: lines, showsPageModes: pageModes,
                                          deselection: deselection) == expected, "row \(ran)")
            ran += 1
        }
        print("[fact-card] order rows \(ran)")
        #expect(ran == 8)
    }

    @Test("A clean pass with nothing to say has no card")
    func cleanPassHasNoCard() throws {
        let report = try #require(VerificationDebugFixtures.all["secureAllPass"])
        #expect(!VerificationResultsView.showsPageModes(report: report))
        #expect(ResultsFactCard.items(handedIn: [], runLines: [], showsPageModes: false,
                                      deselection: VerificationDetailsSection.deselectionFact(snapshot: nil)).isEmpty)
    }

    // MARK: - The run's own lines

    @Test("The run's own lines are shown whole, the instruction included")
    func todaysLinesAreShownWhole() {
        let tooLargeOne = VerificationResultsView.RunFactsStrip.ocrSkipLine(pages: [2])
        let tooLargeMany = VerificationResultsView.RunFactsStrip.ocrSkipLine(pages: [0, 3])
        let lines = [
            tooLargeOne, tooLargeMany,
            VerificationResultsView.RunFactsStrip.degradeLine(
                failedGazetteers: [GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue]),
            VerificationResultsView.RunFactsStrip.degradeLine(failedGazetteers: ["a", "b"]),
        ]
        #expect(Set(lines).count == 4)
        let facts = VerificationDetailsSection.runLineFacts(lines)
        #expect(facts.count == 4)
        for (line, fact) in zip(lines, facts) {
            #expect(Array(fact.shown.utf8) == Array(line.utf8))
            #expect(fact.more.isEmpty && fact.door == nil && !fact.opens)
        }
        #expect(facts.map(\.id) == ["runFactsStrip", "runFactsLine_1", "runFactsLine_2", "runFactsLine_3"])
        #expect(facts[0].shown.hasSuffix("Review that page manually before sharing."))
        #expect(facts[1].shown.hasSuffix("Review those pages manually before sharing."))
        print("[fact-card] run lines \(facts.count)")
    }

    @Test("The row about items left unredacted is a fact with the shipped sentence")
    func deselectionIsAFact() {
        let fact = VerificationDetailsSection.deselectionFact(deselected: 2, total: 5)
        #expect(fact.id == "deselectionRow")
        #expect(fact.shown == VerificationResultsView.deselectionRowText(deselected: 2, total: 5))
        #expect(fact.shown == "You left 2 of 5 detected items unredacted.")
        #expect(!fact.opens)
        // No snapshot (no live scan at run entry): no row.
        #expect(VerificationDetailsSection.deselectionFact(snapshot: nil) == nil)
    }

    // MARK: - Opening

    @Test("A fact opens only when there is something to open")
    func aFactOpensOnlyWhenThereIsSomethingToOpen() {
        #expect(Fact(id: "a", shown: "a", more: ["m"]).opens)
        #expect(Fact(id: "b", shown: "b", door: "D").opens)
        #expect(Fact(id: "c", shown: "c", more: ["m"], door: "D").opens)
        #expect(!Fact(id: "d", shown: "d").opens)
        // A door alone opens to the link row and nothing above it.
        #expect(Fact(id: "b", shown: "b", door: "D").openedItems == [.door("D")])
    }

    @Test("The opened part keeps its paragraphs in order, then the link row")
    func openedParagraphsKeepTheirOrder() {
        let fact = Fact(id: "f", shown: "f", more: ["one", "two", "three"], door: "D")
        #expect(fact.openedItems == [.paragraph("one"), .paragraph("two"), .paragraph("three"), .door("D")])
    }

    @Test("One row open at a time across facts, checks and Page Modes")
    func oneRowOpenAtATime() {
        typealias Open = VerificationDetailsSection.OpenItem
        let after = VerificationDetailsSection.openItem(afterTapping:current:)
        let rows: [(Open, Open?, Open?)] = [
            (.layer(2), .fact("f"), .layer(2)),      // a check tapped: the fact closes
            (.fact("f"), .layer(2), .fact("f")),     // a fact tapped: the check closes
            (.pageModes, .fact("f"), .pageModes),    // Page Modes tapped: the fact closes
            (.fact("f"), .fact("f"), nil),           // the same fact twice: it closes
            (.fact("g"), .fact("f"), .fact("g")),    // another fact: the first closes
        ]
        for (tapped, current, expected) in rows {
            #expect(after(tapped, current) == expected, "\(tapped) on \(String(describing: current))")
        }
        #expect(rows.count == 5)
    }

    // MARK: - The link row

    static func height(_ view: some View, _ type: DynamicTypeSize) -> CGFloat {
        UIHostingController(rootView: view.environment(\.dynamicTypeSize, type))
            .sizeThatFits(in: CGSize(width: 300, height: 4_000)).height
    }

    @Test("The link row can be hit: at least 46 pt high, in the text teal")
    func linkRowCanBeHit() {
        let row = ResultsFactDoorRow(label: "What Boxes Can Show", action: {})
        for type in [DynamicTypeSize.large, .accessibility5] {
            let h = Self.height(row, type)
            #expect(h >= ResectaTokens.TouchTarget.minimum, "\(type): \(h)")
        }
        #expect(ResultsFactDoorRow.labelColor == ResectaTokens.BrandTeal.text)
    }

    // MARK: - The source

    @Test("The card's rows carry no symbol; the shipped identifiers stay")
    func cardRowsCarryNoSymbol() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/VerificationDetailsSection.swift"), encoding: .utf8)
        for gone in ["runSectionRow(", "\"info.circle\"", "\"checklist.unchecked\"", "\"square.2.layers.3d\""] {
            #expect(!source.contains(gone), "\(gone)")
        }
        for kept in ["\"runFactsStrip\"", "\"deselectionRow\"", "\"pageModesSection\""] {
            #expect(source.contains(kept), "\(kept)")
        }
    }
}
