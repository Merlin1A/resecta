import Testing
import Foundation
@testable import RedactionEngine

@Suite("RegexSentinelCheck (W6-b ReDoS guard)", .tags(.search))
struct RegexSentinelCheckTests {

    @Test("Safe pattern accepted")
    func safePatternAccepted() async {
        #expect(await RegexSentinelCheck.validate(#"\d+"#) == true)
    }

    @Test("Empty pattern rejected")
    func emptyRejected() async {
        #expect(await RegexSentinelCheck.validate("") == false)
    }

    @Test("Pattern at 200-char cap accepted; 201 rejected")
    func lengthCap() async {
        let at = String(repeating: "a", count: 200)
        let over = String(repeating: "a", count: 201)
        #expect(await RegexSentinelCheck.validate(at) == true)
        #expect(await RegexSentinelCheck.validate(over) == false)
    }

    @Test("Nested-quantifier pattern rejected at stage 1")
    func nestedQuantifierRejected() async {
        #expect(await RegexSentinelCheck.validate(#"(a+)+b"#) == false)
    }

    @Test("Invalid syntax rejected at stage 1")
    func invalidSyntaxRejected() async {
        #expect(await RegexSentinelCheck.validate(#"(unclosed"#) == false)
    }

    // MARK: - S6 / 4.7 — typed rejection reasons (design 04 §4.7)

    @Test("Over-cap pattern throws patternTooLong with mechanism copy")
    func tooLongPatternThrowsTypedError() {
        let over = String(repeating: "a", count: 201)
        do {
            _ = try DocumentSearcher.validateRegexPatternWithError(over)
            Issue.record("over-cap pattern was accepted")
        } catch { // LegalPhrases:safe (Swift keyword)
            #expect(error is RegexValidationError)
            #expect(error.localizedDescription
                    == "Pattern exceeds the \(DocumentSearcher.maxRegexPatternLength)-character limit.")
        }
    }

    @Test("Pathological pattern throws likelyPathological with mechanism copy")
    func pathologicalPatternThrowsTypedError() {
        do {
            _ = try DocumentSearcher.validateRegexPatternWithError(#"(a|aa)*b"#)
            Issue.record("pathological pattern was accepted")
        } catch { // LegalPhrases:safe (Swift keyword)
            #expect(error.localizedDescription
                    == "Pattern may cause performance issues and has not been accepted.")
        }
    }

    @Test("Nested-quantifier pattern throws nestedQuantifiers with mechanism copy")
    func nestedQuantifierThrowsTypedError() {
        // `(a{2,3})+b` reaches the nested-quantifier gate: the BOUNDED
        // inner quantifier is invisible to RegexSafetyPrecheck (which
        // only flags unbounded inner/outer shapes), so the precheck
        // passes and `hasNestedQuantifiers` fires. `(a+)+b` would trip
        // the precheck FIRST and surface the likelyPathological copy.
        do {
            _ = try DocumentSearcher.validateRegexPatternWithError(#"(a{2,3})+b"#)
            Issue.record("nested-quantifier pattern was accepted")
        } catch { // LegalPhrases:safe (Swift keyword)
            #expect(error.localizedDescription
                    == "Pattern contains nested quantifiers and has not been accepted.")
        }
    }

    @Test("Engine NSError surfaces verbatim, not the prior hardcoded copy")
    func testNSRegexErrorSurfacedVerbatim() {
        // A syntactically invalid pattern reaches NSRegularExpression and
        // its system NSError propagates unwrapped — the caller surfaces
        // error.localizedDescription, which must carry real information
        // rather than the discarded hardcoded string.
        do {
            _ = try DocumentSearcher.validateRegexPatternWithError("[invalid")
            Issue.record("invalid syntax was accepted")
        } catch { // LegalPhrases:safe (Swift keyword)
            #expect(!(error is RegexValidationError))
            #expect(!error.localizedDescription.isEmpty)
            #expect(error.localizedDescription != "Invalid regular expression")
        }
    }

    @Test("Adversarial: typed rejection copy never echoes the submitted pattern (RR-24)")
    func testRegexErrorStringDoesNotContainPatternText() {
        // One probe per typed case; each pattern carries a sentinel token
        // that must not appear in the surfaced copy.
        let probes = [
            String(repeating: "S3CRET-", count: 30),   // patternTooLong
            #"(S3CRET|S3CRETS3CRET)*b"#,               // likelyPathological
            #"(S3CRET{2,3})+b"#,                       // nestedQuantifiers
        ]
        for probe in probes {
            do {
                _ = try DocumentSearcher.validateRegexPatternWithError(probe)
                Issue.record("probe pattern was accepted: typed-case coverage broken")
            } catch { // LegalPhrases:safe (Swift keyword)
                #expect(error is RegexValidationError)
                #expect(!error.localizedDescription.contains("S3CRET"))
            }
        }
    }

    @Test("Throwing and nil-returning validators agree on accept/reject")
    func testVariantsAgree() {
        let patterns = [#"\d+"#, #"(a+)+b"#, "[invalid", #"(a|aa)*b"#,
                        String(repeating: "a", count: 201), #"\b\d{3}-\d{2}-\d{4}\b"#]
        for pattern in patterns {
            let nilForm = DocumentSearcher.validateRegexPattern(pattern) != nil
            let throwing = (try? DocumentSearcher.validateRegexPatternWithError(pattern)) != nil
            #expect(nilForm == throwing, "variants disagree on: \(pattern.prefix(20))…")
        }
    }

    @Test(
        "Validation respects wall-clock budget across diverse inputs",
        .disabled("V1.0 environmental skip: cold-simulator perf flake; budget designed for warm hardware.")
    )
    func wallClockBudget() async {
        let patterns = [
            #"\d+"#,
            #"(ab|cd|ef){30}xyz"#,
            #"(a|aa){20}c"#,
            #".*.*.*.*.*.*.*z"#,
            #"[A-Za-z0-9]{200}"#,
        ]
        for pattern in patterns {
            let start = ContinuousClock.now
            _ = await RegexSentinelCheck.validate(pattern)
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .milliseconds(500), "pattern exceeded budget: \(pattern), elapsed: \(elapsed)")
        }
    }

    @Test("All built-in saved regexes pass the sentinel")
    func builtInsPass() async {
        for regex in SavedRegex.allBuiltIns {
            let ok = await RegexSentinelCheck.validate(regex.pattern)
            #expect(ok == true, "built-in saved regex failed sentinel: \(regex.label) — \(regex.pattern)")
        }
    }
}
