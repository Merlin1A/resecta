import SwiftUI

// The stop at Redact: one sheet, raised when pages a search did not read
// are not yet answered for. It draws the list the state gives it and the
// choices; the state decides when it shows and what each answer does.

/// An answer to the stop at Redact.
enum BeforeYouRedactAnswer: Equatable {
    case redactAnyway
    /// The re-run of a group the sheet shows, as the state gave it.
    case searchThesePages(AppliedSearchQuery)
    case cancel
    /// The sheet swiped down: the same as Cancel.
    case swipedDown
    /// A page chip: Cancel, then the page (0-based).
    case goToPage(Int)
}

struct BeforeYouRedactSheet: View {

    // MARK: - Words

    static let title = "Before You Redact"
    static let searchThesePagesTitle = "Search These Pages"
    static let redactAnywayTitle = "Redact Anyway"
    static let cancelTitle = "Cancel"
    /// Drawn under Redact Anyway, and its spoken hint.
    static let redactAnywayPromise =
        "If you redact anyway, Resecta will not ask again about the same pages for the same reasons while this document is open."

    // MARK: - The choices

    enum Capsule: Equatable {
        case searchThesePages, redactAnyway, cancel
    }

    enum CapsuleStyle: Equatable {
        case tealSolid, outlined, plain
    }

    struct Choice: Equatable {
        let capsule: Capsule
        let style: CapsuleStyle
    }

    /// The choices in drawn order. Exactly one is solid teal, the safest way
    /// forward, and it is never Redact Anyway: Search These Pages when the
    /// state offers the re-run, else Cancel.
    static func choices(offersSearchThesePages: Bool) -> [Choice] {
        if offersSearchThesePages {
            return [Choice(capsule: .searchThesePages, style: .tealSolid),
                    Choice(capsule: .redactAnyway, style: .outlined),
                    Choice(capsule: .cancel, style: .plain)]
        }
        return [Choice(capsule: .redactAnyway, style: .outlined),
                Choice(capsule: .cancel, style: .tealSolid)]
    }

    // MARK: - What an answer does

    struct Effects: Equatable {
        /// The pages and reasons are recorded as answered.
        let records: Bool
        /// The stop's case no longer awaits an answer.
        let clearsCase: Bool
        /// The run funnel is entered again, after any record.
        let entersRun: Bool
        /// Search opens on the state's re-run, at medium.
        let opensSearch: Bool
        /// The page shown afterwards (0-based), if any.
        let showsPage: Int?
    }

    /// Only Redact Anyway records an answer. A swipe down is Cancel; Go to
    /// page is Cancel and then the page.
    static func effects(of answer: BeforeYouRedactAnswer) -> Effects {
        switch answer {
        case .redactAnyway:
            return Effects(records: true, clearsCase: true, entersRun: true, opensSearch: false, showsPage: nil)
        case .searchThesePages:
            return Effects(records: false, clearsCase: true, entersRun: false, opensSearch: true, showsPage: nil)
        case .cancel, .swipedDown:
            return Effects(records: false, clearsCase: true, entersRun: false, opensSearch: false, showsPage: nil)
        case .goToPage(let page):
            return Effects(records: false, clearsCase: true, entersRun: false, opensSearch: false, showsPage: page)
        }
    }

    // MARK: - Height

    /// The sheet takes its content's height up to the screen's; at the
    /// accessibility text sizes, or when the content does not fit, it opens
    /// at full height, and it scrolls.
    static func stopSheetDetent(
        contentHeight: CGFloat, availableHeight: CGFloat, isAccessibilitySize: Bool
    ) -> PresentationDetent {
        guard !isAccessibilitySize, contentHeight > 0, contentHeight <= availableHeight else { return .large }
        return .height(contentHeight)
    }

    // MARK: - The view

    let content: NotSearchedListContent
    /// The run Search These Pages starts; nil when the sheet offers none.
    let reRun: AppliedSearchQuery?
    let captureMonitor: ScreenCaptureMonitor
    let onAnswer: (BeforeYouRedactAnswer) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var contentHeight: CGFloat = 0
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        GeometryReader { screen in
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(ResectaTokens.Ink.cautionMark)
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    Text(Self.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)
                    NotSearchedList(content: content, showsHeader: true, goToPage: { onAnswer(.goToPage($0)) })
                        .padding(.top, 16)
                    VStack(spacing: 10) {
                        ForEach(Self.choices(offersSearchThesePages: reRun != nil), id: \.capsule) { choice in
                            capsuleButton(choice)
                        }
                    }
                    .padding(.top, 22)
                }
                .padding(.top, 26)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .background(GeometryReader { measured in
                    Color.clear.preference(key: StopContentHeightKey.self, value: measured.size.height)
                })
            }
            .onPreferenceChange(StopContentHeightKey.self) { contentHeight = $0 }
            .presentationDetents([Self.stopSheetDetent(
                contentHeight: contentHeight, availableHeight: screen.size.height,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)])
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("beforeYouRedactSheet")
        .accessibilityAction(.escape) { onAnswer(.cancel) }
        .onAppear { titleFocused = true }
        .shieldedSheetContent(monitor: captureMonitor)
    }

    @ViewBuilder
    private func capsuleButton(_ choice: Choice) -> some View {
        switch choice.capsule {
        case .searchThesePages:
            capsule(Self.searchThesePagesTitle, style: choice.style, identifier: "beforeYouRedactSearchThesePages") {
                if let reRun { onAnswer(.searchThesePages(reRun)) }
            }
        case .redactAnyway:
            VStack(spacing: 0) {
                capsule(Self.redactAnywayTitle, style: choice.style, identifier: "beforeYouRedactRedactAnyway") {
                    onAnswer(.redactAnyway)
                }
                .accessibilityHint(Self.redactAnywayPromise)
                Text(Self.redactAnywayPromise)
                    .font(.caption)
                    .foregroundStyle(ResectaTokens.SemanticColor.supportText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
                    .accessibilityHidden(true)
            }
        case .cancel:
            capsule(Self.cancelTitle, style: choice.style, identifier: "beforeYouRedactCancel") {
                onAnswer(.cancel)
            }
        }
    }

    private func capsule(
        _ title: String, style: CapsuleStyle, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(style == .tealSolid ? Color.white : Color.primary)
                .background {
                    switch style {
                    case .tealSolid:
                        RoundedRectangle(cornerRadius: 25).fill(ResectaTokens.BrandTeal.fill)
                    case .outlined:
                        RoundedRectangle(cornerRadius: 25).strokeBorder(Color.primary, lineWidth: 1.5)
                    case .plain:
                        RoundedRectangle(cornerRadius: 25).fill(Color(uiColor: .tertiarySystemFill))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 25))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

private struct StopContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - What the sheet shows

/// The words the stop's list is drawn in, passed in by the caller: the
/// Search sheet's line sentences and the stop's own name line.
struct BeforeYouRedactWords {
    /// The name line for a section's searches, in the order they were first
    /// run; `withOptions` holds the texts whose names also say their options.
    let nameLine: (_ names: [RedactStopUnit], _ withOptions: Set<RedactStop.NamedText>) -> NotSearchedListContent.NameLine
    /// The sentence of one row: a reason, its pages and how its runs ended.
    let row: (_ group: RedactStop.Group, _ names: [RedactStopUnit]) -> String
}

/// The sheet's content and the run its first choice starts.
struct BeforeYouRedactStop: Equatable {
    let content: NotSearchedListContent
    /// Nil when no group the sheet shows has a re-run.
    let reRun: AppliedSearchQuery?
}

extension BeforeYouRedactSheet {

    /// What the stop shows for its case: only the pages and reasons the case
    /// carries, grouped as the state groups them. A section holds the groups
    /// of one set of searches, the one with no name first; its rows keep the
    /// reasons' order. Search These Pages is offered only for a group shown.
    static func stop(casePages: Set<RedactStop.Page>, runs: [RedactStop.Run],
                     answered: Set<RedactStop.Page>, words: BeforeYouRedactWords) -> BeforeYouRedactStop {
        var shown: [RedactStop.Group] = []
        for group in RedactStop.groups(runs: runs, answered: answered) {
            let pages = group.pages.filter { casePages.contains(RedactStop.Page(page: $0, reason: group.reason)) }
            guard !pages.isEmpty else { continue }
            shown.append(RedactStop.Group(reason: group.reason, units: group.units, pages: pages,
                                          notReachedEnding: group.notReachedEnding))
        }
        let withOptions = RedactStop.textsNamedWithOptions(shown)
        var named: [Set<RedactStopUnit>] = []
        for group in shown { if let units = group.units, !named.contains(units) { named.append(units) } }
        let sets: [Set<RedactStopUnit>?] = (shown.contains { $0.units == nil } ? [nil] : []) + named.map { Optional($0) }
        let sections = sets.map { units -> NotSearchedListContent.Section in
            let groups = shown.filter { $0.units == units }
            let names = RedactStop.names(of: groups[0], runs: runs)
            return NotSearchedListContent.Section(
                nameLine: units == nil ? nil : words.nameLine(names, withOptions),
                rows: groups.map { NotSearchedListContent.Row(sentence: words.row($0, names), pages: $0.pages) })
        }
        let reRun = shown.lazy.compactMap { RedactStop.reRun(for: $0, runs: runs) }.first
        return BeforeYouRedactStop(content: NotSearchedListContent(sections: sections, smallPicturesLine: nil), reRun: reRun)
    }
}
