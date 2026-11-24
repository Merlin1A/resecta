import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The results screen's lines about what the run made and what it did not
// read before Redact: each builder's exact words, the order, each line's
// gate (its fact, the output on disk, the report's checks), the two page
// counts read from the closed runs, and a finished run that records them.

@Suite("Results run lines")
@MainActor
struct ResultsRunLinesTests {

    typealias Strip = VerificationResultsView.RunFactsStrip
    typealias Facts = VerificationResultsView.RunFacts
    typealias PageFacts = AccountOfWhatWasRead.Facts

    static func layer(_ status: VerificationStatus, couldNotVerify: Bool = false,
                      couldNotVerifyPart: String? = nil, stopped: CheckStop? = nil) -> LayerResult {
        LayerResult(name: "Check", symbolName: "checkmark", status: status, shortDescription: "",
                    detailDescription: "", pageReferences: nil, durationSeconds: 0,
                    couldNotVerify: couldNotVerify,
                    couldNotVerifyPart: couldNotVerifyPart, couldNotVerifyPartPages: couldNotVerifyPart.map { _ in [] },
                    stopped: stopped)
    }

    static func report(_ layers: [LayerResult], _ overall: VerificationStatus = .pass) -> VerificationReport {
        VerificationReport(layers: layers, overallStatus: overall, durationSeconds: 0)
    }

    static let clean = report([layer(.pass), layer(.pass)])

    // MARK: - Each builder's words

    @Test("Each line's words, in every form")
    func words() {
        let rows: [(String, String)] = [
            (Strip.boxesLine(count: 1), "1 box can still show how long its text is."),
            (Strip.boxesLine(count: 19), "19 boxes can still show how long their text is."),
            (Strip.sizeLine(bytes: 38_200_000), "This PDF is 38.2 MB."),
            (Strip.longImageOnlyLine(pages: 140),
             "This PDF has 140 pages and no text, so an AI assistant that reads only the text of a PDF this long will read nothing of it."),
            (Strip.notSearchedInFullLine(pages: 1), "Before Redact, 1 page was not searched in full."),
            (Strip.notSearchedInFullLine(pages: 12), "Before Redact, 12 pages were not searched in full."),
            (Strip.smallPicturesLine(pages: 1),
             "Small pictures on 1 page, such as logos and stamps, were not searched. A name inside a logo or stamp is not found."),
            (Strip.smallPicturesLine(pages: 38),
             "Small pictures on 38 pages, such as logos and stamps, were not searched. A name inside a logo or stamp is not found."),
            (Strip.checksRanLine(pages: 1), "The checks then ran on the page, looking for your boxed text."),
            (Strip.checksRanLine(pages: 2), "The checks then ran on both pages, looking for your boxed text."),
            (Strip.checksRanLine(pages: 3), "The checks then ran on all 3 pages, looking for your boxed text."),
            (Strip.checksRanLine(pages: 48), "The checks then ran on all 48 pages, looking for your boxed text."),
        ]
        for (built, approved) in rows { #expect(built == approved) }
        #expect(ResultsScopeNote.checksPassedSentences(outputExists: true) == [
            "Checks Passed means no check reported your boxed text in this PDF.",
            "In this version the checks do not show that they read every part of the file.",
            "What remains can still identify someone.",
        ])
    }

    // MARK: - The strip's order and gates

    @Test("No fact, no line, whatever the report and the output")
    func noFactNoLine() {
        for report in [Self.clean, .skipped] {
            for exists in [false, true] {
                #expect(Strip.lines(for: Facts(), report: report, outputExists: exists).isEmpty)
            }
        }
    }

    @Test("Every fact on: the lines in their order")
    func order() {
        let facts = Facts(ocrSkippedPages: [0], degradeFailures: ["NameGazetteer"], runMode: .secure,
                          pageCount: 81, burnedBoxes: 19, outputBytes: 38_200_000,
                          pagesNotSearchedInFull: [0, 4], smallPicturePages: [1, 2, 3])
        #expect(Strip.lines(for: facts, report: Self.clean, outputExists: true) == [
            Strip.ocrSkipLine(pages: [0]),
            Strip.degradeLine(failedGazetteers: ["NameGazetteer"]),
            Strip.boxesLine(count: 19),
            Strip.sizeLine(bytes: 38_200_000),
            Strip.longImageOnlyLine(pages: 81),
            Strip.notSearchedInFullLine(pages: 2),
            Strip.smallPicturesLine(pages: 3),
            Strip.checksRanLine(pages: 81),
        ])
    }

    @Test("The boxes line counts the burned boxes and needs one; it does not need the output")
    func boxesGate() {
        #expect(Strip.lines(for: Facts(burnedBoxes: 0)).isEmpty)
        #expect(Strip.lines(for: Facts(burnedBoxes: 1)) == [Strip.boxesLine(count: 1)])
        #expect(Strip.lines(for: Facts(burnedBoxes: 3), outputExists: true) == [Strip.boxesLine(count: 3)])
    }

    @Test("The size line needs the recorded size and the output on disk")
    func sizeGate() {
        #expect(Strip.lines(for: Facts(outputBytes: 1_000), outputExists: false).isEmpty)
        #expect(Strip.lines(for: Facts(outputBytes: nil), outputExists: true).isEmpty)
        #expect(Strip.lines(for: Facts(outputBytes: 1_000), outputExists: true) == [Strip.sizeLine(bytes: 1_000)])
    }

    @Test("The long image-only line: Secure, more than 80 pages, and the output on disk")
    func longImageOnlyGate() {
        let rows: [(VerificationResultsView.RunMode, Int, Bool, Bool)] = [
            (.secure, 81, true, true), (.secure, 80, true, false), (.secure, 140, false, false),
            (.searchableOrUnknown, 140, true, false),
        ]
        for (mode, pages, exists, shows) in rows {
            let lines = Strip.lines(for: Facts(runMode: mode, pageCount: pages), outputExists: exists)
            #expect(lines == (shows ? [Strip.longImageOnlyLine(pages: pages)] : []), "\(mode) \(pages) \(exists)")
        }
    }

    @Test("The unread pages: each count's line alone, both together, a page in both")
    func unreadLines() {
        #expect(Strip.unreadLines(for: Facts(pagesNotSearchedInFull: [3]), report: nil)
                == [Strip.notSearchedInFullLine(pages: 1)])
        #expect(Strip.unreadLines(for: Facts(smallPicturePages: [3, 5]), report: nil)
                == [Strip.smallPicturesLine(pages: 2)])
        #expect(Strip.unreadLines(for: Facts(pagesNotSearchedInFull: [3, 5], smallPicturePages: [5]), report: nil)
                == [Strip.notSearchedInFullLine(pages: 2), Strip.smallPicturesLine(pages: 1)])
    }

    @Test("What the checks ran on follows an unread line, by the output's page count, only after checks that ran to the end")
    func checksRanGate() {
        let unread = Facts(pageCount: 2, pagesNotSearchedInFull: [0])
        #expect(Strip.unreadLines(for: unread, report: Self.clean).last == Strip.checksRanLine(pages: 2))
        #expect(Strip.unreadLines(for: Facts(pageCount: 1, smallPicturePages: [0]), report: Self.clean)
                == [Strip.smallPicturesLine(pages: 1), Strip.checksRanLine(pages: 1)])
        // No unread line, no line about what the checks then ran on.
        #expect(Strip.unreadLines(for: Facts(pageCount: 48), report: Self.clean).isEmpty)
        // No report, a skipped report, a report with an issue: none.
        for report in [nil, VerificationReport.skipped, Self.report([Self.layer(.pass), Self.layer(.fail("x"))], .fail("x"))] {
            #expect(Strip.unreadLines(for: unread, report: report) == [Strip.notSearchedInFullLine(pages: 1)])
        }
        // No pages recorded: none.
        #expect(Strip.unreadLines(for: Facts(pagesNotSearchedInFull: [0]), report: Self.clean)
                == [Strip.notSearchedInFullLine(pages: 1)])
    }

    @Test("Checks that ran to the end: every row passed, a note or not applicable, none skipped, short of its input or stopped")
    func checksRanToTheEnd() {
        let rows: [(LayerResult, Bool)] = [
            (Self.layer(.pass), true), (Self.layer(.info("n")), true), (Self.layer(.notApplicable("n")), true),
            (Self.layer(.warn("w")), false), (Self.layer(.attention("a")), false), (Self.layer(.fail("f")), false),
            (Self.layer(.skipped), false),
            (Self.layer(.pass, couldNotVerify: true), false),
            (Self.layer(.pass, couldNotVerifyPart: "part"), false),
            (Self.layer(.pass, stopped: .formFieldsNotRead), false),
            (Self.layer(.pass, stopped: .exifSearchStopped(page: 2)), false),
        ]
        for (row, ran) in rows {
            #expect(Strip.checksRanToTheEnd(Self.report([Self.layer(.pass), row])) == ran,
                    "\(row.status) couldNotVerify=\(row.couldNotVerify) stopped=\(String(describing: row.stopped))")
        }
        #expect(!Strip.checksRanToTheEnd(.skipped), "no rows: no checks ran")
    }

    @Test("The scope note's sentences need the output on disk, and show only on Checks Passed")
    func scopeNoteGate() {
        #expect(ResultsScopeNote.checksPassedSentences(outputExists: false).isEmpty)
        let sentences = ResultsScopeNote.checksPassedSentences(outputExists: true)
        #expect(ResultsScopeNote.paragraph(report: Self.clean, sentences: sentences)
                == sentences.joined(separator: " "))
        #expect(ResultsScopeNote.paragraph(report: Self.report([Self.layer(.fail("f"))], .fail("f")),
                                           sentences: sentences) == nil)
    }

    // MARK: - The facts, from the run's inputs

    @Test("derive: the burned boxes on every page, the pages, the size and the unread pages are carried")
    func deriveCarriesTheFacts() {
        var inputs = RedactionState.LastRunInputs.fixture(
            perPageModes: Array(repeating: .secureRasterization, count: 3))
        inputs.burnedRegions = [0: [.mock(), .mock()], 2: [.mock()]]
        inputs.outputBytes = 512
        inputs.pagesNotSearchedInFull = [1]
        inputs.smallPicturePages = [0, 2]
        let facts = Facts.derive(inputs: inputs)
        #expect(facts.burnedBoxes == 3)
        #expect(facts.pageCount == 3)
        #expect(facts.outputBytes == 512)
        #expect(facts.pagesNotSearchedInFull == [1])
        #expect(facts.smallPicturePages == [0, 2])
        // Inputs built by hand carry no burned boxes: no line, no live fallback.
        #expect(Facts.derive(inputs: .fixture()).burnedBoxes == 0)
    }

    // MARK: - The two page counts, from the closed runs

    static func account(_ pages: [PageFacts], recognitionOff: Set<Int> = []) -> SearchAccount {
        var account = SearchAccount(pageCount: pages.count)
        for (page, facts) in pages.enumerated() { account.record(facts, forPage: page) }
        for page in recognitionOff { account.recordRecognitionOff(page: page) }
        account.end(.completed)
        return account
    }

    static func text(_ text: String) -> AppliedSearchQuery {
        AppliedSearchQuery(kind: .text(text), options: SearchOptions())
    }

    @Test("A page named for two reasons, or for two texts, counts once")
    func namedPagesCountOnce() {
        let first = Self.account([[.ownText], [.ownText, .patternTimedOut], []], recognitionOff: [2])
        let second = Self.account([[.ownText], [.ownText], []], recognitionOff: [2])
        let runs: [RedactStop.Run] = [(Self.text("Delia"), first), (Self.text("Brook"), second)]
        #expect(RedactStop.namedPages(runs: runs, answered: []).count > 2, "the stop names page 3 for two texts")
        #expect(RedactStop.pagesNotSearchedInFull(runs: runs) == [1, 2])
    }

    @Test("An answered page still counts as not searched in full")
    func answeredPagesCount() {
        let runs: [RedactStop.Run] = [(Self.text("Delia"), Self.account([[.ownText], []], recognitionOff: [1]))]
        let named = RedactStop.namedPages(runs: runs, answered: [])
        #expect(RedactStop.namedPages(runs: runs, answered: named).isEmpty, "every page answered")
        #expect(RedactStop.pagesNotSearchedInFull(runs: runs) == [1])
    }

    @Test("Small pictures: a page whose only gap they are counts; one a later run read in full, or with another gap, does not")
    func smallPicturePages() {
        let earlier = Self.account([[.ownText, .smallPictures], [.ownText, .smallPictures], [.ownText]])
        let later = Self.account([[.ownText, .smallPictures], [.recognised], [.ownText]])
        #expect(RedactStop.smallPicturePages(runs: [(Self.text("Delia"), earlier)]) == [0, 1])
        #expect(RedactStop.smallPicturePages(runs: [(Self.text("Delia"), earlier), (Self.text("Delia"), later)]) == [0],
                "page 2 was read in full by the later run")
        let otherGap = Self.account([[.ownText, .smallPictures], []], recognitionOff: [1])
        #expect(RedactStop.smallPicturePages(runs: [(Self.text("Delia"), otherGap)]) == [0])
        #expect(RedactStop.smallPicturePages(runs: []).isEmpty)
    }

    // MARK: - A finished run records them

    @Test("A finished run records the unread pages from its closed runs, answered pages too, and the size of the file it made",
          .timeLimit(.minutes(3)))
    func finishedRunRecordsTheFacts() async throws {
        let coord = makeLoadedCoordinator()
        let token = UUID()
        coord.redactionState.recordSearchRunOpened(token: token, query: Self.text("Delia"))
        coord.redactionState.recordSearchAccount(
            Self.account([[.ownText], [.ownText, .smallPictures], []], recognitionOff: [2]), token: token)
        // Page 3 answered before the run, as Redact Anyway answers it: it was
        // still not searched in full.
        coord.redactionState.answerRedactStop([RedactStop.Page(page: 2, reason: .line(.recognitionOff))])
        coord.redactionState.addRegion(RunRecordTests.region(CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.05)),
                                       page: 0, undoManager: nil)
        coord.runFullPipeline(documentOverride: .secureRasterization)
        let run = try #require(coord.documentState.activePipelineTask, "the run started")
        await run.value
        let output = try #require(coord.redactionState.outputURL, "the run made an output")
        let inputs = try #require(coord.redactionState.lastRunInputs)
        #expect(inputs.pagesNotSearchedInFull == [2])
        #expect(inputs.smallPicturePages == [1])
        let size = try #require(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)
        #expect(inputs.outputBytes == size.int64Value)
        #expect(Facts.derive(inputs: inputs).burnedBoxes == 1)
    }
}
