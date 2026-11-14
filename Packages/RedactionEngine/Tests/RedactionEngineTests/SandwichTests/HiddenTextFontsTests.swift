import Testing
@testable import RedactionEngine

@Suite("The hidden text's fonts")
struct HiddenTextFontsTests {

    struct Run: CustomTestStringConvertible, Sendable {
        let name: String
        let text: String
        var testDescription: String { name }
    }

    @Test("The three faces are Courier, Courier New and Menlo, in that order, and each is on this system")
    func threeFaces() {
        #expect(HiddenTextFonts.names == ["Courier", "CourierNewPSMT", "Menlo-Regular"])
        #expect(HiddenTextFonts.names.allSatisfy { HiddenTextFonts.font(named: $0) != nil })
    }

    static let inOnEveryBuild: [Run] = [
        Run(name: "an English word", text: "Report"),
        Run(name: "naïve", text: "na\u{00EF}ve"),
        Run(name: "Łódź", text: "\u{0141}\u{00F3}d\u{017A}"),
        Run(name: "Ελλάδα", text: "\u{0395}\u{03BB}\u{03BB}\u{03AC}\u{03B4}\u{03B1}"),
        Run(name: "Москва", text: "\u{041C}\u{043E}\u{0441}\u{043A}\u{0432}\u{0430}"),
        Run(name: "€1,250", text: "\u{20AC}1,250"),
    ]

    @Test("A run the three faces can draw can be written", arguments: inOnEveryBuild)
    func writtenOnEveryBuild(_ run: Run) {
        #expect(HiddenTextFonts.canBeWritten(run.text))
    }

    @Test("The runs written on every build are six")
    func inLength() {
        #expect(Self.inOnEveryBuild.count == 6)
    }

    static let outOnEveryBuild: [Run] = [
        Run(name: "東京", text: "\u{6771}\u{4EAC}"),
        Run(name: "한국어", text: "\u{D55C}\u{AD6D}\u{C5B4}"),
        Run(name: "हिन्दी", text: "\u{0939}\u{093F}\u{0928}\u{094D}\u{0926}\u{0940}"),
        Run(name: "தமிழ்", text: "\u{0BA4}\u{0BAE}\u{0BBF}\u{0BB4}\u{0BCD}"),
        Run(name: "an emoji", text: "\u{1F600}"),
        Run(name: "a private-use character", text: "\u{E000}"),
        Run(name: "a Syriac word", text: "\u{0710}\u{072A}\u{0721}\u{071D}\u{0710}"),
        Run(name: "a Thaana word", text: "\u{0780}\u{07A6}"),
        Run(name: "an English word holding the replacement character", text: "Rep\u{FFFD}rt"),
        Run(name: "an English word holding a direction mark", text: "Report\u{200E}"),
        Run(name: "a year followed by a Han character", text: "2024\u{5E74}"),
    ]

    @Test("A run with a character no face has, or one the hidden text never holds, cannot be written",
          arguments: outOnEveryBuild)
    func leftOutOnEveryBuild(_ run: Run) {
        #expect(!HiddenTextFonts.canBeWritten(run.text))
        #expect(HiddenTextFonts.choice(for: run.text) == nil)
    }

    @Test("The runs left out on every build are eleven")
    func outLength() {
        #expect(Self.outOnEveryBuild.count == 11)
    }

    @Test("The object mark is passed over: it is no reason to leave a run out")
    func objectMarkPassedOver() {
        #expect(HiddenTextFonts.choice(for: "ab\u{FFFC}cd") == .oneFont("Courier"))
    }

    @Test("A word Courier draws whole is drawn in Courier")
    func courierFirst() {
        #expect(HiddenTextFonts.choice(for: "Report") == .oneFont("Courier"))
    }

    struct Recorded: CustomTestStringConvertible, Sendable {
        let name: String
        let text: String
        let choice: HiddenTextFonts.Choice?
        var testDescription: String { name }
    }

    /// Values that depend on what the three faces cover on the build, read
    /// alike on macOS 27.2, iOS 26.4.1 and iOS 27.2. A value that changes on
    /// a new build is read by a person, not refreshed.
    static let recorded: [Recorded] = [
        Recorded(name: "Việt", text: "Vi\u{1EC7}t", choice: .oneFont("Courier")),
        Recorded(name: "ἀρχή", text: "\u{1F00}\u{03C1}\u{03C7}\u{03AE}", choice: .oneFont("CourierNewPSMT")),
        Recorded(name: "Қазақ", text: "\u{049A}\u{0430}\u{0437}\u{0430}\u{049B}", choice: .oneFont("CourierNewPSMT")),
        Recorded(name: "→", text: "\u{2192}", choice: .oneFont("CourierNewPSMT")),
        Recorded(name: "≤", text: "\u{2264}", choice: .oneFont("Courier")),
        Recorded(name: "Ελλάδα‖, one face a letter",
                 text: "\u{0395}\u{03BB}\u{03BB}\u{03AC}\u{03B4}\u{03B1}\u{2016}",
                 choice: .eachCharacter(["CourierNewPSMT", "CourierNewPSMT", "CourierNewPSMT",
                                         "CourierNewPSMT", "CourierNewPSMT", "CourierNewPSMT", "Courier"])),
    ]

    @Test("A run whose faces depend on the build is drawn as recorded", arguments: recorded)
    func recordedRun(_ run: Recorded) {
        #expect(HiddenTextFonts.choice(for: run.text) == run.choice)
    }

    @Test("The recorded runs are six")
    func recordedLength() {
        #expect(Self.recorded.count == 6)
    }
}
