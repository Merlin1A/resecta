import SwiftUI

// The list of pages a search did not read, and why. One value, made by
// its caller, holds the sections, rows and sentences in the caller's
// order; the list draws them as given and decides only how many page
// chips fit on each row's one line. It is shown in a sheet, in Search's
// details and opened in place on the results screen, the same each time.

/// What the list draws: the caller's sections and rows, each once, in
/// the caller's order. Pages are 0-based.
struct NotSearchedListContent: Equatable {
    /// The line naming the searches a section holds for: `shown` is drawn
    /// (a long name may be shortened), `spoken` has every name whole.
    struct NameLine: Equatable {
        let shown: String
        let spoken: String
    }

    /// One reason: its sentence, and the pages that sentence names, in
    /// page order.
    struct Row: Equatable {
        let sentence: String
        let pages: [Int]
    }

    struct Section: Equatable {
        let nameLine: NameLine?
        let rows: [Row]
    }

    let sections: [Section]
    let smallPicturesLine: String?
}

/// One drawn item of the list, in drawing order.
enum NotSearchedListItem: Equatable {
    case header
    case nameLine(NotSearchedListContent.NameLine)
    case row(NotSearchedListContent.Row, hairlineAbove: Bool)
    case smallPictures(String)
}

struct NotSearchedList: View {
    let content: NotSearchedListContent
    let showsHeader: Bool
    let goToPage: (Int) -> Void

    /// A search name longer than this is shown as its first `limit - 1`
    /// characters and an ellipsis, where the rule allows.
    static let shownNameLimit = 40
    /// The space between two chips, and between the last chip and the count.
    static let chipGap = 8
    /// The most chips a row draws.
    static let chipCap = ResectaTokens.Results.chipCap
    static let header = "Not Searched"

    /// How many chips a row draws, and the count of the rest when it is
    /// drawn (`more` is nil when no count is drawn).
    struct ChipLine: Equatable {
        let shown: Int
        let more: Int?
    }

    // MARK: - The items

    /// The list's items: the header when asked for, then each section's
    /// naming line and rows, then the small-pictures line. Nothing is
    /// added, dropped, reordered or sorted. A content with no row and no
    /// small-pictures line gives no items.
    static func items(for content: NotSearchedListContent, showsHeader: Bool) -> [NotSearchedListItem] {
        let hasRow = content.sections.contains { !$0.rows.isEmpty }
        guard hasRow || content.smallPicturesLine != nil else { return [] }
        var items: [NotSearchedListItem] = showsHeader ? [.header] : []
        for section in content.sections {
            if let nameLine = section.nameLine {
                items.append(.nameLine(nameLine))
            }
            for (index, row) in section.rows.enumerated() {
                // Hairlines stand between the rows of one section only.
                items.append(.row(row, hairlineAbove: index > 0))
            }
        }
        if let line = content.smallPicturesLine {
            items.append(.smallPictures(line))
        }
        return items
    }

    // MARK: - A shortened name

    /// A search name as a naming line shows it: longer than the limit, its
    /// first `limit - 1` characters and "…"; otherwise whole. Shown whole
    /// whatever its length when its section offers no button, or when
    /// another name on the list would be shown the same way. Counted in
    /// characters as a person sees them, not in scalars.
    static func shownName(_ name: String, sectionHasButton: Bool, otherNames: [String]) -> String {
        guard sectionHasButton, name.count > shownNameLimit else { return name }
        let short = Self.shortened(name)
        let clashes = otherNames.contains { $0 != name && $0.count > shownNameLimit && Self.shortened($0) == short }
        return clashes ? name : short
    }

    private static func shortened(_ name: String) -> String {
        String(name.prefix(shownNameLimit - 1)) + "\u{2026}"
    }

    // MARK: - The chip line

    /// How many chips fit on one line of `available` points, in whole
    /// points: each chip's width and the count's width rounded up, the
    /// line rounded down, so a rounding error can only show fewer chips.
    /// `chipWidths` holds one width per page; only the first `chipCap` are
    /// read. All the chips when they number five or fewer and fit; else,
    /// of the k that fit (at most five), the first k − 1 and the count of
    /// the rest, fewer again if the count does not fit beside them; when
    /// the count fits beside no chip, the chips that fit and no count.
    static func chipLine(chipWidths: [Int], moreWidth: Int, available: Int) -> ChipLine {
        let pages = chipWidths.count
        func width(of k: Int) -> Int {
            chipWidths.prefix(k).reduce(0, +) + chipGap * max(0, k - 1)
        }
        var fit = 0
        for k in stride(from: min(pages, chipCap), through: 1, by: -1) where width(of: k) <= available {
            fit = k
            break
        }
        guard fit > 0 else { return ChipLine(shown: 0, more: nil) }
        guard fit < pages else { return ChipLine(shown: fit, more: nil) }
        for shown in stride(from: fit - 1, through: 1, by: -1)
        where width(of: shown) + chipGap + moreWidth <= available {
            return ChipLine(shown: shown, more: pages - shown)
        }
        return ChipLine(shown: fit, more: nil)
    }

    /// The count of the pages without a chip, in the results screen's words.
    static func moreText(_ count: Int) -> String {
        "+\(count)\u{00A0}more"
    }

    /// A chip's tap: the caller's closure, with the chip's 0-based page.
    static func chipAction(page: Int, goToPage: @escaping (Int) -> Void) -> () -> Void {
        { goToPage(page) }
    }

    // MARK: - The view

    var body: some View {
        let items = Self.items(for: content, showsHeader: showsHeader)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                itemView(item, isFirst: index == 0)
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: NotSearchedListItem, isFirst: Bool) -> some View {
        switch item {
        case .header:
            Text(Self.header)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
        case .nameLine(let line):
            Text(line.shown)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.top, isFirst ? 0 : 6)
                .accessibilityLabel(line.spoken)
        case .row(let row, let hairlineAbove):
            VStack(alignment: .leading, spacing: 0) {
                if hairlineAbove { NotSearchedHairline() }
                NotSearchedRow(row: row, goToPage: goToPage)
            }
        case .smallPictures(let line):
            VStack(alignment: .leading, spacing: 0) {
                if !isFirst { NotSearchedHairline() }
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .padding(.vertical, 10)
            }
        }
    }
}

private struct NotSearchedHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

/// One reason: the caution mark, the sentence, and under it the page
/// chips that fit on one line.
private struct NotSearchedRow: View {
    let row: NotSearchedListContent.Row
    let goToPage: (Int) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var markBox: CGFloat = 20
    @ScaledMetric(relativeTo: .subheadline) private var markSize: CGFloat = 16
    @State private var available: CGFloat = 0
    @State private var chipWidths: [Int: CGFloat] = [:]
    @State private var moreWidth: CGFloat = 0

    private var candidates: [Int] { Array(row.pages.prefix(NotSearchedList.chipCap)) }

    private var line: NotSearchedList.ChipLine {
        let widths = row.pages.indices.map { index in
            index < candidates.count ? Int((chipWidths[index] ?? 0).rounded(.up)) : 0
        }
        return NotSearchedList.chipLine(chipWidths: widths, moreWidth: Int(moreWidth.rounded(.up)),
                                        available: Int(available.rounded(.down)))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: markSize))
                .foregroundStyle(ResectaTokens.Ink.cautionMark)
                .frame(width: markBox, height: markBox)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(row.sentence)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
                if !row.pages.isEmpty {
                    chips
                }
            }
        }
        .padding(.vertical, 9)
        .background(alignment: .topLeading) { measures }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var chips: some View {
        let line = self.line
        if line.shown > 0 {
            HStack(spacing: CGFloat(NotSearchedList.chipGap)) {
                ForEach(row.pages.prefix(line.shown), id: \.self) { page in
                    PageChip(pageIndex: page, action: NotSearchedList.chipAction(page: page, goToPage: goToPage))
                }
                if let more = line.more {
                    Text(NotSearchedList.moreText(more))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                        .frame(minHeight: ResectaTokens.Results.chipHeight)
                }
            }
            .fixedSize()
        }
    }

    /// Hidden copies of the candidate chips and of the widest count, each
    /// measured where it would be drawn. Never drawn, never spoken.
    private var measures: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { index, page in
                PageChip(pageIndex: page) {}
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidths[index] = $0 }
            }
            Text(NotSearchedList.moreText(row.pages.count))
                .font(.footnote.weight(.semibold))
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { moreWidth = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
    }
}
