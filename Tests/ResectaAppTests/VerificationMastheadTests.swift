import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The results masthead's words: the row-word title, the one sentence on
// every verdict (it names the control to use), the spoken label with the
// counts, and the completion line. Each sentence is checked against the
// forged reports the results screen is reviewed on, and against the arms
// those reports do not reach.

@Suite("Verification masthead", .tags(.display))
@MainActor
struct VerificationMastheadTests {

    typealias Results = VerificationResultsView
    typealias Fixtures = VerificationDebugFixtures

    static let keepEditing = "Keep\u{00A0}Editing"

    static func row(_ status: VerificationStatus, _ identity: VerificationLayer?,
                    terms: [String]? = nil, pages: [Int]? = nil, cnv: Bool = false,
                    lines: [SearchRecheckQueryLine]? = nil) -> LayerResult {
        LayerResult(name: identity?.name ?? "L", symbolName: "shield", status: status,
                    shortDescription: "Short line.", detailDescription: "", pageReferences: pages,
                    durationSeconds: 0, reviewTermTexts: terms, layer: identity, queryLines: lines,
                    couldNotVerify: cnv)
    }

    static func report(_ status: VerificationStatus, _ rows: [LayerResult]) -> VerificationReport {
        VerificationReport(layers: rows, overallStatus: status, durationSeconds: 1)
    }

    static func attention(terms: [String]) -> VerificationReport {
        report(.attention("a"), [row(.attention("a"), .binaryStringSearch, terms: terms, pages: [1]),
                                 row(.pass, .structureCheck)])
    }

    // MARK: - Titles

    @Test("The row-word titles; INFO reads as a pass; a WARN with a could-not-verify row is incomplete")
    func titles() {
        #expect(VerificationStatus.pass.title == "Checks Passed")
        #expect(VerificationStatus.info("i").title == "Checks Passed")
        #expect(VerificationStatus.warn("w").title == "Completed with\u{00A0}Warnings")
        #expect(VerificationStatus.attention("a").title == "Needs Review")
        #expect(VerificationStatus.fail("f").title == "Checks Failed")
        #expect(VerificationStatus.skipped.title == "Verification Skipped")
        #expect(Results.mastheadTitle(report: Fixtures.secureWarningOnly) == "Completed with\u{00A0}Warnings")
        #expect(Results.mastheadTitle(report: Fixtures.searchableSkipInduced) == "Some Checks Incomplete")
        #expect(Results.mastheadTitle(report: Fixtures.searchableAttentionMixed) == "Needs Review")
    }

    // MARK: - The sentences, fixture by fixture

    /// The sentence each forged report shows (the shipped layout's PASS
    /// note pair names Verification Details until the grouped layout).
    static let fixtureSentences: [(String, String)] = [
        ("secureAllPass", "Look over the redacted PDF in Preview before you share it."),
        ("secureScreenshot", "Read the note in Verification Details before you share the PDF."),
        ("secureScanOnly", "Read the note in Verification Details before you share the PDF."),
        ("searchableAllPass", "Look over the redacted PDF in Preview before you share it."),
        ("searchableAllRasterized", "Look over the redacted PDF in Preview before you share it."),
        ("searchableAttentionMixed", "\(keepEditing), then use text\u{00A0}search to redact \u{201C}Delia\u{201D}."),
        ("searchableAttentionFull",
         "\(keepEditing), then use text\u{00A0}search to redact \u{201C}Delia\u{201D} and \u{201C}Marco\u{201D}."),
        ("searchableAttentionLong", "\(keepEditing), then use text\u{00A0}search to redact the terms below."),
        ("searchableRecheckReview", "\(keepEditing) and run your searches again with OCR on."),
        ("secureFail", "\(keepEditing) to fix what failed, or share after review."),
        ("secureAllFailed", "\(keepEditing) to fix what failed, or share after review."),
        ("searchableSkipInduced", "Run Redact again from \(keepEditing) to include the skipped checks."),
        ("pageCountGate", "\(keepEditing) and run Redact again; the other checks did not run."),
        ("securePassRidingNote", "Read the note in Verification Details before you share the PDF."),
        ("secureWarningOnly", "Read the warning below before you share the PDF."),
        ("searchableSkippedCancelled", "Stopped early. Run\u{00A0}Verification, or run Redact for all checks."),
    ]

    @Test("Every forged report shows its sentence of record, at most 70 characters")
    func fixtureSentencesOfRecord() throws {
        #expect(Self.fixtureSentences.count == 16)
        for (name, sentence) in Self.fixtureSentences {
            let report = try #require(Fixtures.all[name], "\(name)")
            let shown = Results.mastheadSubtitle(report: report)
            #expect(shown == sentence, "\(name): \(shown ?? "nil")")
            #expect((shown ?? "").count <= Results.mastheadSentenceLimit, "\(name)")
        }
        #expect(Results.mastheadSubtitle(report: Fixtures.secureSkippedOff, mode: .secure)
                == "Off in Settings. Run\u{00A0}Verification below before you share the PDF.")
    }

    @Test("WARN is decided by the could-not-verify rows, singular and plural")
    func warnArms() {
        let warning = Self.row(.warn("w"), .structureCheck)
        let cnv = Self.row(.warn("w"), .ocrCheck, cnv: true)
        let skipped = Self.row(.skipped, .characterCount)
        func sentence(_ rows: [LayerResult]) -> String? {
            Results.mastheadSubtitle(report: Self.report(.warn("w"), rows))
        }
        #expect(sentence([warning]) == "Read the warning below before you share the PDF.")
        #expect(sentence([warning, warning]) == "Read the warnings below before you share the PDF.")
        #expect(sentence([cnv]) == "1 check could not run in full; read it below before you share.")
        #expect(sentence([cnv, skipped, warning])
                == "2 checks could not run in full; read them below before you share.")
        #expect(sentence([skipped, warning])
                == "Run Redact again from \(Self.keepEditing) to include the skipped check.")
    }

    @Test("ATTENTION: every term, then the first and a count, then the terms below — never a cut term")
    func attentionFitOrFallBack() {
        let lead = "\(Self.keepEditing), then use text\u{00A0}search to redact"
        func sentence(_ terms: [String]) -> String? { Results.mastheadSubtitle(report: Self.attention(terms: terms)) }
        #expect(sentence(["Delia"]) == "\(lead) \u{201C}Delia\u{201D}.")
        #expect(sentence(["Delia", "Marco"]) == "\(lead) \u{201C}Delia\u{201D} and \u{201C}Marco\u{201D}.")
        #expect(sentence(["Delia", "Marco", "Fox"]) == "\(lead) \u{201C}Delia\u{201D} and 2 more.")
        #expect(sentence(["Delia", "Margaret Thompson-Rivera"]) == "\(lead) \u{201C}Delia\u{201D} and 1 more.")
        #expect(sentence(["Northwest Regional Office"]) == "\(lead) the term below.")
        #expect(sentence(["Northwest Regional Office", "Margaret Thompson-Rivera"]) == "\(lead) the terms below.")
        #expect(sentence([]) == "\(lead) the term below.")
        // Whitespace collapses and a case repeat counts once.
        #expect(sentence(["Delia", "delia", "De  lia"]) == "\(lead) \u{201C}Delia\u{201D} and \u{201C}De lia\u{201D}.")
        for terms in [["a"], ["Delia", "Marco"], ["Delia", "x", "y"], [String(repeating: "x", count: 40)]] {
            #expect((sentence(terms) ?? "").count <= Results.mastheadSentenceLimit)
        }
    }

    @Test("ATTENTION quotes only the three term checks; the term sentence wins over a re-check row")
    func attentionIdentityKeyed() {
        let line = SearchRecheckQueryLine(label: "\u{201C}Delia\u{201D}", foundCount: 2, foundHitCap: false,
                                          appliedCount: 1, remainingCount: 1, route: .textLayer)
        let recheck = Self.row(.attention("a"), .searchRecheck, terms: ["Delia"], pages: [0], lines: [line])
        let recheckOnly = Self.report(.attention("a"), [recheck])
        #expect(Results.mastheadSubtitle(report: recheckOnly)
                == "\(Self.keepEditing) and run your search again with OCR on.")
        #expect(Results.mastheadSubtitleIsPrivacySensitive(report: recheckOnly) == false)
        let both = Self.report(.attention("a"), [Self.row(.attention("a"), .ocrCheck, terms: ["Fox"]), recheck])
        #expect(Results.mastheadSubtitle(report: both)
                == "\(Self.keepEditing), then use text\u{00A0}search to redact \u{201C}Fox\u{201D}.")
        #expect(Results.mastheadSubtitleIsPrivacySensitive(report: both))
        #expect(Results.reviewTermTexts(report: both) == ["Fox"])
        #expect(Results.mastheadSubtitleIsPrivacySensitive(report: Fixtures.searchableAttentionLong) == false)
    }

    @Test("Output missing: the arms that name Preview or Run Verification give way; the others stay")
    func outputMissingSubstitution() {
        let missing = "\(Self.keepEditing), then run Redact again to share the PDF."
        #expect(Results.mastheadSubtitle(report: Fixtures.secureAllPass, outputExists: false) == missing)
        #expect(Results.mastheadSubtitle(report: Fixtures.secureSkippedOff, outputExists: false) == missing)
        #expect(Results.mastheadSubtitle(report: Fixtures.secureFail, outputExists: false)
                == Results.mastheadSubtitle(report: Fixtures.secureFail))
        #expect(Results.mastheadSubtitle(report: Fixtures.secureScreenshot, outputExists: false)
                == "Read the note in Verification Details before you share the PDF.")
    }

    @Test("The run's mode: Secure only when every page rasterized with no fallback reason")
    func runMode() {
        let secure: [PipelineMode] = [.secureRasterization, .secureRasterization]
        #expect(Results.RunMode.of(perPageModes: secure, fallbackReasons: []) == .secure)
        #expect(Results.RunMode.of(perPageModes: secure, fallbackReasons: [nil, .verticalText]) == .searchableOrUnknown)
        #expect(Results.RunMode.of(perPageModes: [.searchableRedaction], fallbackReasons: []) == .searchableOrUnknown)
        #expect(Results.RunMode.of(perPageModes: [], fallbackReasons: []) == .searchableOrUnknown)
    }

    // MARK: - The spoken label

    @Test("The spoken label: the title, the counts with their clauses, the sentence")
    func spokenLabel() {
        #expect(Results.mastheadAccessibilityLabel(report: Fixtures.secureFail)
                == "Checks Failed. 6 of 7 checks passed. 1\u{00A0}failed. \(Self.keepEditing) to fix what failed, "
                + "or share after review.")
        #expect(Results.mastheadAccessibilityLabel(report: Fixtures.searchableAllRasterized)
                == "Checks Passed. 9 of 12 checks passed. 3\u{00A0}had nothing to check. "
                + "Look over the redacted PDF in Preview before you share it.")
        #expect(Results.mastheadAccessibilityLabel(report: Fixtures.pageCountGate)
                == "Checks Failed. 0 of 1 check passed. 1\u{00A0}failed. \(Self.keepEditing) and run Redact again; "
                + "the other checks did not run.")
        #expect(Results.mastheadAccessibilityLabel(report: Fixtures.secureSkippedOff, mode: .secure)
                == "Verification Skipped. Off in Settings. Run\u{00A0}Verification below before you share the PDF.")
    }

    // MARK: - The completion line and the gate run

    @Test("The completion line: duration and checks, the minutes form, the gate's stop")
    func completionLine() {
        #expect(Results.completionLineText(report: Fixtures.secureAllPass) == "Completed in 4.1 seconds · 7 checks")
        #expect(Results.completionLineText(report: Fixtures.searchableAttentionLong)
                == "Completed in 5 min 12 s · 12 checks")
        #expect(Results.completionLineText(report: Fixtures.pageCountGate) == "Stopped at the Page Count check.")
        #expect(Results.completionLineText(report: VerificationReport(
            layers: [Self.row(.pass, .ocrCheck)], overallStatus: .pass, durationSeconds: 0.04))
                == "Completed in under 0.1 seconds · 1 check")
        #expect(Results.isPageCountGateRun(Fixtures.pageCountGate))
        #expect(!Results.isPageCountGateRun(Self.report(.fail("f"), [Self.row(.fail("f"), nil)])))
        #expect(Results.minutesText(120.4) == "2 min 0 s")
    }

    @Test("No masthead string makes an outcome promise")
    func mastheadStringsAreMechanismWorded() throws {
        let stems = try Regex(#"\b(guarantee[ds]?|ensure[ds]?|impossible|find(?:s|ing)?|catch(?:es|ing)?|perfectly|flawlessly|best)\b|100%"#).ignoresCase() // LegalPhrases:safe (test data — the ban list itself)
        var strings = Self.fixtureSentences.map(\.1) + [Results.outputMissingSentence, Results.shareConfirmHint,
                                                         Results.keepEditingBodyText, Results.keepEditingAccessibilityLabel]
        for reason in [VerificationReport.SkipReason.autoVerifyOff, .cancelled, .error] {
            strings += [Results.skippedSubtitle(reason: reason, mode: .secure), Results.skippedSubtitle(reason: reason)]
        }
        for string in strings {
            let lower = string.lowercased()
            for term in LegalPhrases.bannedTerms {
                #expect(!lower.contains(term), "\(string) contains \(term)")
            }
            #expect(string.firstMatch(of: stems) == nil, "\(string)")
            #expect(!string.contains("!"))
        }
    }
}
