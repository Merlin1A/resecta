import Foundation

// What the notice place remembers for the session, and the facts it reads.
// Kept on the search state, not in a view: the results section is unmounted
// whenever the sheet is parked, so a view's own state would be lost there.

struct SearchNoticeState: Equatable {
    /// The lines shown while a run is in progress: those that held when it
    /// started.
    var held: [SearchNoticeLine] = []
    /// The notices already spoken (`SearchNoticeLine.key`).
    var announced: Set<String> = []
    /// The notices the person folded to their first sentence.
    var folded: Set<String> = []

    /// The state a run starts with: the lines that held when it started,
    /// or, when a run was cut short by this one, the lines it was holding.
    /// What was spoken and folded stays.
    func heldForNextRun(lines: [SearchNoticeLine], wasSearching: Bool) -> SearchNoticeState {
        SearchNoticeState(held: wasSearching ? held : lines, announced: announced, folded: folded)
    }

    /// Whether `line` is spoken now: once, when it first shows, never while
    /// held; again only when its sentence changes or the list was cleared.
    func shouldAnnounce(_ line: SearchNoticeLine, isHeld: Bool) -> Bool {
        !isHeld && !announced.contains(line.key)
    }
}

extension SearchState {
    /// The facts the place's lines are read from.
    var noticeFacts: SearchNoticePlace.Facts {
        var facts = SearchNoticePlace.Facts(
            tooLargePages: ocrSkippedPages, timedOutPages: regexTimeoutPages, atResultLimit: resultsAtCap,
            limitStopPage: capStopPage, unscannedPageCount: capUnscannedPageCount,
            interface: searchModeType.interface, widenedPages: widenedBoxPages)
        #if DEBUG
        if let seed = Self.noticeSeed, hasCompletedRunSinceClear || resultsAtCap {
            facts.tooLargePages.formUnion(seed.facts.tooLargePages)
            facts.timedOutPages.formUnion(seed.facts.timedOutPages)
            if seed.facts.atResultLimit {
                facts.atResultLimit = true
                facts.limitStopPage = seed.facts.limitStopPage
                facts.unscannedPageCount = seed.facts.unscannedPageCount
            }
        }
        #endif
        return facts
    }

    #if DEBUG
    /// `--uitestNoticeSeed=<facts>` (DEBUG builds only), facts separated by
    /// `;`: `tooLarge:<pages>`, `timedOut:<pages>` (0-based, separated by
    /// `,`), `limit:<stop page>/<total pages>` (1-based) and `degraded`. The
    /// seeded facts join the run's once a run has ended; `degraded` makes the
    /// degraded-detection line hold in Scan. It changes no state.
    nonisolated static var noticeSeed: (facts: SearchNoticePlace.Facts, degraded: Bool)? {
        noticeSeed(from: ProcessInfo.processInfo.arguments)
    }

    nonisolated static func noticeSeed(from arguments: [String]) -> (facts: SearchNoticePlace.Facts, degraded: Bool)? {
        let prefix = "--uitestNoticeSeed="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        var facts = SearchNoticePlace.Facts()
        var degraded = false
        for part in argument.dropFirst(prefix.count).split(separator: ";") {
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            let value = pieces.count > 1 ? pieces[1] : ""
            let pages = Set(value.split(separator: ",").compactMap { Int($0) })
            switch pieces[0] {
            case "tooLarge": facts.tooLargePages = pages
            case "timedOut": facts.timedOutPages = pages
            case "limit":
                let numbers = value.split(separator: "/").compactMap { Int($0) }
                guard numbers.count == 2 else { continue }
                facts.atResultLimit = true
                facts.limitStopPage = numbers[0]
                facts.unscannedPageCount = max(0, numbers[1] - numbers[0])
            case "degraded": degraded = true
            default: continue
            }
        }
        return (facts, degraded)
    }
    #endif
}
