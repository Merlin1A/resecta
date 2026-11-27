import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

/// The Findings group: one row per problem of the run, said once, with the
/// step to take and the checks behind it; and the list of checks as the
/// full record below it.
@MainActor
struct FindingRowTests {
    typealias Model = FindingRowModel
    typealias Problem = VerificationProblem
    typealias Section = VerificationDetailsSection
    typealias Fixtures = VerificationDebugFixtures

    static func layer(_ status: VerificationStatus, _ identity: VerificationLayer?, terms: [String]? = nil,
                      lines: [SearchRecheckQueryLine]? = nil, pages: [Int]? = nil, fragment: Bool = false,
                      cnv: Bool = false, short: String = "Short line.", part: String? = nil,
                      partPages: [Int]? = nil) -> LayerResult {
        LayerResult(name: identity?.name ?? "Page Count Check", symbolName: "shield", status: status,
                    shortDescription: short, detailDescription: "Detail line.", pageReferences: pages,
                    durationSeconds: 0, reviewTermTexts: terms, layer: identity, queryLines: lines,
                    couldNotVerify: cnv, reviewIsFragment: fragment, couldNotVerifyPart: part,
                    couldNotVerifyPartPages: partPages)
    }

    static func report(_ layers: [LayerResult], modes: [PipelineMode] = []) -> VerificationReport {
        VerificationReport(layers: layers, overallStatus: .attention("a"), durationSeconds: 0, perPageModes: modes)
    }

    static func search(_ label: String, remaining: Int) -> SearchRecheckQueryLine {
        SearchRecheckQueryLine(label: label, foundCount: remaining + 1, foundHitCap: false, appliedCount: 1,
                               remainingCount: remaining, route: .ocr)
    }

    static let sweepLine = SearchRecheckQueryLine(label: "Scan (17 detectors)", foundCount: 0, foundHitCap: false,
                                                  appliedCount: 0, remainingCount: 2, route: .ocr)

    /// The one problem of a report (and the inputs no check reports).
    static func only(_ report: VerificationReport, covered: [Int] = [], forms: Int = 0) throws -> Problem {
        let problems = VerificationProblemModel.derive(report: report, coveredPages: covered, formValueCount: forms)
        try #require(problems.count == 1, "\(problems.map(\.kind))")
        return problems[0]
    }

    // MARK: - Words by kind

    @Test("Each kind says its words: the new sentences as their rows read, the rest from the shipped functions")
    func wordsByKind() throws {
        // The new sentences, typed out from their rows in the strings table.
        #expect(Model.boxedTextReadable == "Text matching what you boxed is still readable.")
        #expect(Model.partOfBoxedText == "Part of boxed text is readable beside its box.")
        #expect(Model.searchesStillMatch(1) == "1 search still has matches.")
        #expect(Model.searchesStillMatch(2) == "2 searches still have matches.")
        #expect(Model.couldNotRunInFull(checks: 1, pages: [2]) == "1 check could not run in full on\u{00A0}page\u{00A0}3.")
        #expect(Model.couldNotRunInFull(checks: 2, pages: [2, 6])
                == "2 checks could not run in full on pages 3\u{00A0}and\u{00A0}7.")
        #expect(Model.skippedChecks(1) == "1 check was skipped.")
        #expect(Model.skippedChecks(2) == "2 checks were skipped.")

        // (layers, covered pages, form values, expected kind, main line with no chips, line under it)
        let failed = Self.layer(.fail("f"), .fontVerification, pages: [2])
        let recheckFailedNoPages = Self.layer(.fail("f"), .searchRecheck)
        let gate = Self.layer(.fail("f"), nil)
        let words = Self.layer(.attention("a"), .binaryStringSearch, terms: ["Delia"], pages: [1])
        let fragment = Self.layer(.attention("a"), .ocrCheck, terms: ["Delia"], pages: [1], fragment: true)
        let recheckFailed = Self.layer(.fail("f"), .searchRecheck, pages: [0])
        let oneSearch = Self.layer(.attention("a"), .searchRecheck, lines: [Self.search("“a”", remaining: 1)], pages: [0])
        let twoSearches = Self.layer(.attention("a"), .searchRecheck,
                                     lines: [Self.search("“a”", remaining: 1), Self.search("“b”", remaining: 2)],
                                     pages: [0])
        let other = Self.layer(.attention("a"), .structureCheck, pages: [0])
        let sweepReview = Self.layer(.attention("a"), .detectionSweep, lines: [Self.sweepLine], pages: [0])
        let items = Self.layer(.info("i"), .detectionSweep, lines: [Self.sweepLine], pages: [0, 2])
        let unread = Self.layer(.warn("w"), .ocrCheck, pages: [2], cnv: true)
        let unreadToo = Self.layer(.warn("w"), .metadataCheck, pages: [6], cnv: true)
        let unfinished = Self.layer(.warn("w"), .textExtraction, cnv: true)
        let skipped = Self.layer(.skipped, .characterCount)
        let skippedToo = Self.layer(.skipped, .characterLineage)
        let fact = { (layer: LayerResult, word: String) in DocumentEditorView.confirmFactLine(layer: layer, outcome: word) }
        let rows: [([LayerResult], [Int], Int, Problem.Kind, String, String?)] = [
            ([failed], [], 0, .failedCheck, fact(failed, "failed"), "Short line."),
            ([recheckFailedNoPages], [], 0, .failedCheck, fact(recheckFailedNoPages, "failed"), "Short line."),
            ([gate], [], 0, .failedCheck, fact(gate, "failed"), "Short line."),
            ([words], [], 0, .boxedTextReadable, "Text matching what you boxed is still readable.", "\u{201C}Delia\u{201D}"),
            ([], [0, 2], 0, .coveredTextInOriginal, ResultsFinding.coveredTextTitle,
             ConcealingAnnotations.confirmLine(pages: [0, 2])),
            ([fragment], [], 0, .partOfBoxedText, "Part of boxed text is readable beside its box.",
             "\u{201C}Delia\u{201D}"),
            ([recheckFailed], [], 0, .partOfBoxedText, "Part of boxed text is readable beside its box.", nil),
            ([oneSearch], [], 0, .searchesStillMatch, "1 search still has matches.", nil),
            ([twoSearches], [], 0, .searchesStillMatch, "2 searches still have matches.", nil),
            ([other], [], 0, .otherNeedsReview, fact(other, "needs review"), "Short line."),
            ([sweepReview], [], 0, .otherNeedsReview, VerificationRowModel.sweepRemainingCaption(sweepReview), nil),
            ([items], [], 0, .possibleItems, VerificationRowModel.sweepRemainingCaption(items), nil),
            ([], [], 3, .formValuesNotCarried, ResultsFinding.filledFormValuesNotCarried(count: 3).sentence, nil),
            ([unread], [], 0, .couldNotRunOnPages, "1 check could not run in full on\u{00A0}page\u{00A0}3.", nil),
            ([unread, unreadToo], [], 0, .couldNotRunOnPages,
             "2 checks could not run in full on pages 3\u{00A0}and\u{00A0}7.", nil),
            ([unfinished], [], 0, .couldNotFinish, fact(unfinished, "could not verify"), "Short line."),
            ([skipped], [], 0, .skippedChecks, "1 check was skipped.", nil),
            ([skipped, skippedToo], [], 0, .skippedChecks, "2 checks were skipped.", nil),
        ]
        var ran = 0
        for (layers, covered, forms, kind, main, under) in rows {
            let report = Self.report(layers)
            let problem = try Self.only(report, covered: covered, forms: forms)
            #expect(problem.kind == kind, "row \(ran)")
            #expect(Model.mainLine(problem, report: report, previewAvailable: false) == main, "row \(ran)")
            #expect(Model.subLine(problem, report: report) == under, "row \(ran)")
            ran += 1
        }
        print("[problem-words] rows \(ran)")
        #expect(ran == 18)
        // While chips show, a line built from the share confirm's own line
        // leaves its page phrase out, by the same call on a copy with no pages.
        let withChips = try Self.only(Self.report([failed]))
        let chipped = Model.mainLine(withChips, report: Self.report([failed]), previewAvailable: true)
        #expect(chipped == fact(Model.pageless(failed), "failed"))
        #expect(!chipped.contains("page"))
        // A failed Search Re-check with no pages is a failed check, never the
        // sentence about part of boxed text.
        let noPages = try Self.only(Self.report([recheckFailedNoPages]))
        #expect(Model.mainLine(noPages, report: Self.report([recheckFailedNoPages]), previewAvailable: false)
                != Model.partOfBoxedText)
    }

    @Test("Each kind's mark: its outcome's shipped symbol; the form-values row takes the grey i of possible items")
    func marksByKind() throws {
        let fragment = Self.report([Self.layer(.attention("a"), .ocrCheck, terms: ["x"], pages: [0], fragment: true)])
        let recheckFailed = Self.report([Self.layer(.fail("f"), .searchRecheck, pages: [0])])
        #expect(Model.markOutcome(try Self.only(fragment)) == .needsReview)
        #expect(Model.markOutcome(try Self.only(recheckFailed)) == .failed)
        let forms = try Self.only(Self.report([]), forms: 2)
        #expect(forms.mark == .possibleItems)
        #expect(Model.markOutcome(forms) == .note)
        #expect(Model.markOutcome(forms).markSymbolName == "info.circle")
        #expect(Model.markOutcome(try Self.only(Self.report([]), covered: [0])) == .needsReview)
        #expect(Model.markOutcome(try Self.only(Self.report([Self.layer(.info("i"), .detectionSweep,
                                                                         lines: [Self.sweepLine], pages: [0])])))
                == .note)
        #expect(Model.markOutcome(try Self.only(Self.report([Self.layer(.skipped, .characterCount)]))) == .couldNotVerify)
        #expect(VerificationOutcome.note.markSymbolName == "info.circle")
    }

    // MARK: - Steps by kind

    @Test("Each kind's step: the Secure step only where a Secure export does not run the check, the remedy by its count")
    func stepsByKind() throws {
        // A failed check: the Secure step on exactly the checks a Secure export does not run.
        var withStep = 0
        for identity in VerificationLayer.allCases {
            let report = Self.report([Self.layer(.fail("f"), identity)])
            let step = Model.step(try Self.only(report), report: report, previewAvailable: true)
            let expected: Model.Step? = identity.appliesTo(.secureRasterization)
                ? nil : .sentence("Exporting as Secure Rasterization avoids this.")
            #expect(step == expected, "\(identity)")
            withStep += expected == nil ? 0 : 1
        }
        print("[problem-steps] failed checks with the Secure step \(withStep) of \(VerificationLayer.allCases.count)")
        #expect(withStep == 6)
        let gate = Self.report([Self.layer(.fail("f"), nil)])
        #expect(Model.step(try Self.only(gate), report: gate, previewAvailable: true) == nil)

        // Boxed text still readable: no step.
        let words = Self.report([Self.layer(.attention("a"), .binaryStringSearch, terms: ["a"], pages: [0])])
        #expect(Model.step(try Self.only(words), report: words, previewAvailable: true) == nil)

        // Part of boxed text beside its box: the shipped remedy, its form by
        // the count of words, as the tail of the shipped caption.
        let one = Self.report([Self.layer(.attention("a"), .ocrCheck, terms: ["a"], pages: [0], fragment: true)])
        let two = Self.report([Self.layer(.attention("a"), .ocrCheck, terms: ["a", "b"], pages: [0], fragment: true)])
        let none = Self.report([Self.layer(.fail("f"), .searchRecheck, pages: [0])])
        #expect(Model.step(try Self.only(one), report: one, previewAvailable: true)
                == .sentence(VerificationRowModel.adjustTheBoxRemedy))
        #expect(Model.step(try Self.only(two), report: two, previewAvailable: true)
                == .sentence(VerificationRowModel.adjustTheBoxesRemedy))
        #expect(Model.step(try Self.only(none), report: none, previewAvailable: true)
                == .sentence(VerificationRowModel.adjustTheBoxesRemedy))
        #expect(VerificationRowModel.fragmentSentence(termTexts: ["a"], pages: [0])
            .hasSuffix(" " + VerificationRowModel.adjustTheBoxRemedy))
        #expect(VerificationRowModel.fragmentSentence(termTexts: ["a", "b"], pages: [0])
            .hasSuffix(" " + VerificationRowModel.adjustTheBoxesRemedy))
        #expect(VerificationRowModel.adjustTheBoxRemedy == "Adjust the box and redact again.")
        #expect(VerificationRowModel.adjustTheBoxesRemedy == "Adjust the boxes and redact again.")

        // Searches that still match: the shipped lead of the check.
        let searchLayer = Self.layer(.attention("a"), .searchRecheck, lines: [Self.search("“a”", remaining: 1)], pages: [0])
        let searches = Self.report([searchLayer])
        let lead = VerificationRowModel.lead(for: searchLayer, outcome: .needsReview, perPageModes: [])
        #expect(Model.step(try Self.only(searches), report: searches, previewAvailable: true) == .sentence(lead[0]))

        // Another check that needs review, and possible items left: Review
        // in Scan on the Detection Sweep, by kind;
        // nothing on another check that needs review.
        let sweep = Self.report([Self.layer(.attention("a"), .detectionSweep, lines: [Self.sweepLine], pages: [0])])
        let sweepNothingLeft = Self.report([Self.layer(.attention("a"), .detectionSweep, pages: [0])])
        let items = Self.report([Self.layer(.info("i"), .detectionSweep, lines: [Self.sweepLine], pages: [0])])
        let other = Self.report([Self.layer(.attention("a"), .structureCheck, pages: [0])])
        #expect(Model.step(try Self.only(sweep), report: sweep, previewAvailable: true) == .reviewInScan)
        #expect(Model.step(try Self.only(sweepNothingLeft), report: sweepNothingLeft, previewAvailable: true)
                == .reviewInScan)
        #expect(Model.step(try Self.only(items), report: items, previewAvailable: true) == .reviewInScan)
        #expect(Model.step(try Self.only(other), report: other, previewAvailable: true) == nil)

        // Checks that could not run in full on named pages: look at the page
        // in Preview, while the PDF exists.
        let onePage = Self.report([Self.layer(.warn("w"), .ocrCheck, pages: [2], cnv: true)])
        let twoPages = Self.report([Self.layer(.warn("w"), .ocrCheck, pages: [2, 4], cnv: true)])
        #expect(Model.step(try Self.only(onePage), report: onePage, previewAvailable: true)
                == .sentence("Look at that page in Preview before you share."))
        #expect(Model.step(try Self.only(twoPages), report: twoPages, previewAvailable: true)
                == .sentence("Look at those pages in Preview before you share."))
        #expect(Model.step(try Self.only(onePage), report: onePage, previewAvailable: false) == nil)

        // No step: covered text, form values, a check that could not finish,
        // skipped checks.
        let unfinished = Self.report([Self.layer(.warn("w"), .textExtraction, cnv: true)])
        let skipped = Self.report([Self.layer(.skipped, .characterCount)])
        #expect(Model.step(try Self.only(Self.report([]), covered: [0]), report: Self.report([]), previewAvailable: true) == nil)
        #expect(Model.step(try Self.only(Self.report([]), forms: 1), report: Self.report([]), previewAvailable: true) == nil)
        #expect(Model.step(try Self.only(unfinished), report: unfinished, previewAvailable: true) == nil)
        #expect(Model.step(try Self.only(skipped), report: skipped, previewAvailable: true) == nil)
    }

    // MARK: - The group draws the model

    /// Every seeded report, crossed with covered pages and form values present or not.
    static var crossed: [(String, VerificationReport, [Int], Int)] {
        Fixtures.all.sorted { $0.key < $1.key }.flatMap { name, report in
            [([], 0), ([0], 0), ([], 2), ([0], 2)].map { (name, report, $0.0, $0.1) }
        }
    }

    @Test("The group draws the model: one row per problem, in its order; the heading counts the rows")
    func theGroupDrawsTheModel() {
        #expect(Fixtures.all.count == 18)
        var examined = 0, withGroup = 0, merged = 0
        for (name, report, covered, forms) in Self.crossed {
            let model = VerificationProblemModel.derive(report: report, coveredPages: covered, formValueCount: forms)
            let rows = Section.findingRows(report: report, coveredPages: covered, formValueCount: forms)
            #expect(rows.map(\.id) == model.map(\.id), "\(name) \(covered) \(forms)")
            #expect(rows.map(\.kind) == model.map(\.kind), "\(name)")
            let heading = Section.findingsHeading(rows)
            if model.isEmpty {
                #expect(heading == nil, "\(name)")
            } else {
                #expect(heading?.shown == "Findings · \(model.count)", "\(name)")
                #expect(heading?.spoken == "Findings, \(model.count).", "\(name)")
                withGroup += 1
            }
            merged += rows.contains { $0.checks.count > 1 } ? 1 : 0
            examined += 1
        }
        print("[problem-group] crossed reports \(examined), with a group \(withGroup), with a row of several checks \(merged)")
        #expect(examined == 72)
        #expect(merged > 0)
        // A row of two checks counts once.
        let two = Self.report([Self.layer(.attention("a"), .binaryStringSearch, terms: ["a"], pages: [0]),
                               Self.layer(.attention("a"), .ocrCheck, terms: ["a"], pages: [0])])
        let rows = Section.findingRows(report: two, coveredPages: [], formValueCount: 0)
        #expect(Section.findingsHeading(rows)?.shown == "Findings · 1")
        // A run whose checks did not run: no group, unless covered text or form values.
        #expect(Section.findingRows(report: Fixtures.secureSkippedOff, coveredPages: [], formValueCount: 0).isEmpty)
        #expect(Section.findingRows(report: Fixtures.secureSkippedOff, coveredPages: [1], formValueCount: 0)
            .map(\.kind) == [.coveredTextInOriginal])
    }

    // MARK: - One place for every check

    /// Built reports with a failed or needs-review check that could not read
    /// part of its input: no seeded report has one.
    static var withUnreadParts: [(key: String, value: VerificationReport)] {
        [(key: "failed, its part on a page",
          value: report([layer(.fail("f"), .metadataCheck, pages: [0], part: "1 page could not be checked: 2",
                               partPages: [1]),
                         layer(.warn("w"), .ocrCheck, pages: [3], cnv: true)])),
         (key: "needs review, its part on no page",
          value: report([layer(.attention("a"), .structureCheck, pages: [0], part: "Could not inspect metadata",
                               partPages: [])])),
         (key: "part of boxed text, its part on a page",
          value: report([layer(.attention("a"), .ocrCheck, terms: ["a"], pages: [0], fragment: true,
                               part: "1 page could not be checked: 3", partPages: [2])]))]
    }

    @Test("Every check has one place; every check that makes Share ask is named by one line of the findings, or two where the second is its unread part")
    func everyCheckHasOnePlace() {
        var examined = 0, named = 0, withPart = 0
        let seeded = Fixtures.all.sorted(by: { $0.key < $1.key })
        for (name, report) in seeded + Self.withUnreadParts {
            let partition = VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
            let placed = Section.groups(partition).flatMap(\.indices) + Section.listRowMembers(partition)
            #expect(placed.sorted() == Array(report.layers.indices), "\(name)")
            let problems = VerificationProblemModel.derive(report: report, coveredPages: [], formValueCount: 0)
            var lines: [(index: Int, line: String)] = []
            for problem in problems {
                if problem.kind == .failedCheck || problem.kind == .possibleItems {
                    let main = Model.mainLine(problem, report: report, previewAvailable: false)
                    lines += problem.checks.map { (index: $0.layerIndex, line: main) }
                } else {
                    lines += Model.checkLines(problem, report: report).map { (index: $0.layerIndex, line: $0.line) }
                }
            }
            let isSeeded = Fixtures.all[name] != nil
            for index in report.layers.indices where partition.outcomes[index].gatesSharing {
                let mine = lines.filter { $0.index == index }.map(\.line)
                if let part = DocumentEditorView.couldNotVerifyPartLine(layer: report.layers[index]) {
                    #expect(mine.count == 2, "\(name) check \(index)")
                    #expect(mine.filter { $0 == part }.count == 1, "\(name) check \(index): its unread part")
                    withPart += 1
                } else {
                    #expect(mine.count == 1, "\(name) check \(index)")
                }
                named += isSeeded ? 1 : 0
            }
            examined += isSeeded ? 1 : 0
        }
        print("[problem-places] seeded reports \(examined), checks that make Share ask \(named), "
              + "built checks with an unread part \(withPart)")
        #expect(examined == 18)
        // 24 with Box Fill: the secure all-failed report's Box Fill row needs review,
        // so it makes Share ask as well.
        #expect(named == 24, "the seeded reports' checks that make Share ask")
        #expect(withPart == 3)
    }

    // MARK: - A check's unread part

    @Test("A failed or needs-review check that could not read part of its input: a row of its own says that part as the Share sheet prints it")
    func theUnreadPartHasARowOfItsOwn() throws {
        // A failed check whose part is on a page: its own row, and the part
        // among the checks that could not run in full.
        let part = "1 page could not be checked: 2"
        let failed = Self.report([Self.layer(.fail("f"), .metadataCheck, pages: [0], part: part, partPages: [1])])
        let problems = VerificationProblemModel.derive(report: failed, coveredPages: [], formValueCount: 0)
        #expect(problems.map(\.kind) == [.failedCheck, .couldNotRunOnPages])
        try #require(problems.count == 2)
        let unread = problems[1]
        #expect(problems[0].checks.map(\.outcome) == [.failed] && problems[0].pages == [0])
        #expect(unread.checks == [Problem.Check(layerIndex: 0, outcome: .couldNotVerify, pages: [1], words: [],
                                                sentence: part)])
        #expect(unread.pages == [1] && unread.mark == .couldNotVerify && unread.count == 1 && unread.words.isEmpty)
        let sheet = DocumentEditorView.couldNotVerifyItemLines(report: failed)
        #expect(sheet == ["Author & File Details: could not verify on\u{00A0}page\u{00A0}2"])
        let lines = Model.checkLines(unread, report: failed)
        #expect(lines.map(\.line) == sheet)
        #expect(lines.map(\.sentence) == [part])
        #expect(lines.allSatisfy { $0.words.isEmpty && $0.stopLines.isEmpty })
        #expect(Model.mainLine(unread, report: failed, previewAvailable: true)
                == Model.couldNotRunInFull(checks: 1, pages: [1]))
        #expect(Model.chipPages(unread, isOpen: true) == [1])
        #expect(Model.step(unread, report: failed, previewAvailable: true) == .sentence(Model.lookAtThatPage))

        // A check that needs review whose part names no page: its own row as
        // it is without the part, and the part as a check that could not finish.
        let whole = "Could not inspect metadata"
        let review = Self.report([Self.layer(.attention("a"), .structureCheck, pages: [0], part: whole, partPages: [])])
        let without = Self.report([Self.layer(.attention("a"), .structureCheck, pages: [0])])
        let two = VerificationProblemModel.derive(report: review, coveredPages: [], formValueCount: 0)
        #expect(two.map(\.kind) == [.otherNeedsReview, .couldNotFinish])
        try #require(two.count == 2)
        let alone = try Self.only(without)
        #expect(two[0] == alone)
        #expect(Model.mainLine(two[0], report: review, previewAvailable: true)
                == Model.mainLine(alone, report: without, previewAvailable: true))
        let finish = two[1]
        #expect(finish.id == "couldNotFinish-0" && finish.pages.isEmpty)
        #expect(finish.checks.map(\.outcome) == [.couldNotVerify] && finish.checks.map(\.sentence) == [whole])
        let reviewSheet = DocumentEditorView.couldNotVerifyItemLines(report: review)
        #expect(reviewSheet == ["Scripts & Attachments: could not verify"])
        #expect(Model.mainLine(finish, report: review, previewAvailable: true) == reviewSheet.first)
        #expect(Model.subLine(finish, report: review) == whole)
        #expect(Model.checkLines(finish, report: review).map(\.line) == reviewSheet)
        #expect(Model.step(finish, report: review, previewAvailable: true) == nil)

        // A check that could not verify on its own, with no failure or
        // review: one entry, as before.
        let warn = Self.report([Self.layer(.warn("w"), .ocrCheck, pages: [3], cnv: true)])
        #expect(try Self.only(warn).kind == .couldNotRunOnPages)
    }

    // MARK: - Every word can be read

    @Test("Every word can be read: the closed row in two lines at most, the opened row every word once")
    func everyWordCanBeRead() throws {
        let seven = ["Delia", "Marsh", "4471", "Elm Street", "Fenwick", "May 3", "Hollis"]
        let report = Self.report([Self.layer(.attention("a"), .binaryStringSearch, terms: seven,
                                             pages: Array(0..<12))])
        let problem = try Self.only(report)
        #expect(Model.subLine(problem, report: report, fits: { _ in true }) == VerificationRowModel.quotedList(seven))
        #expect(Model.subLine(problem, report: report, fits: { _ in false })
                == "\u{201C}Delia\u{201D} and 6 more")
        #expect(Model.closedWords(["Delia"], fits: { _ in false }) == "\u{201C}Delia\u{201D}")
        let opened = Model.checkLines(problem, report: report).flatMap(\.words)
        #expect(opened == seven)
        for word in seven { #expect(opened.filter { $0 == word }.count == 1, "\(word)") }
        #expect(Model.subLineIsPrivate(problem))
    }

    // MARK: - Pages

    @Test("Pages: closed, at most five chips or four and +n more; opened, every page; a row of checks that could not run in full names every page")
    func pagesAreCapped() throws {
        let report = Self.report([Self.layer(.attention("a"), .binaryStringSearch, terms: ["a"], pages: Array(0..<12))])
        let problem = try Self.only(report)
        #expect(Model.chipPages(problem, isOpen: false) == [0, 1, 2, 3])
        #expect(Model.moreChipsText(problem, isOpen: false) == "+8\u{00A0}more")
        #expect(Model.chipPages(problem, isOpen: true) == Array(0..<12))
        #expect(Model.moreChipsText(problem, isOpen: true) == nil)
        let five = Self.report([Self.layer(.attention("a"), .binaryStringSearch, terms: ["a"], pages: Array(0..<5))])
        #expect(Model.chipPages(try Self.only(five), isOpen: false) == Array(0..<5))
        #expect(Model.showsChips(problem, previewAvailable: true))
        #expect(!Model.showsChips(problem, previewAvailable: false))
        #expect(Model.couldNotRunInFull(checks: 1, pages: [0]) == "1 check could not run in full on\u{00A0}page\u{00A0}1.")
        #expect(Model.couldNotRunInFull(checks: 1, pages: [0, 1, 2])
                == "1 check could not run in full on pages 1, 2,\u{00A0}and\u{00A0}3.")
        #expect(Model.couldNotRunInFull(checks: 2, pages: [0, 1, 2, 3])
                == "2 checks could not run in full on pages 1, 2, 3,\u{00A0}and\u{00A0}4.")
    }

    // MARK: - Spoken labels

    static let sentinel = "QZSENTINEL"

    @Test("No spoken label, heading, main line, step or check line carries the person's words; words are private")
    func noSpokenLabelCarriesDocumentText() throws {
        let typed = SearchRecheckQueryLine(
            label: "\u{201C}\(Self.sentinel)\u{201D}", foundCount: 2, foundHitCap: false, appliedCount: 1,
            remainingCount: 1, route: .ocr, perTerm: [.init(term: Self.sentinel, found: 2, applied: 1, remaining: 1)])
        let layers = [
            Self.layer(.attention("a"), .searchRecheck, terms: [Self.sentinel], lines: [typed], pages: [0]),
            Self.layer(.attention("a"), .binaryStringSearch, terms: [Self.sentinel], pages: [1]),
            Self.layer(.attention("a"), .ocrCheck, terms: [Self.sentinel], pages: [1], fragment: true),
            Self.layer(.info("i"), .detectionSweep, lines: [Self.sweepLine], pages: [0, 1]),
            Self.layer(.warn("w"), .ocrCheck, terms: [Self.sentinel], pages: [2], cnv: true),
            Self.layer(.fail("f"), .fontVerification, terms: [Self.sentinel], pages: [3]),
            Self.layer(.skipped, .characterCount),
        ]
        let report = Self.report(layers)
        let problems = VerificationProblemModel.derive(report: report, coveredPages: [0], formValueCount: 2)
        var shown: [String] = [Section.findingsHeading(problems)?.shown ?? "", Section.findingsHeading(problems)?.spoken ?? ""]
        var privateWords = 0
        for problem in problems {
            for preview in [true, false] {
                shown.append(Model.spokenLabel(problem, report: report, previewAvailable: preview))
                shown.append(Model.mainLine(problem, report: report, previewAvailable: preview))
                if case .sentence(let line) = Model.step(problem, report: report, previewAvailable: preview) {
                    shown.append(line)
                }
            }
            if let sub = Model.subLine(problem, report: report) {
                if sub.contains(Self.sentinel) {
                    #expect(Model.subLineIsPrivate(problem), "\(sub)")
                    privateWords += 1
                } else {
                    shown.append(sub)
                }
            }
            for line in Model.checkLines(problem, report: report) {
                shown += [line.line, line.sentence ?? ""] + line.stopLines
            }
        }
        for line in shown { #expect(!line.contains(Self.sentinel), "\(line)") }
        print("[problem-private] problems \(problems.count), lines read \(shown.count), private lines with the word \(privateWords)")
        #expect(problems.count >= 7)
        #expect(privateWords == 2)
        // The row draws the words private, in the closed line and the opened lines.
        let source = try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/FindingRow.swift"), encoding: .utf8)
        #expect(source.components(separatedBy: ".privacySensitive(FindingRowModel.subLineIsPrivate(problem))").count == 2)
        #expect(source.components(separatedBy: "Text(\"\\u{201C}\\(word)\\u{201D}\")").count == 2)
        let wordsSite = try #require(source.range(of: "Text(\"\\u{201C}\\(word)\\u{201D}\")"))
        let next = try #require(source.range(of: ".privacySensitive()", range: wordsSite.upperBound..<source.endIndex))
        #expect(source[wordsSite.upperBound..<next.lowerBound].count < 160)
    }

    // MARK: - The list row

    @Test("The list row: the shipped title and the tick on a pass; otherwise P of T checks passed and the list mark")
    func listRowWhenSomethingDidNotPass() {
        let failed = VerificationLayerPartition(layers: Fixtures.secureAllFailed.layers,
                                                perPageModes: Fixtures.secureAllFailed.perPageModes)
        #expect(!Section.listRowReportsAPass(failed))
        #expect(Section.listRowWords(failed).first == failed.summaryLine1)
        #expect(Section.listRowMarkSymbol(failed) == "list.bullet")
        let clean = VerificationLayerPartition(layers: Fixtures.secureAllPass.layers,
                                               perPageModes: Fixtures.secureAllPass.perPageModes)
        #expect(Section.listRowReportsAPass(clean))
        #expect(Section.listRowMarkSymbol(clean) == "checkmark")
        #expect(Section.listRowWords(clean).first == clean.clusterTitleBase)
        #expect(Section.listRowSpokenLabel(clean) == clean.clusterSpokenLabel)
        // The members: every check not in a card above, in the report's order.
        var examined = 0
        for (name, report) in Fixtures.all {
            let p = VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
            let above = Set(Section.groups(p).flatMap(\.indices))
            #expect(Section.listRowMembers(p) == report.layers.indices.filter { !above.contains($0) }, "\(name)")
            examined += 1
        }
        #expect(examined == 18)
        // With checks that had nothing to check, their clause on the second line.
        let idle = Self.layer(.notApplicable("n"), .searchRecheck)
        let mixed = VerificationLayerPartition(layers: [Self.layer(.fail("f"), .textExtraction), Self.layer(.pass, .ocrCheck), idle],
                                               perPageModes: [])
        #expect(Section.listRowWords(mixed).first == "1 of 2 checks passed")
        #expect(Section.listRowWords(mixed).second == "1\u{00A0}had nothing to check")
    }

    // MARK: - Source pin

    @Test("Source pin: the details draw no by-check group headings; the Findings heading stays")
    func noByCheckGroupHeadings() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/VerificationDetailsSection.swift"), encoding: .utf8)
        #expect(!source.contains("\"Could not verify\""))
        #expect(!source.contains("\"Incomplete\""))
        #expect(source.contains("\"Findings\""))
    }

    @Test("Source pin: a page chip answers a tap anywhere in its 46-pt touch target, its hit frame set before its tap shape")
    func pageChipKeepsItsTouchTarget() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/PageChip.swift"), encoding: .utf8)
        let lines = source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let capsule = try #require(lines.firstIndex { $0.hasPrefix(".background(") && $0.contains("Capsule()") })
        let frame = try #require(lines.firstIndex { $0 == ".frame(minHeight: ResectaTokens.TouchTarget.minimum)" })
        let shape = try #require(lines.firstIndex { $0 == ".contentShape(Rectangle())" })
        let pull = try #require(lines.firstIndex {
            $0.hasPrefix(".padding(.vertical, -(ResectaTokens.TouchTarget.minimum - ResectaTokens.Results.chipHeight)")
        })
        #expect(capsule < frame && frame < shape && shape < pull)
        #expect(ResectaTokens.TouchTarget.minimum == 46)
    }

    // MARK: - The results view's two values

    @Test("The shipped section above keeps only the hand-drawn item; the details get the covered pages and the values")
    func theResultsViewHandsOnItsValues() {
        let items: [ResultsFinding] = [.coveredTextInOriginal(pages: [1]), .filledFormValuesNotCarried(count: 4),
                                       .handRegionsOnPagesWithoutText(regionPages: [2])]
        #expect(VerificationResultsView.findingsOutsideTheGroup(items) == [.handRegionsOnPagesWithoutText(regionPages: [2])])
        #expect(VerificationResultsView.formValueCount(in: items) == 4)
        #expect(VerificationResultsView.formValueCount(in: []) == 0)
        #expect(VerificationResultsActions.concealedPages(in: items) == [1])
    }
}
