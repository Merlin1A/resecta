import Testing
@testable import ResectaApp

@Suite("Custom Terms: the words under an add")
@MainActor
struct CustomTermsAddAnswerTests {

    enum Answer: CaseIterable, Sendable {
        case saved, invalid, full, duplicate, missing, notSaved, held

        var change: ListChange {
            switch self {
            case .saved: .saved
            case .invalid: .refused(.invalid)
            case .full: .refused(.full)
            case .duplicate: .refused(.duplicate)
            case .missing: .refused(.missing)
            case .notSaved: .notSaved
            case .held: .held
            }
        }
    }

    @Test("Custom Terms shows its refusal sentence for a refusal and nothing for a change that was not stored",
          arguments: Answer.allCases)
    func refusalText(_ answer: Answer) {
        #expect(Answer.allCases.count == 7)
        let expected: String? = switch answer {
        case .invalid, .full, .duplicate, .missing:
            "Term rejected. The pattern may be invalid or fail the regex safety check."
        case .saved, .notSaved, .held: nil
        }
        #expect(CustomTermsView.addRefusalText(for: answer.change) == expected)
    }
}
