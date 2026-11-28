import Testing
import Foundation
import SwiftUI
@testable import ResectaApp
import RedactionEngine

// The editor's band under the toolbar: seven places in a fixed order, the
// first that holds shown, the rest waiting. The order has one home
// (`TopBannerSlot`); the import annotation notice's own visibility reads
// only its own facts. Every expectation is the band's case table, written
// out, not derived from the code under test.

@MainActor
@Suite("Editor top-banner slot")
struct TopBannerSlotTests {

    /// The band's order, written out.
    private static let order: [TopBannerSlot] = [
        .redrawn, .paused, .droppedFiles, .importAnnotations, .sourceProtection, .fit, .imagePages,
    ]

    /// Every set of the seven places, by the bits of 0 to 127 over `order`.
    private static var everySet: [Set<TopBannerSlot>] {
        (0..<128).map { bits in Set(order.indices.filter { bits & (1 << $0) != 0 }.map { order[$0] }) }
    }

    @Test("The band shows the first notice in its order, for every set of notices")
    func occupantForEverySet() {
        #expect(TopBannerSlot.allCases.count == 7)
        #expect(TopBannerSlot.allCases == Self.order)
        let sets = Self.everySet
        #expect(sets.count == 128)
        #expect(Set(sets).count == 128)
        for present in sets {
            var expected: TopBannerSlot?
            for slot in Self.order where present.contains(slot) {
                expected = slot
                break
            }
            #expect(TopBannerSlot.occupant(of: present) == expected, "\(present)")
        }
        #expect(TopBannerSlot.occupant(of: [.paused, .importAnnotations]) == .paused)
        #expect(TopBannerSlot.occupant(of: [.redrawn, .paused]) == .redrawn)
        #expect(TopBannerSlot.occupant(of: [.droppedFiles, .importAnnotations]) == .droppedFiles)
        #expect(TopBannerSlot.occupant(of: [.paused, .droppedFiles]) == .paused)
        #expect(TopBannerSlot.occupant(of: []) == nil)
    }

    @Test("The folded mark's number is how many notices hold, and it shows from two")
    func waitingCountForEverySet() {
        let sets = Self.everySet
        #expect(sets.count == 128)
        var shown = 0
        for present in sets {
            let expected: Int? = present.count >= 2 ? present.count : nil
            #expect(TopBannerSlot.waitingCount(of: present) == expected, "\(present)")
            if expected != nil { shown += 1 }
        }
        // 128 sets less the empty one and the seven of one.
        #expect(shown == 120)
        #expect(TopBannerSlot.waitingCount(of: [.paused, .importAnnotations]) == 2)
        #expect(TopBannerSlot.waitingCount(of: [.paused]) == nil)
    }

    /// An editing document whose source carries a filled form field, so the
    /// annotation notice is owed.
    private static func annotatedEditingDocument() -> DocumentState {
        let documentState = DocumentState()
        documentState.phase = .editing
        documentState.sourceFilledFormFieldCount = 1
        return documentState
    }

    @Test("The editor's read: paused comes before the import notice, and the fit input ranks fifth")
    func editorsRead() {
        let both = Self.annotatedEditingDocument()
        both.wasPausedByBackground = true
        #expect(TopBannerSlot.winner(documentState: both) == .paused, "O-2 paused and the import notice")
        #expect(TopBannerSlot.holding(documentState: both) == [.paused, .importAnnotations])

        let annotated = Self.annotatedEditingDocument()
        #expect(TopBannerSlot.winner(documentState: annotated) == .importAnnotations, "O-3 the import notice alone")

        let plain = DocumentState()
        plain.phase = .editing
        #expect(TopBannerSlot.winner(documentState: plain) == nil, "O-3 none")
        #expect(TopBannerSlot.holding(documentState: plain).isEmpty)

        #expect(TopBannerSlot.winner(documentState: plain, widenedOnPage: true) == .fit, "O-5 the fit input")
        #expect(TopBannerSlot.winner(documentState: annotated, widenedOnPage: true) == .importAnnotations,
                "O-5 the import notice before the fit input")
        plain.wasPausedByBackground = true
        #expect(TopBannerSlot.winner(documentState: plain, widenedOnPage: true) == .paused, "O-5 then with the pause")
        #expect(TopBannerSlot.holding(documentState: plain, widenedOnPage: true) == [.paused, .fit])
    }

    /// A search session whose results on `widened` pages are drawn widened,
    /// and on `clean` pages are not.
    private static func session(widened: [Int], clean: [Int] = []) -> SearchState {
        let search = SearchState()
        search.results = (widened.map { ($0, true) } + clean.map { ($0, false) }).map { page, flag in
            SearchResult(
                pageIndex: page, normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.03),
                matchedText: "Hartwell", contextSnippet: "...", source: .textLayer, term: "Hartwell",
                isSelected: true, inkFitDegraded: flag)
        }
        return search
    }

    @Test("The editor's read puts the fit notice in the band only on a page holding a widened box, until it is closed")
    func fitNoticeOnItsPageUntilClosed() {
        let plain = DocumentState()
        plain.phase = .editing
        let state = RedactionState()
        // Pages 1 and 4 (0-based 0 and 3) widened, page 2 clean.
        state.activeSearch = Self.session(widened: [0, 3], clean: [1])
        func band(on page: Int) -> TopBannerSlot? {
            TopBannerSlot.winner(documentState: plain, widenedOnPage: state.fitNoticeHolds(on: page))
        }
        #expect(band(on: 0) == .fit, "F1 the widened page")
        #expect(band(on: 1) == nil, "F6 a clean page")
        #expect(band(on: 3) == .fit, "the other widened page")

        state.closeFitNotice()
        #expect(band(on: 0) == nil, "F7 closed on the page in view")
        #expect(band(on: 3) == nil, "F7 and on every page widened when it was closed")
        #expect(band(on: 1) == nil)

        // Page 6 (0-based 5) widened for the first time.
        state.activeSearch?.results += Self.session(widened: [5]).results
        #expect(band(on: 5) == .fit, "F7b a page widened after the close shows it")
        #expect(band(on: 0) == nil && band(on: 3) == nil, "F7b the closed pages stay closed")

        state.clearForNewDocument()
        #expect(state.fitNoticeClosedPages.isEmpty, "F7c another document: nothing is closed")
        state.activeSearch = Self.session(widened: [0])
        #expect(band(on: 0) == .fit, "F7c its widened page shows it")

        plain.phase = .verified(report: .skipped)
        #expect(band(on: 0) == nil, "F10 a phase other than editing: nothing")
    }

    @Test("The image, source and dropped-files notes are present only while editing and until closed")
    func documentNotesTable() {
        let phases: [DocumentState.PhaseKind] = [.empty, .importing, .editing, .detecting, .redacting,
                                                 .verifying, .verified, .exporting, .failed]
        let origins: [ImportFacts.Origin] = [.pdf, .images(count: 2)]
        var rows = 0
        for phase in phases { for origin in origins { for encrypted in [false, true] {
            for imageClosed in [false, true] { for sourceClosed in [false, true] { for count in [nil, 3] as [Int?] {
                let facts = ImportFacts.Summary(origin: origin, wasEncrypted: encrypted, hadRestrictions: false)
                // The rule, written out: only while editing; the dropped-files
                // note while its count is set; the source note for an
                // encrypted source until closed; the image note for a document
                // made from images until closed.
                var expected: Set<TopBannerSlot> = []
                if phase == .editing {
                    if count != nil { expected.insert(.droppedFiles) }
                    if encrypted && !sourceClosed { expected.insert(.sourceProtection) }
                    if origin != .pdf && !imageClosed { expected.insert(.imagePages) }
                }
                #expect(TopBannerSlot.documentNotes(
                    phase: phase, facts: facts, imagePagesNoteDismissed: imageClosed,
                    sourceProtectionNoteDismissed: sourceClosed, droppedFilesNoteCount: count) == expected,
                        "\(phase) \(origin) encrypted \(encrypted) closed \(imageClosed)/\(sourceClosed) count \(String(describing: count))")
                rows += 1
            } } }
        } } }
        #expect(rows == 288)

        // Through the editor's read: an image document while editing shows its
        // note; closed, nothing; dropped files then outrank it.
        let document = DocumentState()
        document.phase = .editing
        document.sourceFacts = ImportFacts.Summary(origin: .images(count: 2), wasEncrypted: false, hadRestrictions: false)
        #expect(TopBannerSlot.winner(documentState: document) == .imagePages)
        document.droppedFilesNoteCount = 3
        #expect(TopBannerSlot.winner(documentState: document) == .droppedFiles)
        #expect(TopBannerSlot.holding(documentState: document) == [.droppedFiles, .imagePages])
        document.droppedFilesNoteCount = nil
        document.imagePagesNoteDismissed = true
        #expect(TopBannerSlot.winner(documentState: document) == nil)
    }

    @Test("Each note's closed state is written only by its close, an import, Start Over and a drop's arrival")
    func noteStateWriters() throws {
        let sources = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
        let files = try #require(FileManager.default.enumerator(atPath: sources.path))
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
        #expect(files.count > 100, "the source tree was not found")
        // The band file closes each note; ImportService resets them on an
        // import, DocumentState on Start Over; DocumentState+LoadNotes holds
        // the notes and their forwarding setters; the workspace view sets the
        // count when a drop's document arrives.
        let band = "DocumentEditorView+TopBanner.swift"
        let holders: Set<String> = [band, "ImportService.swift", "DocumentState.swift", "DocumentState+LoadNotes.swift"]
        let allowed: [String: Set<String>] = [
            "imagePagesNoteDismissed": holders,
            "sourceProtectionNoteDismissed": holders,
            "droppedFilesNoteCount": holders.union(["RedactWorkspaceView.swift"]),
            "loadNotes": ["ImportService.swift", "DocumentState.swift", "DocumentState+LoadNotes.swift"],
        ]
        var writers: [String: Set<String>] = [:]
        for file in files {
            let name = (file as NSString).lastPathComponent
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                for property in allowed.keys
                where code.range(of: "\\b\(property)\\s*=[^=]", options: .regularExpression) != nil {
                    writers[property, default: []].insert(name)
                }
            }
            if name == band {
                #expect(!text.contains("onDisappear"), "the band file holds an onDisappear")
            }
        }
        for (property, files) in allowed {
            let found = writers[property] ?? []
            #expect(!found.isEmpty, "\(property) is written nowhere")
            #expect(found.isSubset(of: files), "\(property) is written in \(found.subtracting(files).sorted())")
        }
        // Each note's close writes its state in the document, not in a view's
        // own state.
        for property in ["imagePagesNoteDismissed", "sourceProtectionNoteDismissed", "droppedFilesNoteCount"] {
            #expect(writers[property]?.contains(band) == true, "the band's close does not write \(property)")
        }
    }

    @Test("The editor's read: a dismissed annotation notice and a phase other than editing leave the slot empty")
    func emptySlot() {
        let documentState = Self.annotatedEditingDocument()
        documentState.annotationNoticeDismissed = true
        #expect(TopBannerSlot.winner(documentState: documentState) == nil)
        let verifying = Self.annotatedEditingDocument()
        verifying.wasPausedByBackground = true
        verifying.phase = .verified(report: .skipped)
        #expect(TopBannerSlot.winner(documentState: verifying) == nil)
    }

    @Test("What holds is read with the phase aside")
    func holdingLeavesThePhaseAside() {
        let verifying = Self.annotatedEditingDocument()
        verifying.wasPausedByBackground = true
        verifying.phase = .verified(report: .skipped)
        #expect(TopBannerSlot.holding(documentState: verifying) == [.paused, .importAnnotations])
        verifying.annotationNoticeDismissed = true
        #expect(TopBannerSlot.holding(documentState: verifying) == [.paused])
    }

    /// One state of the editor's sheet slot, its inputs to the band's rule,
    /// and the phases in which the band shows.
    private struct SlotState {
        let name: String
        let slotPresents: Bool
        let searchIsTheSheet: Bool
        let detent: PresentationDetent
        let shownIn: Set<DocumentState.PhaseKind>
    }

    @Test("The band shows only while editing with no sheet above the parked height")
    func bandIsShownTable() {
        let phases: [DocumentState.PhaseKind] = [
            .empty, .importing, .editing, .detecting, .redacting, .verifying, .verified, .exporting, .failed,
        ]
        // Each slot state, its inputs, and the phases in which the band shows.
        let slotStates: [SlotState] = [
            SlotState(name: "H-1 no sheet", slotPresents: false, searchIsTheSheet: false,
                      detent: .medium, shownIn: [.editing]),
            SlotState(name: "H-2 Search parked", slotPresents: true, searchIsTheSheet: true,
                      detent: .compactFloat, shownIn: [.editing]),
            SlotState(name: "H-3 Search at medium", slotPresents: true, searchIsTheSheet: true,
                      detent: .medium, shownIn: []),
            SlotState(name: "H-3 Search at large", slotPresents: true, searchIsTheSheet: true,
                      detent: .large, shownIn: []),
            SlotState(name: "H-4 the rationale sheet", slotPresents: true, searchIsTheSheet: false,
                      detent: .compactFloat, shownIn: []),
        ]
        var rows = 0
        for state in slotStates {
            for phase in phases {
                let shown = TopBannerSlot.bandIsShown(
                    phase: phase, slotPresents: state.slotPresents,
                    searchIsTheSheet: state.searchIsTheSheet, searchDetent: state.detent)
                #expect(shown == state.shownIn.contains(phase), "\(state.name), \(phase)")
                rows += 1
            }
        }
        #expect(phases.count == 9)
        #expect(rows == 45)
    }

    @Test("Hiding the band leaves every notice in place")
    func hidingEndsNothing() {
        let documentState = Self.annotatedEditingDocument()
        documentState.wasPausedByBackground = true
        let before = TopBannerSlot.holding(documentState: documentState)
        #expect(TopBannerSlot.winner(documentState: documentState) == .paused)
        // Search rises to medium: the band hides.
        #expect(!TopBannerSlot.bandIsShown(
            phase: documentState.phaseKind, slotPresents: true, searchIsTheSheet: true, searchDetent: .medium))
        // Search parks: the band shows the same occupant, and nothing has ended.
        #expect(TopBannerSlot.bandIsShown(
            phase: documentState.phaseKind, slotPresents: true, searchIsTheSheet: true, searchDetent: .compactFloat))
        #expect(TopBannerSlot.winner(documentState: documentState) == .paused)
        #expect(TopBannerSlot.holding(documentState: documentState) == before)
        #expect(documentState.wasPausedByBackground)
        #expect(!documentState.annotationNoticeDismissed)
    }

    /// One state of the band as speech sees it, or a new document.
    private enum SpeechState {
        case band(shown: TopBannerSlot?, holding: Set<TopBannerSlot>, sceneIsActive: Bool = true)
        case newDocument
    }

    /// A spoken line: the state it is spoken at, counted from 1, and its notice.
    private struct Spoken: Equatable {
        let state: Int
        let slot: TopBannerSlot
    }

    private struct SpeechRow {
        let name: String
        let states: [SpeechState]
        let spoken: [Spoken]
    }

    @Test("A notice is spoken once, and again when its condition has ended and holds again")
    func spokenOnce() {
        let rows: [SpeechRow] = [
            SpeechRow(name: "A-1 the pause shown; Search raised, the pause holding; shown again", states: [
                .band(shown: .paused, holding: [.paused]),
                .band(shown: nil, holding: [.paused]),
                .band(shown: .paused, holding: [.paused]),
            ], spoken: [Spoken(state: 1, slot: .paused)]),
            SpeechRow(name: "A-2 the pause shown; Dismiss; a second pause shown", states: [
                .band(shown: .paused, holding: [.paused]),
                .band(shown: nil, holding: []),
                .band(shown: .paused, holding: [.paused]),
            ], spoken: [Spoken(state: 1, slot: .paused), Spoken(state: 3, slot: .paused)]),
            SpeechRow(name: "A-3 the pause shown; Restart clears it and leaves editing; a second pause, shown on return", states: [
                .band(shown: .paused, holding: [.paused]),
                .band(shown: nil, holding: []),
                .band(shown: nil, holding: [.paused]),
                .band(shown: .paused, holding: [.paused]),
            ], spoken: [Spoken(state: 1, slot: .paused), Spoken(state: 4, slot: .paused)]),
            SpeechRow(name: "A-4 the pause shown; a new document; a pause in it", states: [
                .band(shown: .paused, holding: [.paused]),
                .newDocument,
                .band(shown: .paused, holding: [.paused]),
            ], spoken: [Spoken(state: 1, slot: .paused), Spoken(state: 3, slot: .paused)]),
            SpeechRow(name: "A-5 the pause and the import notice hold; the pause dismissed", states: [
                .band(shown: .paused, holding: [.paused, .importAnnotations]),
                .band(shown: .importAnnotations, holding: [.importAnnotations]),
            ], spoken: [Spoken(state: 1, slot: .paused), Spoken(state: 2, slot: .importAnnotations)]),
            SpeechRow(name: "A-6 the import notice shown; a run takes the phase away and gives it back", states: [
                .band(shown: .importAnnotations, holding: [.importAnnotations]),
                .band(shown: nil, holding: [.importAnnotations]),
                .band(shown: .importAnnotations, holding: [.importAnnotations]),
            ], spoken: [Spoken(state: 1, slot: .importAnnotations)]),
            SpeechRow(name: "A-7 the pause raised with the scene in the background; the scene active", states: [
                .band(shown: .paused, holding: [.paused], sceneIsActive: false),
                .band(shown: .paused, holding: [.paused]),
            ], spoken: [Spoken(state: 2, slot: .paused)]),
        ]
        #expect(rows.count == 7)
        for row in rows {
            var announced: Set<TopBannerSlot> = []
            var spoken: [Spoken] = []
            for (index, state) in row.states.enumerated() {
                switch state {
                case .newDocument:
                    announced = []
                case let .band(shown, holding, sceneIsActive):
                    let step = TopBannerSlot.announceStep(
                        shown: TopBannerSlot.shownForSpeech(shown, sceneIsActive: sceneIsActive),
                        holding: holding, announced: announced)
                    announced = step.announced
                    if let slot = step.speak { spoken.append(Spoken(state: index + 1, slot: slot)) }
                }
            }
            #expect(spoken == row.spoken, "\(row.name)")
        }
    }

    @Test("Speech steps: what is kept, what is spoken")
    func speechStepRows() {
        #expect(TopBannerSlot.announceStep(shown: .paused, holding: [.paused], announced: [])
                == TopBannerSlot.SpeechStep(speak: .paused, announced: [.paused]))
        #expect(TopBannerSlot.announceStep(shown: .paused, holding: [.paused], announced: [.paused])
                == TopBannerSlot.SpeechStep(speak: nil, announced: [.paused]))
        #expect(TopBannerSlot.announceStep(shown: nil, holding: [.importAnnotations], announced: [.paused, .importAnnotations])
                == TopBannerSlot.SpeechStep(speak: nil, announced: [.importAnnotations]))
        #expect(TopBannerSlot.shownForSpeech(.paused, sceneIsActive: true) == .paused)
        #expect(TopBannerSlot.shownForSpeech(.paused, sceneIsActive: false) == nil)
        #expect(TopBannerSlot.shownForSpeech(nil, sceneIsActive: true) == nil)
    }

    @Test("The annotation notice's visibility reads its own facts only")
    func annotationVisibilityReadsItsOwnFacts() {
        #expect(ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 1, dismissed: false))
        #expect(!ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 1, dismissed: true))
    }
}
