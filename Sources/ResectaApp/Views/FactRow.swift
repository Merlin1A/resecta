import SwiftUI

// The results screen's card of facts about the PDF: plain rows with no
// symbol in front, their text 16 pt in, which sets them apart from the rows
// of checks above. A fact shows its first line whole, with any line that
// tells the person to do something before sharing; a fact with more to say
// has the shipped chevron and opens in place to its other lines and, when
// it has one, a link row. Which lines are shown and which wait for a tap is
// decided where the fact is made; nothing here splits a line.

/// One fact of the card.
// nonisolated: a plain value, made and read off the main actor by tests.
nonisolated struct ResultsFact: Equatable, Identifiable {
    /// Where the fact sits in the card (`ResultsFactCard.items`).
    enum Place: Equatable { case first, notRead, pictures, last }

    /// One item of the opened part, in order.
    enum OpenedItem: Equatable {
        case paragraph(String)
        case door(String)
    }

    /// A stable name: it keys the open row and, unless `identifier` is
    /// given, is the row's identifier.
    let id: String
    /// Always in view: the first line, whole, and any instruction.
    let shown: String
    /// Shown only while the row is open, each its own paragraph.
    var more: [String] = []
    /// The label of a link row at the end of the opened part.
    var door: String? = nil
    var place: Place = .last
    /// The row's identifier when it is not the `id`.
    var identifier: String? = nil

    var accessibilityIdentifier: String { identifier ?? id }

    /// The row opens, and has a chevron, exactly when it has something to
    /// open to.
    var opens: Bool { !more.isEmpty || door != nil }

    /// What the opened part draws: the paragraphs, then the link row.
    var openedItems: [OpenedItem] {
        more.map(OpenedItem.paragraph) + (door.map { [OpenedItem.door($0)] } ?? [])
    }
}

/// One row of the card: a fact, or the Page Modes row.
nonisolated enum ResultsCardItem: Equatable {
    case fact(ResultsFact)
    case pageModes
}

nonisolated enum ResultsFactCard {
    /// The card from top to bottom: handed-in facts placed first; the run's
    /// own lines in their order; handed-in facts about what was not read;
    /// the Detection Sweep's limit when the card holds it; handed-in facts
    /// about pictures; Page Modes when it shows; the row
    /// about items left unredacted; handed-in facts placed last. The card
    /// is drawn when this is not empty.
    static func items(handedIn: [ResultsFact], runLines: [ResultsFact], showsPageModes: Bool,
                      deselection: ResultsFact?, sweepLimit: ResultsFact? = nil) -> [ResultsCardItem] {
        func placed(_ place: ResultsFact.Place) -> [ResultsCardItem] {
            handedIn.filter { $0.place == place }.map(ResultsCardItem.fact)
        }
        var items = placed(.first)
        items += runLines.map(ResultsCardItem.fact)
        items += placed(.notRead)
        if let sweepLimit { items.append(.fact(sweepLimit)) }
        items += placed(.pictures)
        if showsPageModes { items.append(.pageModes) }
        if let deselection { items.append(.fact(deselection)) }
        items += placed(.last)
        return items
    }
}

/// A fact's row. With nothing to open it is text, not a button; with
/// something to open it is a button with the shipped chevron and hint, and
/// open, its paragraphs in the caption grey, 8 pt apart, then the link row.
struct ResultsFactRow: View {
    let fact: ResultsFact
    var isOpen: Bool = false
    var onTap: () -> Void = {}
    var onDoor: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if fact.opens {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onTap) {
                    HStack(alignment: .top, spacing: 0) {
                        shownText
                        DisclosureChevron(isExpanded: isOpen, tint: Color(.secondaryLabel))
                            .frame(width: ResectaTokens.Results.chevronColumn)
                            .padding(.top, ResectaTokens.Spacing.xxs)
                            .padding(.leading, ResectaTokens.Spacing.sm)
                    }
                    .modifier(ResultsFactRowFrame())
                    .contentShape(Rectangle())
                }
                .buttonStyle(ResultsRowButtonStyle())
                .accessibilityLabel(fact.shown)
                .accessibilityHint(LayerResultRow.accessibilityHint(isExpandable: true, isExpanded: isOpen))
                if isOpen {
                    VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
                        ForEach(Array(fact.openedItems.enumerated()), id: \.offset) { _, item in
                            switch item {
                            case .paragraph(let line):
                                Text(line)
                                    .font(.footnote)
                                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                                    .fixedSize(horizontal: false, vertical: true)
                            case .door(let label):
                                ResultsFactDoorRow(label: label, action: onDoor)
                            }
                        }
                    }
                    .padding(.horizontal, ResectaTokens.Spacing.md)
                    .padding(.bottom, ResectaTokens.Spacing.md - 2)
                    .transition(.opacity)
                }
            }
            .background(isOpen ? LayerResultRow.rowWash(colorScheme) : .clear)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(fact.accessibilityIdentifier)
        } else {
            shownText
                .modifier(ResultsFactRowFrame())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(fact.accessibilityIdentifier)
        }
    }

    private var shownText: some View {
        Text(fact.shown)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The shipped rows' insets and height: 16 pt in from each edge, 11 above
/// and below, at least 52 pt.
struct ResultsFactRowFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, ResectaTokens.Spacing.md)
            .padding(.vertical, ResectaTokens.Results.rowVerticalPadding)
            .frame(minHeight: ResectaTokens.Results.rowMinHeight)
    }
}

/// The link row at the end of an opened fact: the label in the text teal,
/// the shipped chevron (it does not turn), hit over the row's width and at
/// least 46 pt high whatever the text's own height. No hint until its
/// sentence is approved.
struct ResultsFactDoorRow: View {
    let label: String
    let action: () -> Void

    /// The label's colour: the teal made for small text.
    static let labelColor = ResectaTokens.BrandTeal.text

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Self.labelColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DisclosureChevron(isExpanded: false, tint: Self.labelColor)
                    .frame(width: ResectaTokens.Results.chevronColumn)
                    .padding(.leading, ResectaTokens.Spacing.sm)
            }
            .frame(maxWidth: .infinity, minHeight: ResectaTokens.TouchTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
