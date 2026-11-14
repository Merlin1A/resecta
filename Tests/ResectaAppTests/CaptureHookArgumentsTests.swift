import Testing
@testable import ResectaApp

// The DEBUG hook that raises the screen-capture cover a set number of
// seconds after launch, and may lower it again, reads its two arguments as
// whole seconds and nothing else. The bare `--simulateCapture` (the cover
// at launch) is a different hook and is not read as a delay.
@Suite("Timed capture hook arguments")
@MainActor
struct CaptureHookArgumentsTests {

    struct Row {
        let arguments: [String]
        let delay: Int?
        let end: Int?
    }

    static let rows: [Row] = [
        Row(arguments: ["--uitesting"], delay: nil, end: nil),
        Row(arguments: ["--simulateCaptureAfter=6"], delay: 6, end: nil),
        Row(arguments: ["--simulateCaptureAfter=0"], delay: 0, end: nil),
        Row(arguments: ["--simulateCapture"], delay: nil, end: nil),
        Row(arguments: ["--simulateCaptureAfter="], delay: nil, end: nil),
        Row(arguments: ["--simulateCaptureAfter=x"], delay: nil, end: nil),
        Row(arguments: ["--simulateCaptureAfter=-1"], delay: nil, end: nil),
        Row(arguments: ["--simulateCaptureAfter=2.5"], delay: nil, end: nil),
        Row(arguments: ["--simulateCaptureAfter=6", "--simulateCaptureEndAfter=9"], delay: 6, end: 9),
        Row(arguments: ["--simulateCaptureAfter=6", "--simulateCaptureEndAfter=6"], delay: 6, end: nil),
        Row(arguments: ["--simulateCaptureAfter=6", "--simulateCaptureEndAfter=3"], delay: 6, end: nil),
        Row(arguments: ["--simulateCaptureEndAfter=9"], delay: nil, end: nil),
    ]

    @Test("The timed capture hook reads whole seconds and nothing else")
    func readsWholeSecondsOnly() {
        #expect(Self.rows.count == 12)
        for row in Self.rows {
            #expect(ResectaApp.simulatedCaptureDelay(for: row.arguments) == row.delay, "\(row.arguments)")
            #expect(ResectaApp.simulatedCaptureEnd(for: row.arguments) == row.end, "\(row.arguments)")
        }
    }
}
