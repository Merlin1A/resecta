import CoreGraphics
import Foundation
import PDFKit
import Testing
import os
@testable import RedactionEngine

// PERF-7 — Stress-corpus baseline test.
//
// Builds the deterministic 500-page synthetic PDF, runs the engine
// per-page rasterize pipeline against every page, captures wall-clock
// duration and peak `os_proc_available_memory()` delta, and writes
// `stress-result.json` to the test output directory. When a committed
// `stress-baseline.json` is present (the canonical path is
// `Packages/RedactionEngine/Tests/RedactionEngineTests/IntegrationTests/StressTests/stress-baseline.json`),
// the test asserts the current run is within the wall-clock window
// (20%, M2) and the peak-memory window (30%, CAT-222) — both only on
// the baseline's recorded machine. Memory's wider window reflects its
// higher noise; on any machine other than the baseline's, both
// comparisons are documentary (withKnownIssue + log print,
// CAT-231), never failures.
//
// Note: This is a multi-minute run; not part of the default green-bar
// suite. Run it locally via `make stress-baseline`, which rewrites
// the committed JSON. There is no remote workflow.
//
// Mechanism-description language only (I6 §4 of shared-context):
// no outcome-promise vocabulary in user-visible strings or comments —
// the baseline is a regression guard, not a hard contract.

// Tag dedicated to long-running stress workloads. Defined inline here
// rather than in `Fixtures/TestHelpers.swift` so future tag additions
// stay close to the consuming suite — the existing tag block in
// TestHelpers.swift covers the security / sandwich / coordination
// taxonomy and adding a perf-only tag there would mix categories.
extension Tag {
    /// Long-running stress workloads — excluded from default runs.
    @Tag static var stress: Self
}

@Suite("PERF-7 Stress Corpus")
struct StressCorpusTests {

    /// Smoke test — fast (a single ~500-page write, no rasterization).
    /// Verifies the fixture builder is wired up before the long test.
    @Test("Fixture builder emits 500-page PDF", .tags(.stress))
    func testFixtureHas500Pages() throws {
        let url = try StressFixtureBuilder.buildStressFixture(
            pageCount: 500, seed: 42
        )
        defer { try? FileManager.default.removeItem(at: url) }

        guard let doc = PDFDocument(url: url) else {
            Issue.record("Failed to load stress fixture")
            return
        }
        #expect(doc.pageCount == 500)
        // Page 0 should have extractable text — confirms the fixture
        // produces a real text layer (not glyph outlines).
        if let first = doc.page(at: 0), let s = first.string {
            #expect(!s.isEmpty)
        } else {
            Issue.record("First page produced no string")
        }
    }

    /// Full pipeline run — captures metrics, writes result JSON,
    /// compares to baseline if present. Run-time budget is 30 min on
    /// the CI runner; locally on Apple silicon it lands well under
    /// that ceiling.
    ///
    /// Tagged `.stress` so it is excluded from the default green-bar
    /// runs (`--skip-tag stress`); explicit invocation via
    /// `-only-testing:RedactionEngineTests/StressCorpusTests/testStressCorpusBaseline()`
    /// (used by `make stress-baseline` and the nightly workflow) runs
    /// it. The Makefile target also passes
    /// `RESECTA_REPO_ROOT=$(pwd)` via Xcode's
    /// `-resultBundlePath`-adjacent env injection so the test can
    /// locate the committed baseline file.
    @Test("Stress corpus baseline — pipeline over 500 pages", .tags(.stress))
    func testStressCorpusBaseline() async throws {
        let url = try StressFixtureBuilder.buildStressFixture(
            pageCount: 500, seed: 42
        )
        defer { try? FileManager.default.removeItem(at: url) }

        guard let doc = PDFDocument(url: url) else {
            Issue.record("Stress fixture failed to load as PDFDocument")
            return
        }
        #expect(doc.pageCount == 500)

        let rasterizer = PageRasterizer()
        let startMemory = os_proc_available_memory()
        var peakMemoryDelta: Int = 0
        let clockStart = ContinuousClock.now

        // Two regions per page — header label + body block. These
        // exercise the fill + verify path that PERF-5 / PERF-6 will
        // optimise. Keeping them constant per page means the baseline
        // is reproducible from `(pageCount, seed)` alone.
        let perPageRegions: [RedactionRegion] = [
            RedactionRegion(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                normalizedRect: CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.04),
                source: .manual
            ),
            RedactionRegion(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                normalizedRect: CGRect(x: 0.10, y: 0.30, width: 0.60, height: 0.20),
                source: .manual
            )
        ]

        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            let pageData = PDFPageData(
                page: page,
                pageIndex: pageIndex,
                regions: perPageRegions,
                fillColor: .black,
                targetDPI: 150,  // 150 keeps the run inside the 30 min
                                 // CI budget; the pipeline still
                                 // exercises selectDPI / fill / verify
                                 // at this DPI.
                pipelineMode: .secureRasterization,
                rotation: page.rotation,
                // CAT-127: rasterize() now reads the pre-extracted geometry + CG page.
                cropBoxBounds: page.bounds(for: .cropBox),
                cgPage: page.pageRef,
                hasText: false
            )

            // Engine call. autoreleasepool inside the engine's
            // `rasterize` wraps the synchronous bitmap work — see
            // PageRasterizer.swift step 4–7. We avoid wrapping the
            // `await` in an autoreleasepool here because suspension
            // points inside an autoreleasepool block can defer the
            // ObjC release scope past the original boundary, which
            // is contrary to the intent of the scope.
            _ = try await rasterizer.rasterize(pageData, dpiCap: 150)

            let nowMemory = os_proc_available_memory()
            let delta = max(0, startMemory - nowMemory)
            if delta > peakMemoryDelta {
                peakMemoryDelta = delta
            }
        }

        let elapsed = clockStart.duration(to: ContinuousClock.now)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        let result = StressResult(
            wallClockSeconds: elapsedSeconds,
            peakMemoryBytes: peakMemoryDelta,
            pageCount: doc.pageCount,
            seed: 42,
            recordedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            machine: MachineSpec.current()
        )

        // Always emit the result JSON. The nightly workflow uploads
        // it as an artifact; the local `make stress-baseline` target
        // copies it over the committed baseline.
        let resultURL = stressResultURL()
        try writeStressJSON(result, to: resultURL)

        // Compare against the committed baseline if it exists.
        // First run on a new clone will skip the comparison and
        // record the result for review.
        if let baseline = loadCommittedBaseline() {
            let delta = (result.wallClockSeconds - baseline.wallClockSeconds)
                / max(baseline.wallClockSeconds, 0.0001)
            // M2 widened the perf budget from 10% to 20% per plan
            // §2 locked-decision (Performance). Wall-clock target on the
            // recorded machine: ≤ 1.2 × baseline. The window is one-sided
            // (a substantial speedup is worth a fresh baseline but does
            // not fail the test).
            //
            // Machine context: baseline.machine identifies the hardware
            // the comparison-target was recorded on. When current and
            // baseline machines disagree the wall-clock comparison is
            // documentary — re-derive the budget from a fresh baseline
            // on the current machine before treating a regression as
            // load-bearing. See plan §7 ("Machine pinning").
            let currentMachine = MachineSpec.current()
            let sameMachine = baseline.machine?.matches(currentMachine) ?? false
            if sameMachine {
                #expect(
                    delta < 0.20,
                    "Wall-clock regressed by \(Int(delta * 100))% vs baseline (current=\(result.wallClockSeconds)s baseline=\(baseline.wallClockSeconds)s)"
                )
                // CAT-222: memory regression window, asserted only on the
                // baseline's recorded machine (same gating logic as the
                // wall-clock window — cross-machine memory numbers are not
                // comparable, and the GitHub runner never matches by
                // design; the withKnownIssue branch below covers it). The
                // 30% window absorbs OS memory-pressure variance, which
                // is noisier than wall-clock jitter. Zero-valued baseline
                // means the committed JSON predates memory capture —
                // refresh with `make stress-baseline` before relying on it.
                if baseline.peakMemoryBytes > 0 {
                    let memDelta = Double(result.peakMemoryBytes - baseline.peakMemoryBytes)
                        / Double(baseline.peakMemoryBytes)
                    #expect(
                        memDelta < 0.30,
                        "Peak memory regressed by \(Int(memDelta * 100))% vs baseline (current=\(result.peakMemoryBytes)B baseline=\(baseline.peakMemoryBytes)B)"
                    )
                }
            } else {
                // CAT-231: these branches previously called Issue.record
                // directly, which in Swift Testing marks the test FAILED —
                // so every run on a machine that did not match the
                // committed baseline (every GitHub-hosted runner) failed
                // before the workflow's artifact/comment steps could use
                // the data. withKnownIssue marks the mismatch as expected:
                // the detail stays visible in the result bundle without
                // failing the run, and the print keeps the delta in the
                // plain-text CI log.
                let detail: String
                if let baselineMachine = baseline.machine {
                    detail = "Baseline recorded on \(baselineMachine.deviceModel); current run on \(currentMachine.deviceModel). Wall-clock delta \(Int(delta * 100))% is documentary only — refresh the baseline with `make stress-baseline` on this machine."
                } else {
                    detail = "Baseline JSON predates the machine schema; current wall-clock=\(result.wallClockSeconds)s — refresh the baseline with `make stress-baseline` on this machine."
                }
                withKnownIssue("Machine mismatch — baseline comparison is documentary (CAT-231)") {
                    Issue.record(Comment(rawValue: detail))
                }
                print("[stress documentary] wall-clock delta vs baseline: \(Int(delta * 100))% (current=\(result.wallClockSeconds)s baseline=\(baseline.wallClockSeconds)s; peakMemory current=\(result.peakMemoryBytes)B baseline=\(baseline.peakMemoryBytes)B)")
            }
        }
    }

    // MARK: - Result IO

    private func stressResultURL(testFile: String = #filePath) -> URL {
        // Prefer the source-tree directory (so `make stress-baseline`
        // can `mv` the result over the baseline without searching
        // a temp path). If the source-tree path is not writable
        // (stripped CI build), fall back to NSTemporaryDirectory and
        // emit the standard env var the workflow consumes.
        let sourceTreeURL = URL(fileURLWithPath: testFile)
            .deletingLastPathComponent()
            .appendingPathComponent("stress-result.json")
        let dir = sourceTreeURL.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) {
            return sourceTreeURL
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stress-result.json")
    }

    private func loadCommittedBaseline(testFile: String = #filePath) -> StressResult? {
        // The committed baseline lives next to this test file.
        // We use `#filePath` (the Swift compile-time source-tree path)
        // — same approach as `LegalKeyExistenceTests` in the app
        // target. When the runtime
        // location is not the source tree (e.g., a stripped CI build
        // copying the .xctest to a separate path), this returns nil
        // and the comparison is skipped; the workflow uploads the
        // emitted `stress-result.json` as a build artifact instead.
        let url = URL(fileURLWithPath: testFile)
            .deletingLastPathComponent()
            .appendingPathComponent("stress-baseline.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StressResult.self, from: data)
    }

    private func writeStressJSON(_ result: StressResult, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Schema

/// Stress-baseline schema. Committed at:
///   Packages/RedactionEngine/Tests/RedactionEngineTests/IntegrationTests/StressTests/stress-baseline.json
///
/// Update flow: `make stress-baseline` runs the test, writes
/// `stress-result.json` to a known temp path, and copies it over the
/// committed baseline. The committed file is intentionally tiny —
/// CI diffs and regression-window math operate on these fields only.
///
/// M2 added the `machine` block (plan §7 "Machine pinning"): the 20%
/// wall-clock budget is "of the recorded baseline on the recorded
/// machine"; if the comparison machine differs from the baseline's
/// machine, the comparison is documentary and the operator should
/// refresh the baseline.
struct StressResult: Codable, Sendable {
    let wallClockSeconds: Double
    let peakMemoryBytes: Int
    let pageCount: Int
    let seed: UInt64
    let recordedAtISO8601: String
    /// Hardware / toolchain context for the run. Optional for
    /// backward compatibility with pre-M2 baselines (the `nil` case
    /// reports a documentary Issue and skips the regression assertion).
    let machine: MachineSpec?

    init(
        wallClockSeconds: Double,
        peakMemoryBytes: Int,
        pageCount: Int,
        seed: UInt64,
        recordedAtISO8601: String,
        machine: MachineSpec? = nil
    ) {
        self.wallClockSeconds = wallClockSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.pageCount = pageCount
        self.seed = seed
        self.recordedAtISO8601 = recordedAtISO8601
        self.machine = machine
    }
}

/// Hardware / toolchain context captured at baseline time. Identity
/// is decided by `deviceModel` + `simulatorName` — the same MacBook
/// driving the same iPhone simulator is treated as the same machine.
/// The `osVersion` and `xcodeVersion` fields are documentary; an OS
/// or Xcode bump on the same hardware does not invalidate the
/// baseline (the regression window absorbs minor toolchain drift).
/// See plan §7.
struct MachineSpec: Codable, Sendable, Equatable {
    let deviceModel: String
    let deviceClass: String
    let osVersion: String
    let xcodeVersion: String
    let simulatorName: String

    func matches(_ other: MachineSpec) -> Bool {
        deviceModel == other.deviceModel
            && simulatorName == other.simulatorName
    }

    /// Static probe of the current host. Values are populated by
    /// shelling out to `system_profiler`/`sw_vers`/`xcodebuild` at
    /// build time would add tooling complexity; the simpler in-test
    /// fallback reads the runtime environment when available and
    /// otherwise reports the recorded baseline's snapshot. A local
    /// `make stress-baseline` run records its own machine via the
    /// same probe.
    static func current() -> MachineSpec {
        let host = ProcessInfo.processInfo
        // `hw.model` via sysctl identifies the host hardware
        // (e.g., "MacBookPro18,1"); `system_profiler` is more
        // expensive and not needed for the identifier-only role
        // played by the machine block.
        let deviceModel = sysctlString("hw.model") ?? "unknown"
        let osVersion = "macOS \(host.operatingSystemVersionString)"
        let simulatorName = host.environment["SIMULATOR_DEVICE_NAME"]
            ?? "iPhone 17"
        let xcodeVersion = host.environment["XCODE_VERSION_ACTUAL"]
            ?? "unspecified"
        return MachineSpec(
            deviceModel: deviceModel,
            deviceClass: "macOS-iPhone-Simulator",
            osVersion: osVersion,
            xcodeVersion: xcodeVersion,
            simulatorName: simulatorName
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}
