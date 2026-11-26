import SwiftUI

/// The one place above the results that says what a search did not read:
/// one notice at most, by rank, sized to the room the list has. It reads the
/// session, asks the rules for its occupant, speaks a notice once and mounts
/// the sheet notice; nothing else mounts it. What it remembers lives on the
/// search state (`SearchNoticeState`), since the results section is
/// unmounted whenever the sheet is parked.
struct SearchNoticePlaceView: View {
    @Bindable var searchState: SearchState
    let degradedLine: SearchNoticeLine?
    /// The list's room: the height between the sheet's fixed top and the
    /// footer or the keyboard, measured by the section.
    let room: CGFloat
    /// The section's width.
    let width: CGFloat
    let onShowDetails: () -> Void
    let onAnnounce: (String) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Space above and below the notice in the place.
    static let verticalMargin: CGFloat = 10

    var body: some View {
        let lines = SearchNoticePlace.shownLines(
            run: SearchNoticePlace.runLines(searchState.noticeFacts), held: searchState.notices.held,
            isSearching: searchState.isSearching, degraded: degradedLine)
        if let occupant = occupant(of: lines) {
            SheetNoticeView(
                text: occupant.text, spokenLine: occupant.line.sentence, lineLimit: occupant.lineLimit,
                control: occupant.control, isHeld: occupant.isHeld, identifier: occupant.line.identifier,
                onTap: { tap(occupant) })
                .dynamicTypeSize(drawSize(for: occupant))
                .padding(.horizontal, NoticeView.Metrics.sideInset)
                .padding(.vertical, Self.verticalMargin)
                .task(id: occupant.line.key + (occupant.isHeld ? "\u{1F}held" : "")) {
                    guard searchState.notices.shouldAnnounce(occupant.line, isHeld: occupant.isHeld) else { return }
                    searchState.notices.announced.insert(occupant.line.key)
                    onAnnounce(occupant.line.sentence)
                }
        }
    }

    private var noticeWidth: CGFloat { max(1, width - 2 * NoticeView.Metrics.sideInset) }

    /// The limit: 40 % of the room; no limit until the room is measured.
    private var limit: CGFloat { room > 0 ? MessageSizing.limit(space: room) : .greatestFiniteMagnitude }

    private func occupant(of lines: [SearchNoticeLine]) -> SearchNoticePlace.Occupant? {
        guard let line = lines.first else { return nil }
        let first = SearchNoticePlace.firstSentence(of: line.sentence)
        let control: SearchNoticePlace.Control = lines.count > 1 ? .opensDetails : .none
        let whole = SheetNoticeView.height(
            text: line.sentence, lineLimit: nil, control: control, size: dynamicTypeSize, width: noticeWidth)
        let twoLines = SheetNoticeView.height(
            text: first, lineLimit: 2, control: .opensDetails, size: dynamicTypeSize, width: noticeWidth)
        let cap = limit >= CGFloat(Int.max / 2) ? Int.max / 2 : Int(limit.rounded(.down))
        return SearchNoticePlace.occupant(
            lines: lines, isHeld: searchState.isSearching && line.kind != .degraded, limit: cap,
            wholeHeight: Int(whole.rounded(.up)), twoLineHeight: Int(twoLines.rounded(.up)),
            personFolded: searchState.notices.folded.contains(line.key))
    }

    /// The one-line form at the accessibility sizes is drawn at the size the
    /// size step gives; every other form at the person's size.
    private func drawSize(for occupant: SearchNoticePlace.Occupant) -> DynamicTypeSize {
        guard occupant.lineLimit == 1, room > 0 else { return dynamicTypeSize }
        return MessageSizing.drawSize(person: dynamicTypeSize, limit: limit) { size in
            SheetNoticeView.height(text: occupant.text, lineLimit: 1, control: occupant.control,
                                   size: size, width: noticeWidth)
        }
    }

    private func tap(_ occupant: SearchNoticePlace.Occupant) {
        switch occupant.control {
        case .none: break
        case .opensDetails: onShowDetails()
        case .foldsInPlace(let folded):
            if folded {
                searchState.notices.folded.remove(occupant.line.key)
            } else {
                searchState.notices.folded.insert(occupant.line.key)
            }
        }
    }
}
