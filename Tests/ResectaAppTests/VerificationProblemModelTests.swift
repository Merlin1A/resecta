import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// The problems model's rule, against the shipped Share gate itself: for a
// report that has checks, `VerificationProblemModel.derive` returns a problem
// exactly when `DocumentEditorView.shareConfirmKind` would ask with nothing
// acknowledged. The gate is the oracle; these tests never restate its
// conditions.

@Suite("Findings by problem: the model")
@MainActor
struct VerificationProblemModelTests {

    typealias Kind = VerificationProblem.Kind

    // MARK: - Building reports

    /// Every generated result carries this one sentence, so code that decided
    /// a kind by looking for a word in an engine sentence would see nothing
    /// to tell the results apart, and no test here could pass because of it.
    static let sentence = "A placeholder sentence."

    enum State: CaseIterable {
        case passed, note, noteWithItems, nothingToCheck, plainWarning
        case flaggedWarningWithPages, flaggedWarningWithoutPages, skipped
        case needsReviewWithWords, needsReviewFragment, needsReviewMatching
        case failedWithPages, failedWithoutPages
    }

    /// The five checks of the generated reports: the three that look for the
    /// person's words, the Search Re-check and the Detection Sweep.
    static let identities: [VerificationLayer] = [.ocrCheck, .binaryStringSearch, .operatorReExtraction,
                                                  .searchRecheck, .detectionSweep]

    static func states(for identity: VerificationLayer) -> [State] {
        State.allCases.filter { state in
            switch state {
            case .noteWithItems: identity == .detectionSweep
            case .needsReviewFragment: VerificationRowModel.quotesReviewTerms(identity)
            case .needsReviewMatching: identity == .searchRecheck
            default: true
            }
        }
    }

    static func line(remaining: Int) -> SearchRecheckQueryLine {
        SearchRecheckQueryLine(label: "\u{201C}Delia\u{201D}", foundCount: 2, foundHitCap: false,
                               appliedCount: 2, remainingCount: remaining, route: .ocr)
    }

    static func layer(_ identity: VerificationLayer, _ state: State) -> LayerResult {
        var status = VerificationStatus.pass
        var pages: [Int]?
        var terms: [String]?
        var lines: [SearchRecheckQueryLine]?
        var flagged = false
        var fragment = false
        switch state {
        case .passed: break
        case .note: status = .info(sentence)
        case .noteWithItems: status = .info(sentence); pages = [1]; lines = [line(remaining: 2)]
        case .nothingToCheck: status = .notApplicable(sentence)
        case .plainWarning: status = .warn(sentence); pages = [1]
        case .flaggedWarningWithPages: status = .warn(sentence); pages = [1]; flagged = true
        case .flaggedWarningWithoutPages: status = .warn(sentence); flagged = true
        case .skipped: status = .skipped
        case .needsReviewWithWords: status = .attention(sentence); pages = [0]; terms = ["Delia"]
        case .needsReviewFragment: status = .attention(sentence); pages = [0]; terms = ["Del"]; fragment = true
        case .needsReviewMatching: status = .attention(sentence); pages = [0]; lines = [line(remaining: 1)]
        case .failedWithPages: status = .fail(sentence); pages = [0]
        case .failedWithoutPages: status = .fail(sentence)
        }
        return LayerResult(name: identity.name, symbolName: identity.symbolName, status: status,
                           shortDescription: sentence, detailDescription: "", pageReferences: pages,
                           durationSeconds: 0, reviewTermTexts: terms, layer: identity, queryLines: lines,
                           couldNotVerify: flagged, reviewIsFragment: fragment)
    }

    /// The result with a part it could not read, on `pages`; every other
    /// field as it was. The part carries the one placeholder sentence.
    static func withPart(_ l: LayerResult, pages: [Int]) -> LayerResult {
        LayerResult(name: l.name, symbolName: l.symbolName, status: l.status, shortDescription: l.shortDescription,
                    detailDescription: l.detailDescription, pageReferences: l.pageReferences,
                    durationSeconds: l.durationSeconds, reviewTermTexts: l.reviewTermTexts, layer: l.layer,
                    queryLines: l.queryLines, couldNotVerify: l.couldNotVerify, reviewIsFragment: l.reviewIsFragment,
                    couldNotVerifyPart: sentence, couldNotVerifyPartPages: pages, stopped: l.stopped)
    }

    /// Each one-check generated report whose check failed or needs review
    /// (19), that check given a part it could not read on a page and on none.
    static func reportsWithUnreadParts() -> [VerificationReport] {
        let base = identities.map { layer($0, .passed) }
        var out: [VerificationReport] = []
        for i in identities.indices {
            for s in states(for: identities[i]) {
                let one = layer(identities[i], s)
                guard one.status.isFail || one.status.isAttention else { continue }
                for pages in [[2], []] {
                    var layers = base
                    layers[i] = withPart(one, pages: pages)
                    out.append(report(layers))
                }
            }
        }
        return out
    }

    /// A report whose verdict is the engine's own fold over its checks.
    static func report(_ layers: [LayerResult]) -> VerificationReport {
        VerificationReport(layers: layers, overallStatus: VerificationEngine().aggregateStatus(layers),
                           durationSeconds: 0)
    }

    /// One check in a state, then every pair of checks in every pair of
    /// states; the other checks pass.
    static func generatedReports() -> [VerificationReport] {
        let base = identities.map { layer($0, .passed) }
        var out: [VerificationReport] = []
        for i in identities.indices {
            for s in states(for: identities[i]) {
                var layers = base
                layers[i] = layer(identities[i], s)
                out.append(report(layers))
            }
        }
        for i in identities.indices {
            for j in identities.indices where j > i {
                for si in states(for: identities[i]) {
                    for sj in states(for: identities[j]) {
                        var layers = base
                        layers[i] = layer(identities[i], si)
                        layers[j] = layer(identities[j], sj)
                        out.append(report(layers))
                    }
                }
            }
        }
        return out
    }

    // MARK: - The oracle and the checks every case gets

    /// The shipped gate, with a fresh state: nothing acknowledged.
    static func shareAsks(_ report: VerificationReport, coveredPages: [Int], formValueCount: Int) -> Bool {
        let state = DocumentState()
        state.sourceFilledFormFieldCount = formValueCount
        return DocumentEditorView.shareConfirmKind(report: report, documentState: state,
                                                   concealedPages: coveredPages) != nil
    }

    /// Nothing dropped, nothing counted twice: the checks behind the
    /// problems are exactly those whose outcome gates sharing, plus those
    /// with possible items left, each once; and a failed or needs-review
    /// check that also could not read part of its input once more, by that
    /// part, its outcome could not verify.
    static func namesEachGatingCheckOnce(_ report: VerificationReport, _ problems: [VerificationProblem]) -> Bool {
        let checks = problems.flatMap(\.checks)
        let named = checks.map(\.layerIndex)
        let expected = report.layers.indices.filter { i in
            let l = report.layers[i]
            return VerificationRowModel.outcome(for: l, perPageModes: report.perPageModes).gatesSharing
                || VerificationRowModel.hasItemsRemaining(l)
        }
        let parts = report.layers.indices.filter { i in
            let l = report.layers[i]
            return (l.status.isFail || l.status.isAttention) && l.couldNotVerifyPart != nil
        }
        let second = checks.filter { parts.contains($0.layerIndex) && $0.outcome == .couldNotVerify }.map(\.layerIndex)
        return named.sorted() == (expected + parts).sorted() && second.sorted() == parts
            && Set(named).count + parts.count == named.count
    }

    /// The kinds come in their declared order.
    static func inKindOrder(_ problems: [VerificationProblem]) -> Bool {
        zip(problems, problems.dropFirst()).allSatisfy { $0.kind <= $1.kind }
    }

    // MARK: - The seeded reports

    @Test("The seeded reports give these problems")
    func seededReportsGiveTheseFindings() throws {
        let rows: [(String, [Kind])] = [
            ("secureAllPass", []), ("searchableAllPass", []), ("searchableAllRasterized", []),
            ("secureWarningOnly", []), ("securePassRidingNote", []),
            ("secureScreenshot", [.possibleItems]), ("secureScanOnly", [.possibleItems]),
            ("searchableAttentionMixed", [.boxedTextReadable, .couldNotRunOnPages]),
            ("searchableAttentionFull", [.boxedTextReadable, .couldNotRunOnPages]),
            // No seeded report sets the part-of-a-word flag, so this one is
            // boxed text still readable, from its two word checks.
            ("searchableAttentionLong", [.boxedTextReadable, .couldNotRunOnPages]),
            ("secureFail", [.failedCheck]), ("pageCountGate", [.failedCheck]),
            ("searchableSkipInduced", [.skippedChecks]),
            ("searchableRecheckReview", [.searchesStillMatch]),
            ("secureAllFailed", [.failedCheck, .failedCheck, .failedCheck, .failedCheck, .failedCheck,
                                 .searchesStillMatch, .otherNeedsReview, .couldNotRunOnPages]),
            ("searchableSweepReview", [.otherNeedsReview]),
        ]
        let counts: [String: [Kind: Int]] = [
            "searchableAttentionMixed": [.couldNotRunOnPages: 2],
            "searchableAttentionFull": [.couldNotRunOnPages: 2],
            "searchableAttentionLong": [.couldNotRunOnPages: 1],
            "searchableSkipInduced": [.skippedChecks: 2],
            "searchableRecheckReview": [.searchesStillMatch: 2],
            "secureAllFailed": [.searchesStillMatch: 1, .couldNotRunOnPages: 1],
        ]
        var ran = 0
        for (name, kinds) in rows {
            let report = try #require(VerificationDebugFixtures.all[name], "no seeded report \(name)")
            let problems = VerificationProblemModel.derive(report: report, coveredPages: [], formValueCount: 0)
            #expect(problems.map(\.kind) == kinds, "\(name)")
            for (kind, count) in counts[name] ?? [:] {
                #expect(problems.first { $0.kind == kind }?.count == count, "\(name) \(kind)")
            }
            #expect(Set(problems.map(\.id)).count == problems.count, "\(name): ids unique")
            ran += 1
        }
        print("[problems-model] seeded rows \(ran)")
        #expect(ran == 16)
        // Every seeded report with checks is in the table.
        #expect(VerificationDebugFixtures.all.values.filter { !$0.layers.isEmpty }.count == 16)
    }

    // MARK: - Generated reports against the gate

    @Test("Findings exist exactly when Share asks")
    func findingsExistExactlyWhenShareAsks() {
        var cases = 0
        var keys = Set<String>()
        for report in Self.generatedReports() {
            for covered in [[Int](), [0]] {
                for forms in [0, 2] {
                    let problems = VerificationProblemModel.derive(report: report, coveredPages: covered,
                                                                   formValueCount: forms)
                    let asks = Self.shareAsks(report, coveredPages: covered, formValueCount: forms)
                    #expect(!problems.isEmpty == asks,
                            "\(report.layers.map { "\($0.status)" }) covered \(covered) forms \(forms): \(problems.map(\.kind))")
                    keys.insert(Self.gateKey(report, covered: !covered.isEmpty, forms: forms > 0))
                    cases += 1
                }
            }
        }
        print("[problems-model] generated cases \(cases), gate keys \(keys.count)")
        #expect(cases == 5_060)
        #expect(cases > 1_000)
        #expect(keys.count == 40)
    }

    /// What the gate reads with nothing acknowledged: the verdict's class
    /// (five), covered pages, the sweep's items, form values.
    static func gateKey(_ report: VerificationReport, covered: Bool, forms: Bool) -> String {
        let s = report.overallStatus
        let verdict: String
        if s.isFail { verdict = "failed" }
        else if s.isAttention { verdict = "needs review" }
        else if s.isWarn {
            let incomplete = report.layers.contains { $0.status.isSkipped } || report.layers.contains(where: CouldNotVerifyWarn.matches)
            verdict = incomplete ? "warnings, incomplete" : "warnings"
        } else { verdict = "passed" }
        let items = report.layers.contains(where: VerificationRowModel.hasItemsRemaining)
        return "\(verdict) · covered \(covered) · items \(items) · forms \(forms)"
    }

    // MARK: - Each gating check once, kinds in order

    @Test("Nothing dropped, nothing counted twice, kinds in order")
    func nothingDroppedNothingTwice() {
        var reports = Self.generatedReports()
        reports += VerificationDebugFixtures.all.values.filter { !$0.layers.isEmpty }
        reports += Self.reportsWithUnreadParts()
        var ran = 0
        for report in reports {
            let problems = VerificationProblemModel.derive(report: report, coveredPages: [0], formValueCount: 2)
            #expect(Self.namesEachGatingCheckOnce(report, problems), "\(report.layers.map { "\($0.status)" })")
            #expect(Self.inKindOrder(problems), "\(problems.map(\.kind))")
            ran += 1
        }
        print("[problems-model] reports \(ran)")
        #expect(ran == 1_265 + 16 + 38)
    }

    // MARK: - The right kind for a failed re-check and a fragment

    @Test("A plain sentence is earned: the right kind for a failed re-check and a fragment")
    func plainSentenceIsEarned() {
        func derive(_ layers: [LayerResult]) -> [VerificationProblem] {
            VerificationProblemModel.derive(report: Self.report(layers), coveredPages: [], formValueCount: 0)
        }
        let passing = Self.identities.map { Self.layer($0, .passed) }
        var withPages = passing
        withPages[3] = Self.layer(.searchRecheck, .failedWithPages)
        let a = derive(withPages)
        #expect(a.map(\.kind) == [.partOfBoxedText])
        #expect(a.first?.mark == .failed)
        var noPages = passing
        noPages[3] = Self.layer(.searchRecheck, .failedWithoutPages)
        #expect(derive(noPages).map(\.kind) == [.failedCheck])
        var fragment = passing
        fragment[1] = Self.layer(.binaryStringSearch, .needsReviewFragment)
        let f = derive(fragment)
        #expect(f.map(\.kind) == [.partOfBoxedText])
        #expect(f.first?.mark == .needsReview)
        var both = passing
        both[0] = Self.layer(.ocrCheck, .needsReviewWithWords)
        both[1] = Self.layer(.binaryStringSearch, .needsReviewFragment)
        let b = derive(both)
        #expect(b.map(\.kind) == [.boxedTextReadable, .partOfBoxedText])
        #expect(b.first?.words == ["Delia"])
        #expect(b.first?.checks.map(\.layerIndex) == [0])
        #expect(b.last?.checks.map(\.layerIndex) == [1])
    }

    // MARK: - Reports whose checks did not run

    /// The named exception: a report with no checks (a Stop, a cancelled run,
    /// verification off) has no result to sort into a kind, so only the two
    /// kinds with no check behind them can appear, while the gate asks. A
    /// report whose every check was skipped has checks, and is skipped checks.
    @Test("Reports whose checks did not run")
    func reportsWhoseChecksDidNotRun() throws {
        let off = try #require(VerificationDebugFixtures.all["secureSkippedOff"])
        let cancelled = try #require(VerificationDebugFixtures.all["searchableSkippedCancelled"])
        let allSkipped = Self.report(Self.identities.map { Self.layer($0, .skipped) })
        #expect(allSkipped.overallStatus.isSkipped)
        let rows: [(VerificationReport, [Int], Int, [Kind], Int?)] = [
            (off, [], 0, [], nil),
            (cancelled, [], 0, [], nil),
            (off, [], 2, [.formValuesNotCarried], 2),
            (off, [0], 0, [.coveredTextInOriginal], nil),
            (allSkipped, [], 0, [.skippedChecks], 5),
        ]
        var ran = 0
        for (report, covered, forms, kinds, count) in rows {
            let problems = VerificationProblemModel.derive(report: report, coveredPages: covered, formValueCount: forms)
            #expect(problems.map(\.kind) == kinds)
            #expect(problems.first?.count == count)
            #expect(DocumentEditorView.shareNeedsSkippedConfirm(report: report, acknowledged: false))
            ran += 1
        }
        let pages = VerificationProblemModel.derive(report: off, coveredPages: [0], formValueCount: 0).first?.pages
        #expect(pages == [0])
        #expect(VerificationProblemModel.derive(report: allSkipped, coveredPages: [], formValueCount: 0)
            .first?.checks.count == 5)
        print("[problems-model] not-run rows \(ran)")
        #expect(ran == 5)
    }

    // MARK: - Acknowledgements

    /// The signature is what keeps the function blind to the acknowledgement
    /// flags: it is given a report, pages and a count, and reports what was
    /// found; the gate decides whether to ask now. Here, for one report per
    /// family of the gate, the gate asks exactly when that family's own flag
    /// is unset (16 of the 32 combinations), while the three values the
    /// function is given are the same in all 32. For the checks-not-run
    /// family the function's list is empty (the named exception). Nothing in
    /// the new file can turn this test red; only a change to the gate can.
    @Test("Acknowledgements change the gate, not the problems")
    func acknowledgementsDoNotChangeTheFindings() {
        let flags: [ReferenceWritableKeyPath<DocumentState, Bool>] = [
            \.failShareAcknowledged, \.skippedShareAcknowledged, \.incompleteWarnShareAcknowledged,
            \.concealedAnnotationsShareAcknowledged, \.possibleItemsShareAcknowledged,
        ]
        let passing = Self.identities.map { Self.layer($0, .passed) }
        var failed = passing; failed[0] = Self.layer(.ocrCheck, .failedWithPages)
        var skippedOne = passing; skippedOne[0] = Self.layer(.ocrCheck, .skipped)
        var items = passing; items[4] = Self.layer(.detectionSweep, .noteWithItems)
        let families: [(VerificationReport, [Int], Int, Bool)] = [  // report, covered, own flag, problems expected
            (Self.report(failed), [], 0, true),
            (VerificationReport.skipped(reason: .autoVerifyOff), [], 1, false),
            (Self.report(skippedOne), [], 2, true),
            (Self.report(passing), [0], 3, true),
            (Self.report(items), [], 4, true),
        ]
        var ran = 0
        for (report, covered, own, expectFindings) in families {
            let problems = VerificationProblemModel.derive(report: report, coveredPages: covered, formValueCount: 0)
            #expect(problems.isEmpty == !expectFindings)
            var asks = 0, quiet = 0
            for combination in 0..<32 {
                let state = DocumentState()
                for (bit, flag) in flags.enumerated() { state[keyPath: flag] = combination & (1 << bit) != 0 }
                let kind = DocumentEditorView.shareConfirmKind(report: report, documentState: state,
                                                               concealedPages: covered)
                if kind != nil { asks += 1 } else { quiet += 1 }
                #expect((kind != nil) == !state[keyPath: flags[own]])
            }
            #expect(asks == 16 && quiet == 16)
            ran += 1
        }
        #expect(ran == 5)
    }
}
