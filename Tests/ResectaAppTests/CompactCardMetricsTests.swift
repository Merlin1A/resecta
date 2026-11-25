import Testing
import Foundation
import SwiftUI
import UIKit
@testable import ResectaApp

// The parked Search card's numbers: each buildable value on its named,
// card-local constant; the hug identity with the card's own top padding;
// the touch floor kept at every floored site; and the room under the row
// that holds the line drawn there. Source pins where a value is only a
// view literal.

@Suite("The small card's metrics")
@MainActor
struct CompactCardMetricsTests {

    private static func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("Each buildable value is the card's value, on its named constant")
    func valuesOfRecord() {
        #expect(CompactFloatDetent.hugHeight == 101)
        #expect(CompactCard.applyHeight == 46)
        #expect(CompactCard.applyPadding == 16)
        #expect(CircularIconButtonStyle.parkedDiameter == 46)
        #expect(CircularIconButtonStyle.parkedGlyphPointSize == 20)
        // The row from the card's top: the grabber's inset plus the card's own padding.
        #expect(CompactFloatDetent.grabberInset + CompactCard.rowTopPadding == 15)
        #expect(CompactCard.sideInset == 16)
        #expect(ResultNavSite.parked.pairSpacing == 8)
        // The search bar keeps its own values.
        #expect(ResultNavSite.searchBar.pairSpacing == 6)
        #expect(ResultNavSite.searchBar.diameter == CircularIconButtonStyle.diameter)
    }

    @Test("The hug is the grabber's inset, the card's top padding, the row and the room under it")
    func hugIdentity() {
        #expect(CompactFloatDetent.hugHeight
                == CompactFloatDetent.grabberInset + CompactCard.rowTopPadding
                + CompactFloatDetent.rowHeight + CompactFloatDetent.bottomInset)
        #expect(CompactCard.rowTopPadding >= 0)
    }

    @Test("The circle and Apply keep the touch floor, and the row is the tallest of them")
    func touchFloor() {
        let floor = ResectaTokens.TouchTarget.minimum
        #expect(CircularIconButtonStyle.parkedDiameter >= floor)
        #expect(CompactCard.applyHeight >= floor)
        #expect(CompactFloatDetent.rowHeight
                == max(floor, CompactCard.applyHeight, CircularIconButtonStyle.parkedDiameter))
    }

    @Test("The editor and the sheet both read the one hug")
    func oneHugFeedsBoth() throws {
        let editor = try Self.source("Sources/ResectaApp/Views/DocumentEditorView.swift")
        let sheet = try Self.source("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+CompactApply.swift")
        #expect(editor.contains("hugHeight: CompactFloatDetent.hug(for: dynamicTypeSize)"))
        #expect(sheet.contains("hugHeight: CompactFloatDetent.hug(for: dynamicTypeSize)"))
    }

    @Test("The line's gap is named, and the search bar's cluster keeps its 4-pt outer stack")
    func lineGapAndTheBarsCluster() throws {
        #expect(CompactCard.countLineGap == 6)
        let nav = try Self.source("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+ResultNavigation.swift")
        let start = try #require(nav.range(of: "func resultNavCluster(site: ResultNavSite) -> some View {"))
        let body = nav[start.upperBound...].drop { $0.isWhitespace }
        #expect(body.hasPrefix("HStack(spacing: ResectaTokens.Spacing.xs) {"))
    }

    @Test("A circle over the touch floor is laid out at its own size; one under it at the floor")
    func circleOuterFrame() {
        func size(_ diameter: CGFloat) -> CGSize {
            UIHostingController(rootView: SearchAndRedactSheet.circularIconLabel(
                "chevron.down", diameter: diameter, glyphPointSize: 20))
                .sizeThatFits(in: CGSize(width: 300, height: 300))
        }
        #expect(size(50) == CGSize(width: 50, height: 50))
        #expect(size(44) == CGSize(width: 46, height: 46))
    }

    @Test("Apply's two heights each keep the floor token")
    func applyHeightsKeepTheFloor() throws {
        let apply = try Self.source("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+CompactApply.swift")
        #expect(Self.occurrences(of: "ResectaTokens.TouchTarget.minimum", in: apply) == 2)
        #expect(Self.occurrences(
            of: ".frame(minHeight: max(ResectaTokens.TouchTarget.minimum, CompactCard.applyHeight))", in: apply) == 2)
    }

    @Test("The room under the row holds the line drawn there at xxLarge")
    func roomHoldsTheLine() {
        let room = CompactFloatDetent.hugHeight - CompactFloatDetent.grabberInset
            - CompactCard.rowTopPadding - CompactFloatDetent.rowHeight
        let line = UIFont.preferredFont(
            forTextStyle: .subheadline,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraExtraLarge)).lineHeight
        #expect(room >= CompactCard.countLineGap + ceil(line), "room \(room), line \(line)")
    }
}
