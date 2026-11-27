import Foundation
import Testing
@testable import RedactionEngine
@testable import ResectaApp

// The statement function against the table written by hand from the
// sentences before the function existed (Fixtures/SearchStatementTable.md).
// A difference is settled against the sentences, never by rewriting the
// table from the function. Pages in the table are one-based.

@Suite("Search statement: the table")
struct SearchStatementTableTests {

    /// The key's sixteen documents, ten pages each, built from the facts the
    /// searcher and the app's two signals give. Indices are zero-based.
    static func account(_ summary: String) -> SearchAccount {
        typealias F = AccountOfWhatWasRead.Facts
        var pages = [F](repeating: [.ownText], count: 10)
        var ending = SearchAccount.Ending.completed
        switch summary {
        case "S1": break
        case "S2": pages[3] = [.recognised]; pages[6] = [.recognised]
        case "S3": pages[3] = [.unopenable]
        case "S4": pages[3] = [.recognitionFailed]
        case "S5": pages[3] = [.emptyReadWithInk]
        case "S6": pages[3] = [.tooLarge]
        case "S7": pages[3] = [.recognitionOff]
        case "S8": pages[3] = [.ownText, .picturesRequired, .recognitionOff]
        case "S9": pages[3] = [.ownText, .patternTimedOut]
        case "S10": for page in 4...9 { pages[page] = [] }; ending = .stoppedAtResultLimit(page: 3)
        case "S11": for page in 4...9 { pages[page] = [] }; ending = .stopped(page: 3)
        case "S12": for page in [1, 4, 7] { pages[page] = [.ownText, .smallPictures] }
        case "S13":
            pages[2] = [.unopenable]; pages[5] = [.recognitionOff]; pages[1] = [.ownText, .smallPictures]
            pages[8] = []; pages[9] = []; ending = .stopped(page: 7)
        case "S14": pages[3] = [.recognised]; pages[6] = [.recognised]; pages[1] = [.ownText, .smallPictures]
        case "S15": pages[3] = [.recognised]; pages[6] = [.recognised]; pages[8] = [.recognitionFailed]
        case "S16": pages[1] = [.recognised]; pages[2] = [.recognised]; pages[8] = []; pages[9] = []; ending = .stopped(page: 7)
        default: Issue.record("no such summary \(summary)")
        }
        var account = SearchAccount(pageCount: 10)
        for (page, facts) in pages.enumerated() { account.record(facts, forPage: page) }
        account.end(ending)
        return account
    }

    static func mode(_ key: String) -> SearchModeType {
        switch key {
        case "M1": .text
        case "M2", "M3": .multiTerm
        case "M4": .regex
        default: .piiScan
        }
    }

    // MARK: - The table's spelling of a statement

    static func pagesText(_ pages: [Int]) -> String {
        let shown = pages.map { $0 + 1 }
        guard let first = shown.first, let last = shown.last else { return "no page" }
        if shown.count == 1 { return "page \(first)" }
        if shown == Array(first...last) { return "pages \(first)-\(last)" }
        return "pages " + shown.dropLast().map(String.init).joined(separator: ", ") + " and \(last)"
    }

    static func causeText(_ cause: SearchAccount.PictureCause) -> String {
        switch cause {
        case .recognitionFailed: "recognition failed"
        case .recognitionFoundNoText: "recognition found no text"
        case .tooLarge: "too large"
        case .recognitionOff: "recognition off"
        case .notReported: "not reported"
        }
    }

    static func lineText(_ line: SearchStatement.Line) -> String {
        let banner = " (the line is today's banner)"
        switch line.reason {
        case .couldNotBeOpened: return "could not be opened, \(line.count), \(pagesText(line.pages))"
        case .recognitionFailed: return "recognition failed, \(line.count), \(pagesText(line.pages))"
        case .recognitionFoundNoText: return "recognition found no text, \(line.count), \(pagesText(line.pages))"
        case .tooLarge: return "too large, \(line.count), \(pagesText(line.pages))" + banner
        case .recognitionOff: return "recognition off, \(line.count), \(pagesText(line.pages))"
        case .picturesNotRead(let cause):
            return "pictures not read (cause: \(causeText(cause))), \(line.count), \(pagesText(line.pages))"
        case .patternTimedOut: return "the pattern ran out of time, \(line.count), \(pagesText(line.pages))" + banner
        case .noReport: return "no report, \(line.count), \(pagesText(line.pages))"
        case .notReached:
            let stop = (line.stopPage ?? -1) + 1
            let text = "not reached, \(line.count), \(pagesText(line.pages)); page \(stop) searched in part; "
                + (line.atResultLimit ? "the result limit" : "stopped")
            return line.atResultLimit ? text + " (the line is today's result-limit notice, shown once)" : text
        }
    }

    static func headlineText(_ headline: SearchStatement.Headline?) -> String {
        switch headline {
        case nil: "NONE"
        case .plain: "PLAIN"
        case .lead: "LEAD"
        case .qualified(let n): "QUALIFIED \(n)"
        case .stopped: "STOPPED"
        case .stoppedWithRecognition(let n): "STOPPED \(n)"
        }
    }

    static func tableRows() throws -> [[String]] {
        let url = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SearchStatementTable.md")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Row ") }
            .map { $0.split(separator: "|", omittingEmptySubsequences: false).dropFirst().map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    @Test("Every row of the table: the headline, the lines in order and the quiet line")
    func table() throws {
        let rows = try Self.tableRows()
        #expect(rows.count == 160)
        #expect(rows.map { Int($0[0]) } == (1...160).map { Optional($0) })
        for row in rows {
            let statement = SearchStatement.statement(
                mode: Self.mode(row[1]), hasResults: row[2] == "R3", account: Self.account(row[3]), hiddenCount: 0)
            let lines = statement.lines.map(Self.lineText).joined(separator: "; then ")
            #expect(Self.headlineText(statement.headline) == row[4], "row \(row[0]) headline")
            #expect((lines.isEmpty ? "none" : lines) == row[5], "row \(row[0]) lines")
            #expect((statement.quietCount.map(String.init) ?? "none") == row[6], "row \(row[0]) quiet line")
            #expect(statement.hiddenCount == nil, "row \(row[0]): no filter hides a result in the table")
        }
    }
}
