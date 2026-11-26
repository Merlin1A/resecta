import SwiftUI

// The sheet's side of the notice place: the degraded-detection line, the
// lines that hold now, the parked strip's mark and the details.

extension SearchAndRedactSheet {

    /// The session's line, present while the degraded-detection notice
    /// shows for the interface in view.
    var noticeDegradedLine: SearchNoticeLine? {
        var shows = Self.degradeBannerShouldShow(
            interface: searchState.searchModeType.interface, degraded: redactionState.autoDetectionDegraded)
        #if DEBUG
        if SearchState.noticeSeed?.degraded == true, searchState.searchModeType.interface == .scan { shows = true }
        #endif
        return SearchNoticePlace.degradedLine(shows: shows, failures: redactionState.autoDetectionDegradeFailures)
    }

    /// The lines that hold now, in rank order: what the place, the mark and
    /// the details read.
    var noticeShownLines: [SearchNoticeLine] {
        SearchNoticePlace.shownLines(
            run: SearchNoticePlace.runLines(searchState.noticeFacts), held: searchState.notices.held,
            isSearching: searchState.isSearching, degraded: noticeDegradedLine)
    }

    /// The parked strip's caution mark, while the place would show a notice:
    /// a button named by that notice's whole sentence; a tap raises the sheet
    /// to half height.
    @ViewBuilder
    var stripNoticeMark: some View {
        if let label = SearchNoticePlace.stripMarkLabel(noticeShownLines) {
            Button {
                selectedDetent = .medium
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: Self.stripNoticeMarkSize))
                    .foregroundStyle(ResectaTokens.Ink.cautionMark)
                    .frame(width: ResectaTokens.TouchTarget.minimum, height: ResectaTokens.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityIdentifier("parkedStripNoticeMark")
        }
    }

    /// The mark's glyph size on the strip.
    nonisolated static let stripNoticeMarkSize: CGFloat = 16

    /// The details, over Search. A chip closes them, then shows its page and
    /// parks the sheet.
    var noticeDetailsSheet: some View {
        NotSearchedDetailsSheet(lines: noticeShownLines, captureMonitor: captureMonitor) { page in
            activeModal = nil
            showPage(page)
        }
    }
}
