import Foundation
import PDFKit
import Testing
import CryptoKit
@testable import RedactionEngine

// H3.4 — the regex-safety runner (1.2 instrumentation plan §6).
//
// Feeds BOTH regex corpora through the product's full safety pipeline —
// `RegexSafetyPrecheck.isLikelyPathological` → `validateRegexPatternWithError`
// (length cap, precheck, nested-quantifier heuristic, ICU compile) →
// `RegexSentinelCheck.validate` (200 ms sentinel probe) — and times a bounded
// execution of every accepted pattern against representative text with the
// `perPageRegexTimeout` (5 s) discipline the search path applies:
//
//   - `Fixtures/fuzz/redos_payloads.json` (adversarial, T-existing): every
//     row must end REJECTED or BOUNDED — an accepted pattern that outruns
//     the budget on its own attacker input is the failure the sentinel
//     exists to prevent (M12-15 adversarial leg).
//   - `Fixtures/fuzz/benign_regexes.json` (T3.2, own-authored realistic
//     user shapes): the benign-rejection rate is the M12-15 headline;
//     `borderline`-labeled rows are counted in the rate AND sliced
//     separately (they sit on the conservative-precheck boundary by
//     design).
//
// Execution watchdog: an accepted-but-catastrophic pattern spins inside a
// synchronous ICU call that nothing can interrupt (the RegexSentinelCheck
// contract), so timed executions run on a detached task with a deadline
// waiter — on timeout the row records unbounded and the spinning task is
// ORPHANED (same trade the product sentinel makes; bounded by process
// lifetime, and the adversarial corpus is 32 rows).
//
// MEASUREMENT HARNESS: env-gated (RESECTA_REGEX_OUT, with the
// TEST_RUNNER_-prefixed form xcodebuild forwards), never in the batched gate.

@Suite("H3.4 regex-safety runner (standing emitter)", .serialized)
struct RegexSafetyRunnerTests {

    // MARK: - Env gate

    static func regexOut() -> String? {
        let e = ProcessInfo.processInfo.environment
        if let p = e["RESECTA_REGEX_OUT"], !p.isEmpty { return p }
        if let p = e["TEST_RUNNER_RESECTA_REGEX_OUT"], !p.isEmpty { return p }
        return nil
    }

    /// Optional second benign yardstick: a JSON file in the benign corpus
    /// shape (`patterns: [{id, pattern, pattern_class}]`) drawn OUTSIDE the
    /// repository — a dev-time sample of a third-party regex corpus that is
    /// never a fixture. Absent → the addendum is skipped, never red.
    static func regexSample() -> String? {
        let e = ProcessInfo.processInfo.environment
        if let p = e["RESECTA_REGEX_SAMPLE"], !p.isEmpty { return p }
        if let p = e["TEST_RUNNER_RESECTA_REGEX_SAMPLE"], !p.isEmpty { return p }
        return nil
    }

    // MARK: - Corpora

    struct AdversarialRow: Decodable {
        let id: String
        let pattern_class: String
        let target_regex_shape: String
        let attacker_input: String
        let expected_behavior: String
    }
    struct AdversarialFile: Decodable {
        let payloads: [AdversarialRow]
    }
    struct BenignRow: Decodable {
        let id: String
        let pattern: String
        let pattern_class: String
        let borderline: Bool?
    }
    struct BenignFile: Decodable {
        let patterns: [BenignRow]
    }

    static func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "fuzz"),
            "\(name).json missing from the test bundle")
        return try Data(contentsOf: url)
    }

    // MARK: - Output rows

    struct RowOut: Encodable {
        let id: String
        let corpus: String              // "adversarial" | "benign"
        let pattern_class: String
        let pattern_sha256: String
        let borderline: Bool
        let precheck_flagged: Bool
        let precheck_us: Double
        let validate_error: String?     // nil = compiled
        let sentinel_ok: Bool
        let sentinel_ms: Double
        let accepted: Bool              // full-pipeline verdict (sentinel)
        let exec_ms: Double?            // accepted rows only
        let exec_timed_out: Bool
        let budget_ms: Double
        let false_reject: Bool          // benign AND not accepted
    }
    struct SummaryOut: Encodable {
        let benign_total: Int
        let benign_rejected: Int
        let benign_reject_rate: Double
        let benign_rejected_ids: [String]
        let benign_borderline_total: Int
        let benign_borderline_rejected: Int
        let benign_nonborderline_rejected: Int
        let adversarial_total: Int
        let adversarial_rejected: Int
        let adversarial_executed_bounded: Int
        let adversarial_unbounded: Int
        let exec_budget_ms: Double
        let sentinel_budget_ms: Double
    }
    struct FileOut: Encodable {
        let schema_version: Int
        let generated_by: String
        let adversarial_sha256: String
        let benign_sha256: String
        let rows: [RowOut]
        let summary: SummaryOut
    }

    struct SampleSummaryOut: Encodable {
        let total: Int
        let rejected: Int
        let reject_rate: Double
        let rejected_ids: [String]
        let exec_timed_out_ids: [String]
        let rejection_by_stage: [String: Int]
    }
    struct SampleFileOut: Encodable {
        let schema_version: Int
        let generated_by: String
        let sample_sha256: String
        let sample_file: String
        let rows: [RowOut]
        let summary: SampleSummaryOut
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Timed, watchdogged execution (sentinel's orphan trade)

    static let execBudget: Duration = DocumentSearcher.perPageRegexTimeout

    /// Runs `regex.enumerateMatches` over `text` with the search path's
    /// `.reportProgress` + deadline bail, on a detached task raced against
    /// a deadline waiter. Returns (wall ms, timedOut).
    static func timedExecution(pattern: String, text: String) async -> (ms: Double, timedOut: Bool) {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func setIfUnset() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let start = ContinuousClock.now
        return await withCheckedContinuation { (cont: CheckedContinuation<(Double, Bool), Never>) in
            let flag = Flag()
            Task.detached {
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    if flag.setIfUnset() { cont.resume(returning: (0, false)) }
                    return
                }
                let ns = text as NSString
                let deadline = ContinuousClock.now + RegexSafetyRunnerTests.execBudget
                regex.enumerateMatches(
                    in: text,
                    options: [.reportProgress],
                    range: NSRange(location: 0, length: ns.length)
                ) { _, _, stop in
                    if ContinuousClock.now >= deadline { stop.pointee = true }
                }
                let elapsed = ContinuousClock.now - start
                let ms = Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15
                if flag.setIfUnset() { cont.resume(returning: (ms, false)) }
            }
            Task.detached {
                try? await Task.sleep(for: RegexSafetyRunnerTests.execBudget + .seconds(1))
                if flag.setIfUnset() {
                    let elapsed = ContinuousClock.now - start
                    let ms = Double(elapsed.components.seconds) * 1000
                        + Double(elapsed.components.attoseconds) / 1e15
                    cont.resume(returning: (ms, true))
                }
            }
        }
    }

    static func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    /// Full pipeline verdict for one pattern; executes accepted patterns
    /// against `execText`.
    static func gradePattern(
        id: String, corpus: String, cls: String, pattern: String,
        borderline: Bool, execText: String
    ) async -> RowOut {
        let clock = ContinuousClock()

        let t0 = clock.now
        let flagged = RegexSafetyPrecheck.isLikelyPathological(pattern)
        let precheckElapsed = clock.now - t0
        let precheckUS = Double(precheckElapsed.components.seconds) * 1e6
            + Double(precheckElapsed.components.attoseconds) / 1e12

        var validateError: String? = nil
        do {
            _ = try DocumentSearcher.validateRegexPatternWithError(pattern)
        } catch let e as RegexValidationError {  // LegalPhrases:safe (Swift keyword)
            switch e {
            case .patternTooLong: validateError = "patternTooLong"
            case .likelyPathological: validateError = "likelyPathological"
            case .nestedQuantifiers: validateError = "nestedQuantifiers"
            case .nestedBoundProduct: validateError = "nestedBoundProduct"
            }
        } catch {  // LegalPhrases:safe (Swift keyword)
            validateError = "compile: \((error as NSError).localizedDescription)"
        }

        let t1 = clock.now
        let sentinelOK = await RegexSentinelCheck.validate(pattern)
        let sentinelElapsed = clock.now - t1
        let sentinelMS = Double(sentinelElapsed.components.seconds) * 1000
            + Double(sentinelElapsed.components.attoseconds) / 1e15

        var execMS: Double? = nil
        var timedOut = false
        if sentinelOK {
            let (ms, out) = await timedExecution(pattern: pattern, text: execText)
            execMS = r3(ms)
            timedOut = out
        }

        let budgetMS = Double(execBudget.components.seconds) * 1000
        return RowOut(
            id: id, corpus: corpus, pattern_class: cls,
            pattern_sha256: sha(Data(pattern.utf8)),
            borderline: borderline,
            precheck_flagged: flagged,
            precheck_us: r3(precheckUS),
            validate_error: validateError,
            sentinel_ok: sentinelOK,
            sentinel_ms: r3(sentinelMS),
            accepted: sentinelOK,
            exec_ms: execMS,
            exec_timed_out: timedOut,
            budget_ms: budgetMS,
            false_reject: corpus == "benign" && !sentinelOK)
    }

    // MARK: - The emit

    @Test("Emit regex-safety verdicts over the adversarial + benign corpora")
    func emitRegexSafety() async throws {
        guard let out = Self.regexOut() else {
            TestGate.skip("[H3.4] RESECTA_REGEX_OUT unset — the regex-safety runner was not requested")
            return
        }
        let advData = try Self.fixtureData("redos_payloads")
        let benData = try Self.fixtureData("benign_regexes")
        let adversarial = try JSONDecoder().decode(AdversarialFile.self, from: advData).payloads
        let benign = try JSONDecoder().decode(BenignFile.self, from: benData).patterns

        // Representative benign-execution text: packet page 0's text layer.
        var packetText = ""
        if let url = Bundle.module.url(
            forResource: "packet", withExtension: "pdf", subdirectory: "TestResources"),
           let doc = PDFDocument(url: url), let page = doc.page(at: 0) {
            packetText = page.string ?? ""
        }
        #expect(!packetText.isEmpty, "packet page-0 text must load for benign execution")

        var rows: [RowOut] = []

        for row in benign {
            let graded = await Self.gradePattern(
                id: row.id, corpus: "benign", cls: row.pattern_class,
                pattern: row.pattern, borderline: row.borderline ?? false,
                execText: packetText)
            rows.append(graded)
        }
        for row in adversarial {
            let graded = await Self.gradePattern(
                id: row.id, corpus: "adversarial", cls: row.pattern_class,
                pattern: row.target_regex_shape, borderline: false,
                execText: row.attacker_input)
            rows.append(graded)
        }

        let ben = rows.filter { $0.corpus == "benign" }
        let adv = rows.filter { $0.corpus == "adversarial" }
        let benRejected = ben.filter { !$0.accepted }
        let advRejected = adv.filter { !$0.accepted }
        let advBounded = adv.filter { $0.accepted && !$0.exec_timed_out }
        let advUnbounded = adv.filter { $0.accepted && $0.exec_timed_out }

        // The adversarial contract is a hard assert: rejected or bounded.
        #expect(advUnbounded.isEmpty,
                "adversarial patterns must be rejected or budget-bounded: \(advUnbounded.map(\.id))")
        // Benign executions must never hit the page budget.
        let benTimedOut = ben.filter { $0.exec_timed_out }
        #expect(benTimedOut.isEmpty,
                "benign patterns must execute within the page budget: \(benTimedOut.map(\.id))")

        let summary = SummaryOut(
            benign_total: ben.count,
            benign_rejected: benRejected.count,
            benign_reject_rate: ben.isEmpty ? 0
                : (Double(benRejected.count) / Double(ben.count) * 1e6).rounded() / 1e6,
            benign_rejected_ids: benRejected.map(\.id).sorted(),
            benign_borderline_total: ben.filter(\.borderline).count,
            benign_borderline_rejected: benRejected.filter(\.borderline).count,
            benign_nonborderline_rejected: benRejected.filter { !$0.borderline }.count,
            adversarial_total: adv.count,
            adversarial_rejected: advRejected.count,
            adversarial_executed_bounded: advBounded.count,
            adversarial_unbounded: advUnbounded.count,
            exec_budget_ms: Double(Self.execBudget.components.seconds) * 1000,
            sentinel_budget_ms: 200)

        try Self.writeJSON(FileOut(
            schema_version: 1,
            generated_by: "RegexSafetyRunnerTests (H3.4)",
            adversarial_sha256: Self.sha(advData),
            benign_sha256: Self.sha(benData),
            rows: rows,
            summary: summary), to: "\(out)/regex-safety.json")

        print("[H3.4] benign \(benRejected.count)/\(ben.count) rejected "
              + "(borderline \(benRejected.filter(\.borderline).count)); "
              + "adversarial \(advRejected.count) rejected / \(advBounded.count) bounded "
              + "/ \(advUnbounded.count) UNBOUNDED")

        try await Self.emitSample(out: out, execText: packetText)
    }

    /// The optional second yardstick (see `regexSample`): every row graded
    /// through the same pipeline against the same execution text, reported
    /// beside — never merged into — the corpus numbers. No hard assertion:
    /// the sample is a statistic, not a contract.
    static func emitSample(out: String, execText: String) async throws {
        guard let samplePath = Self.regexSample() else {
            print("[H3.4] RESECTA_REGEX_SAMPLE not set; the sample addendum skipped.")
            return
        }
        let sampleData = try Data(contentsOf: URL(fileURLWithPath: samplePath))
        let sample = try JSONDecoder().decode(BenignFile.self, from: sampleData).patterns
        var rows: [RowOut] = []
        for row in sample {
            rows.append(await Self.gradePattern(
                id: row.id, corpus: "sample", cls: row.pattern_class,
                pattern: row.pattern, borderline: false, execText: execText))
        }
        let rejected = rows.filter { !$0.accepted }
        var byStage: [String: Int] = [:]
        for row in rejected {
            let stage = row.validate_error.map { $0.hasPrefix("compile") ? "compile" : $0 } ?? "sentinel"
            byStage[stage, default: 0] += 1
        }
        let summary = SampleSummaryOut(
            total: rows.count,
            rejected: rejected.count,
            reject_rate: rows.isEmpty ? 0
                : (Double(rejected.count) / Double(rows.count) * 1e6).rounded() / 1e6,
            rejected_ids: rejected.map(\.id).sorted(),
            exec_timed_out_ids: rows.filter(\.exec_timed_out).map(\.id).sorted(),
            rejection_by_stage: byStage)
        try Self.writeJSON(SampleFileOut(
            schema_version: 1,
            generated_by: "RegexSafetyRunnerTests (H3.4 sample addendum)",
            sample_sha256: Self.sha(sampleData),
            sample_file: URL(fileURLWithPath: samplePath).lastPathComponent,
            rows: rows,
            summary: summary), to: "\(out)/regex-safety-sample.json")
        print("[H3.4] sample \(rejected.count)/\(rows.count) rejected; "
              + "stages \(byStage); exec timed out \(summary.exec_timed_out_ids.count)")
    }
}
