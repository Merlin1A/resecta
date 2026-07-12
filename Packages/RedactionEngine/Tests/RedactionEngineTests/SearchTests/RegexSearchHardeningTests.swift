import Testing
import PDFKit
@testable import RedactionEngine

// F-001 — Sync `validateRegexPattern` rejects catastrophic shapes that
// compile cleanly under the legacy `hasNestedQuantifiers` heuristic, plus
// a cancellation-propagation check that exercises the `.reportProgress`
// path through the full-scan branch.

@Suite("Regex search hardening (F-001)", .tags(.search))
struct RegexSearchHardeningTests {

    // MARK: - Validation rejects catastrophic shapes

    @Test("validateRegexPattern rejects `(a+)+b`")
    func rejectsNestedPlus() {
        #expect(DocumentSearcher.validateRegexPattern("(a+)+b") == nil)
    }

    @Test("validateRegexPattern rejects `(ab|abc)*xyz`")
    func rejectsAlternationStar() {
        #expect(DocumentSearcher.validateRegexPattern("(ab|abc)*xyz") == nil)
    }

    @Test("validateRegexPattern rejects `(a|aa)*b`")
    func rejectsOverlappingAlternationStar() {
        #expect(DocumentSearcher.validateRegexPattern("(a|aa)*b") == nil)
    }

    @Test("validateRegexPattern rejects `(a|ab)+b` (overlapping alternation under +)")
    func rejectsOverlappingAlternationPlus() {
        #expect(DocumentSearcher.validateRegexPattern("(a|ab)+b") == nil)
    }

    @Test("validateRegexPattern rejects `(a+|b+)+` (alternation of quantifiers)")
    func rejectsAlternatedQuantifiers() {
        #expect(DocumentSearcher.validateRegexPattern("(a+|b+)+") == nil)
    }

    @Test("validateRegexPattern rejects `(a|b){2,}` (group with unbounded open brace)")
    func rejectsOpenBraceOverAlternation() {
        #expect(DocumentSearcher.validateRegexPattern("(a|b){2,}") == nil)
    }

    // MARK: - Validation still accepts safe shapes

    @Test(#"validateRegexPattern accepts `\d{3}-\d{2}-\d{4}` (SSN shape)"#)
    func acceptsSSNShape() {
        #expect(DocumentSearcher.validateRegexPattern(#"\d{3}-\d{2}-\d{4}"#) != nil)
    }

    @Test("validateRegexPattern accepts bounded `(a|b){1,10}`")
    func acceptsBoundedAlternation() {
        #expect(DocumentSearcher.validateRegexPattern("(a|b){1,10}") != nil)
    }

    @Test("validateRegexPattern accepts all built-in saved regex patterns")
    func acceptsBuiltInRegexes() {
        for regex in SavedRegex.allBuiltIns {
            #expect(
                DocumentSearcher.validateRegexPattern(regex.pattern) != nil,
                "built-in failed validation: \(regex.label) — \(regex.pattern)"
            )
        }
    }

    // MARK: - Cancellation propagation via `.reportProgress`

    /// Multi-page PDF with enough text-layer characters per page that a
    /// regex sweep takes long enough to observe cancellation. Each page
    /// carries ~1.2KB of `alpha` repetitions to give `enumerateMatches`
    /// time to invoke its progress closure.
    private func longTextPDF(pageCount: Int) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let body = String(repeating: "alpha ", count: 200)
        return renderer.pdfData { context in
            for _ in 0..<pageCount {
                context.beginPage()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10),
                    .foregroundColor: UIColor.black
                ]
                (body as NSString).draw(at: CGPoint(x: 36, y: 36), withAttributes: attrs)
            }
        }
    }

    @Test("Cancellation propagates through `.reportProgress` on a long-running scan")
    func cancellationPropagatesQuickly() async throws {
        let data = longTextPDF(pageCount: 8)
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        // Force an effectively-immediate per-page timeout so the search
        // task short-circuits via the same code path a real cancellation
        // would take. `.reportProgress` is what lets the engine invoke
        // the closure between match attempts so the timeout actually
        // samples. The sink fires once per affected page; observing
        // any value from this PDF confirms the in-loop check ran.
        let searcher = DocumentSearcher(regexTimeoutOverride: .nanoseconds(1))
        let pages = TimeoutCollector()
        await searcher.setRegexTimeoutSink({ page in
            Task { await pages.append(page) }
        })

        let mode = SearchMode.regex("alpha", options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        let start = ContinuousClock.now
        for await _ in stream { }
        let elapsed = ContinuousClock.now - start

        // Wall-clock sanity bound. The meaningful assertion is the
        // sink-fired check below — this one only rejects the "did not
        // bail at all" regression (production worst case for 8 pages
        // at the 5-second per-page ceiling is 40s). The 15s headroom
        // absorbs `Task.yield` jitter when Swift Testing runs other
        // suites concurrently on the iPhone 17 simulator, where the
        // tight 5s budget previously tripped intermittently around
        // the 5.4–5.6s mark.
        #expect(elapsed < .seconds(15), "search did not bail in time; elapsed: \(elapsed)")

        try await Task.sleep(for: .milliseconds(50))
        let observed = await pages.snapshot()
        #expect(!observed.isEmpty, "expected timeout sink to fire on at least one page; observed=\(observed)")
    }

    // MARK: - Package C — `UserTermMatcher.alwaysFlagHits` runtime defense

    /// Build a `UserTermMatcher` whose always-flag list bypasses
    /// `validateRegexPattern` so a known-pathological shape (catastrophic
    /// backtracking) can exercise the runtime timeout path directly.
    /// Production constructs `CompiledUserTerm` via `UserTermMatcher.compile`,
    /// which gates regex compilation through `validateRegexPattern`; tests
    /// touch the internal init under `@testable import` so the runtime
    /// timeout + cancellation paths stay testable for regression coverage.
    private func makeMatcher(alwaysFlagPatterns: [String]) -> UserTermMatcher {
        let terms = alwaysFlagPatterns.compactMap { pattern -> CompiledUserTerm? in
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            return CompiledUserTerm(
                pattern: pattern,
                regex: regex,
                normalizedLiteral: nil
            )
        }
        return UserTermMatcher(alwaysFlag: terms, neverFlag: [])
    }

    @Test("alwaysFlagHits surfaces a timeout via the `.reportProgress` path")
    func alwaysFlagHitsTimesOutOnPathologicalPattern() {
        // The F-001 anchor mandates `[.reportProgress]` so the enumerator
        // fires the per-match closure BETWEEN match attempts on long
        // walks. This test pins that wiring: a simple `a` pattern over a
        // long `aaaa…` body produces many fast match attempts; the
        // closure's `ContinuousClock` check trips somewhere mid-walk and
        // the timeout exit records the pattern in `timedOutPatterns`. A
        // wiring regression that drops `[.reportProgress]` (the audit's
        // §1.1.a defect) makes the closure never fire on long alternation
        // walks — the function runs to completion and `timedOutPatterns`
        // stays empty.
        //
        // True catastrophic backtracking inside a SINGLE match attempt
        // is uninterruptible by `.reportProgress` and remains the domain
        // of `DocumentSearcher.validateRegexPattern` (see the rejection
        // suite above) — not what this runtime defense covers.
        //
        // The override must be large enough that the outer-loop
        // `ContinuousClock` pre-check (which trips at the top of each
        // term iteration in `alwaysFlagHits`) doesn't short-circuit
        // before the regex enumerator runs. 1 ms clears that nanosecond-
        // scale overhead while staying well inside the production 5 s
        // budget. The body is sized so the inner check fires reliably.
        let pattern = "a"
        let matcher = makeMatcher(alwaysFlagPatterns: [pattern])
        let pageText = String(repeating: "a", count: 200_000)

        let start = ContinuousClock.now
        let result = matcher.alwaysFlagHits(
            in: pageText,
            timeoutOverride: .milliseconds(1)
        )
        let elapsed = ContinuousClock.now - start

        #expect(
            elapsed < DocumentSearcher.perPageRegexTimeout,
            "alwaysFlagHits did not bail in time; elapsed: \(elapsed)"
        )
        #expect(
            result.timedOutPatterns.contains(pattern),
            "expected `\(pattern)` in timedOutPatterns; got: \(result.timedOutPatterns)"
        )
    }

    @Test("alwaysFlagHits respects Task cancellation")
    func alwaysFlagHitsRespectsTaskCancellation() async {
        let matcher = makeMatcher(alwaysFlagPatterns: ["a"])
        let pageText = String(repeating: "a", count: 1_000)

        // Pre-cancelling the wrapping task sets `Task.isCancelled` before
        // the body runs. The outer-loop check (or, if scheduling races,
        // the inner `.reportProgress` callback) sees it and bails before
        // the regex enumerator does substantial work.
        let task = Task {
            let start = ContinuousClock.now
            let result = matcher.alwaysFlagHits(in: pageText)
            let elapsed = ContinuousClock.now - start
            return (result, elapsed)
        }
        task.cancel()
        let (result, elapsed) = await task.value

        #expect(result.hits.isEmpty)
        #expect(result.timedOutPatterns.isEmpty)
        #expect(
            elapsed < DocumentSearcher.perPageRegexTimeout,
            "alwaysFlagHits did not observe cancellation in time; elapsed: \(elapsed)"
        )
    }

    @Test("alwaysFlagHits surfaces no timeout on a safe pattern")
    func alwaysFlagHitsNoTimeoutOnSafePattern() {
        let matcher = makeMatcher(alwaysFlagPatterns: [#"\d{3}-\d{2}-\d{4}"#])
        let pageText = "preface 123-45-6789 trailing 987-65-4321 tail"

        let result = matcher.alwaysFlagHits(in: pageText)

        #expect(result.timedOutPatterns.isEmpty)
        #expect(result.hits.count == 2)
    }
}

/// Sink target for the regex-timeout sink. Posting through an actor keeps
/// the test thread-safe under the @Sendable closure contract.
private actor TimeoutCollector {
    private var pages: [Int] = []
    func append(_ page: Int) { pages.append(page) }
    func snapshot() -> [Int] { pages }
}
