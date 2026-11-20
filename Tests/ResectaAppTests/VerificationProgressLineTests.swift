import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// While the checks run: the figure is the number of results published so
// far, on every finish as well as every start; the line names a check only
// while it runs alone, after half a second, and never a Search Re-check
// that has nothing to re-run; the verdict card and its slide are gone; the
// bar's trailing button ignores a late tap.

@Suite("The running checks' figure and line", .tags(.display))
@MainActor
struct VerificationProgressLineTests {

    typealias Line = VerificationProgressLine.Line
    typealias Progress = DocumentState.VerificationProgress

    static func result(_ layer: VerificationLayer) -> LayerResult {
        LayerResult(name: layer.name, symbolName: layer.symbolName, status: .pass, shortDescription: "",
                    detailDescription: "", pageReferences: nil, durationSeconds: 0, layer: layer)
    }

    static let group: [VerificationLayer] = [.textExtraction, .ocrCheck, .binaryStringSearch]
    // Date's own zero: a time t0 + s holds s exactly, so the view's Date
    // arithmetic and this test's clock agree at the 0.3 s and 0.5 s edges
    // (far from it, adding a fraction of a second rounds).
    static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - The cases table, then the replays

    @Test("The cases table, and replays of a Secure run in today's order, the earlier order and the idle order")
    func progressLineTable() {
        // (finished, total, running, seconds running, typed search applied, expected line)
        let rows: [(Int, Int, VerificationLayer?, Double, Bool, Line)] = [
            (0, 7, .textExtraction, 0.1, true, .checking),                 // 1 the group has started
            (0, 7, .textExtraction, 30, true, .checking),                  // 2 the same, 30 s later
            (3, 7, nil, 0, true, .checking),                               // 3 the group's results in
            (3, 7, .structureCheck, 0.2, true, .checking),                 // 4 alone, 0.2 s
            (3, 7, .structureCheck, 0.5, true, .naming(.structureCheck)),  // 5 alone, 0.5 s
            (4, 7, nil, 0, true, .checking),                               // 6 it finished
            (5, 7, nil, 0, true, .checking),                               // 7 the long pass, nothing announced
            (5, 7, .searchRecheck, 2, true, .naming(.searchRecheck)),      // 8 announced, typed search
            (5, 7, .searchRecheck, 2, false, .checking),                   // 9 the same, a Scan only
            (6, 7, .detectionSweep, 1, true, .naming(.detectionSweep)),    // 10 the sweep
            (7, 7, nil, 0, true, .checking),                               // 11 the last result
            (0, 13, .textExtraction, 1, true, .checking),                  // 12 Searchable, the group of four
            (0, 0, nil, 0, false, .checking),                              // 13 no progress yet
            (6, 7, .detectionSweep, 1, false, .naming(.detectionSweep)),   // 14 idle order: the sweep's pass
        ]
        var ran = 0
        for (finished, total, running, seconds, typed, line) in rows {
            let state = VerificationProgressLine.make(
                finished: finished, total: total, running: running,
                runningOpensGroup: running?.phase == .parallelBase, secondsRunning: seconds,
                typedSearchApplied: typed)
            #expect(state == .init(finished: finished, total: total, line: line), "row \(ran + 1)")
            ran += 1
        }
        #expect(ran == 14)
        // A named line is the row's title, never the engine's name.
        #expect(VerificationProgressLine.text(.naming(.ocrCheck))
                == "Checking \(VerificationRowModel.title(for: VerificationLayer.ocrCheck))\u{2026}")
        #expect(VerificationRowModel.title(for: VerificationLayer.ocrCheck) != VerificationLayer.ocrCheck.name)

        // (a) today's engine: the last pair is announced after its pass.
        let a = Self.replay(typed: true, [
            (.start(.textExtraction), 0, 0, .checking),
            (.finish(.textExtraction), 4, 1, .checking),
            (.finish(.ocrCheck), 4, 2, .checking),
            (.finish(.binaryStringSearch), 4, 3, .checking),
            (.start(.structureCheck), 4, 3, .checking),
            (.wait, 4.6, 3, .naming(.structureCheck)),
            (.finish(.structureCheck), 5, 4, .checking),
            (.start(.metadataCheck), 5, 4, .checking),
            (.finish(.metadataCheck), 5.2, 5, .checking),
            (.wait, 90, 5, .checking),
            (.start(.searchRecheck), 100, 5, .checking),
            (.finish(.searchRecheck), 100.1, 6, .checking),
            (.start(.detectionSweep), 100.1, 6, .checking),
            (.finish(.detectionSweep), 100.2, 7, .checking),
        ])
        // (b) the earlier announcement: the Re-check is announced before the pass.
        let b = Self.replay(typed: true, [
            (.start(.textExtraction), 0, 0, .checking),
            (.finish(.textExtraction), 4, 1, .checking),
            (.finish(.ocrCheck), 4, 2, .checking),
            (.finish(.binaryStringSearch), 4, 3, .checking),
            (.start(.structureCheck), 4, 3, .checking),
            (.finish(.structureCheck), 4.3, 4, .checking),
            (.start(.metadataCheck), 4.3, 4, .checking),
            (.finish(.metadataCheck), 4.4, 5, .checking),
            (.start(.searchRecheck), 4.4, 5, .checking),
            (.wait, 60, 5, .naming(.searchRecheck)),
            (.finish(.searchRecheck), 100, 6, .checking),
            (.start(.detectionSweep), 100, 6, .checking),
            (.finish(.detectionSweep), 100.2, 7, .checking),
        ])
        // (c) no typed search, the idle Re-check first, the sweep announced for the pass.
        let c = Self.replay(typed: false, [
            (.start(.textExtraction), 0, 0, .checking),
            (.finish(.textExtraction), 4, 1, .checking),
            (.finish(.ocrCheck), 4, 2, .checking),
            (.finish(.binaryStringSearch), 4, 3, .checking),
            (.start(.structureCheck), 4, 3, .checking),
            (.finish(.structureCheck), 4.3, 4, .checking),
            (.start(.metadataCheck), 4.3, 4, .checking),
            (.finish(.metadataCheck), 4.4, 5, .checking),
            (.start(.searchRecheck), 4.4, 5, .checking),
            (.finish(.searchRecheck), 4.5, 6, .checking),
            (.start(.detectionSweep), 4.5, 6, .checking),
            (.wait, 60, 6, .naming(.detectionSweep)),
            (.finish(.detectionSweep), 100, 7, .checking),
        ])
        print("[progress-line] rows \(ran), replay steps \(a) \(b) \(c)")
        let steps: [Int] = [a, b, c]
        #expect(steps == [14, 13, 13])
    }

    enum Step { case start(VerificationLayer), finish(VerificationLayer), wait }

    /// Feeds the steps through the runner's mapping and reads the screen's
    /// figure and line after each one; returns the steps run.
    static func replay(typed: Bool, _ steps: [(Step, Double, Int, Line)]) -> Int {
        var progress = Progress(currentLayer: 0, totalLayers: 0, layerName: "", completedLayers: [],
                                typedSearchApplied: typed, checksBegan: t0, lastChange: t0)
        var ordinal = 0
        var run = 0
        for (step, at, figure, line) in steps {
            let now = t0.addingTimeInterval(at)
            switch step {
            case .start(let layer):
                ordinal += 1
                progress = PipelineRunner.verificationProgress(
                    after: .layerStarted(layer: layer, ordinal: ordinal, totalLayers: 7,
                                         completedLayers: progress.completedLayers),
                    previous: progress, now: now)
            case .finish(let layer):
                progress = PipelineRunner.verificationProgress(
                    after: .layerFinished(layer: layer, ordinal: ordinal, result: result(layer)),
                    previous: progress, now: now)
            case .wait:
                break
            }
            let state = VerificationProgressView.state(.init(verifying: progress), now: now)
            #expect(state.finished == figure && state.total == 7 && state.line == line, "step \(run + 1) at \(at)")
            run += 1
        }
        return run
    }

    // MARK: - Never names a check that is not running alone

    @Test("Over 500 runs in the engine's order, the line names only a check that runs alone, after half a second")
    func neverNamesACheckThatIsNotRunning() {
        var random = ProgressLineRandom(seed: 0x5EED_1234)
        var runs = 0, named = 0
        for index in 0..<500 {
            let typed = index % 2 == 0
            let searchable = index % 3 == 0
            let singles: [VerificationLayer] = searchable
                ? [.structureCheck, .metadataCheck, .spatialVerification, .characterCount, .fontVerification,
                   .characterLineage, .hiddenWordInk, .searchRecheck, .detectionSweep]
                : [.structureCheck, .metadataCheck, .searchRecheck, .detectionSweep]
            let firstGroup: [VerificationLayer] = searchable ? Self.group + [.operatorReExtraction] : Self.group
            let total = firstGroup.count + singles.count
            var progress = Progress(currentLayer: 0, totalLayers: 0, layerName: "", completedLayers: [],
                                    typedSearchApplied: typed, checksBegan: Self.t0, lastChange: Self.t0)
            var clock = 0.0, ordinal = 0
            // The test's own record of what is announced and not finished.
            var announced: (layer: VerificationLayer, at: Double, opensGroup: Bool)?
            func look() {
                // Read the screen at a few moments up to the next event.
                for offset in [0.0, 0.3, 0.5, 2.0] {
                    let now = Self.t0.addingTimeInterval(clock + offset)
                    let state = VerificationProgressView.state(.init(verifying: progress), now: now)
                    guard case .naming(let layer) = state.line else { continue }
                    named += 1
                    #expect(announced?.layer == layer, "run \(index): names \(layer), not running")
                    #expect(announced?.opensGroup == false, "run \(index): names the group's first")
                    #expect(clock + offset - (announced?.at ?? .infinity) >= 0.5, "run \(index): before half a second")
                    #expect(layer != .searchRecheck || typed, "run \(index): an idle Re-check named")
                }
            }
            func start(_ layer: VerificationLayer, opensGroup: Bool) {
                ordinal += 1
                progress = PipelineRunner.verificationProgress(
                    after: .layerStarted(layer: layer, ordinal: ordinal, totalLayers: total,
                                         completedLayers: progress.completedLayers),
                    previous: progress, now: Self.t0.addingTimeInterval(clock))
                announced = (layer, clock, opensGroup)
                look()
                clock += random.gap()
            }
            func finish(_ layer: VerificationLayer) {
                progress = PipelineRunner.verificationProgress(
                    after: .layerFinished(layer: layer, ordinal: ordinal, result: Self.result(layer)),
                    previous: progress, now: Self.t0.addingTimeInterval(clock))
                announced = nil
                look()
                clock += random.gap()
            }
            start(firstGroup[0], opensGroup: true)
            for layer in firstGroup { finish(layer) }
            for layer in singles { start(layer, opensGroup: false); finish(layer) }
            #expect(progress.completedLayers.count == total)
            runs += 1
        }
        print("[progress-line] runs \(runs), named moments \(named)")
        #expect(runs == 500)
        #expect(named > 0)
    }

    // MARK: - A finish publishes progress

    @Test("A finish publishes progress with its result and no running check; a start names the check, its group and a time")
    func aFinishPublishesProgress() {
        let began = Self.t0
        let start = PipelineRunner.verificationProgress(
            after: .layerStarted(layer: .textExtraction, ordinal: 1, totalLayers: 7, completedLayers: []),
            previous: Progress(currentLayer: 0, totalLayers: 0, layerName: "", completedLayers: []),
            now: began)
        #expect(start.running == .init(layer: .textExtraction, opensGroup: true, since: began))
        #expect(start.totalLayers == 7 && start.completedLayers.isEmpty && start.lastChange == began)
        let alone = PipelineRunner.verificationProgress(
            after: .layerStarted(layer: .structureCheck, ordinal: 4, totalLayers: 7, completedLayers: []),
            previous: start, now: began.addingTimeInterval(3))
        #expect(alone.running?.opensGroup == false)
        let later = began.addingTimeInterval(5)
        let finish = PipelineRunner.verificationProgress(
            after: .layerFinished(layer: .structureCheck, ordinal: 4, result: Self.result(.structureCheck)),
            previous: alone, now: later)
        #expect(finish.completedLayers.map(\.layer) == [.structureCheck])
        #expect(finish.running == nil)
        #expect(finish.totalLayers == 7 && finish.lastChange == later)
        // A typed search is a request the user applied that is not a Scan.
        #expect(!PipelineRunner.appliedTypedSearch([]))
    }

    // MARK: - No verdict card, no slide

    @Test("Source pin: the editor raises no verdict card, and the running screen does not slide in")
    func noVerdictCardNoSlide() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/DocumentEditorView.swift"), encoding: .utf8)
        #expect(!source.contains("showBriefStatus"))
        let start = try #require(source.range(of: "case .verifying:"))
        let end = try #require(source.range(of: "case .verified", range: start.upperBound..<source.endIndex))
        #expect(!source[start.upperBound..<end.lowerBound].contains(".move(edge: .trailing)"))
    }

    // MARK: - The spoken block, the long-run line, the late tap

    @Test("The block is spoken in shipped words; the long-run line and the reminder come by time")
    func spokenBlockAndTimes() {
        let state = VerificationProgressLine(finished: 5, total: 14, line: .checking)
        #expect(VerificationProgressView.spokenLabel(state, longRun: false)
                == "Verification In Progress. 5 of 14 checks completed. Checking.")
        let empty = VerificationProgressLine(finished: 0, total: 0, line: .checking)
        #expect(VerificationProgressView.spokenLabel(empty, longRun: false) == "Verification In Progress. Checking.")
        let progress = DocumentState.PipelineProgress(current: 1, total: 7, stepDescription: "",
                                                      checksBegan: Self.t0, lastChange: Self.t0)
        #expect(!VerificationProgressView.showsLongRunLine(progress, now: Self.t0.addingTimeInterval(14.9)))
        #expect(VerificationProgressView.showsLongRunLine(progress, now: Self.t0.addingTimeInterval(15)))
        #expect(VerificationProgressView.stillCheckingDue(progress, now: Self.t0.addingTimeInterval(29.9)) == nil)
        #expect(VerificationProgressView.stillCheckingDue(progress, now: Self.t0.addingTimeInterval(30)) == Self.t0)
    }

    @Test("For 0.3 seconds after the results appear, the bar's trailing button ignores taps")
    func lateTapIsIgnored() {
        #expect(DocumentEditorToolbar.acceptsTrailingTap(resultsAppearedAt: nil, now: Self.t0))
        #expect(!DocumentEditorToolbar.acceptsTrailingTap(resultsAppearedAt: Self.t0, now: Self.t0.addingTimeInterval(0.29)))
        #expect(DocumentEditorToolbar.acceptsTrailingTap(resultsAppearedAt: Self.t0, now: Self.t0.addingTimeInterval(0.3)))
    }
}

/// A fixed-seed generator for the gaps between events (SplitMix64).
struct ProgressLineRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// A gap of 0 to 3 seconds, in tenths.
    mutating func gap() -> Double { Double(next() % 31) / 10 }
}
