import Foundation
import RedactionCore

// What the reader of a page's stored picture reports for one page: the walk
// of its JPEG as the file stores it, or the named reason it would not go on.
// No box is read here. A walk can be built only by the walker (its seal is
// made in JPEGEntropyWalk.swift alone), so no other code can hand the
// verdict a walk that was not read.

/// Why the reader stopped. Each reason has its own name; the offset is the
/// byte in the image stream where it stopped (0 when the reason is about the
/// page rather than a byte of its picture).
struct PageImageRefusal: Error, Equatable, Sendable {
    /// The closed list of reasons.
    enum Reason: String, CaseIterable, Sendable {
        // The header, read by meaning.
        case noStartMarker
        case markerExpected
        case fillByteBeforeMarker
        case segmentOutsideStream
        case markerNotAllowed
        case notBaselineSequential
        case precisionNotEightBits
        case componentCount
        case samplingFactor
        case colourSampledAboveBrightness
        case secondFrame
        case frameSideZero
        case tooManyBlocks
        case noJFIFHeader
        case secondJFIFHeader
        case jfifHeaderLength
        case jfifThumbnail
        case adobeSegment
        case unlistedSegmentsOverLimit
        case quantiserTable
        case quantiserStepZero
        case huffmanTable
        case tableDefinedTwice
        case restartDefinition
        case scanBeforeFrame
        case scanNotEveryComponent
        case scanNotSequential
        case tableNotDefined
        case tableNeverUsed
        // The walk of the coded data.
        case scanCutShort
        case markerInsideScan
        case restartMarkerNotDeclared
        case restartMarkerOrder
        case huffmanCodeNotInTable
        case coefficientSize
        case coefficientRun
        case noEndMarker
        case bytesAfterEndMarker
        // The page and its record.
        case noPageImage
        case twoPageImages
        case formsOverLimit
        case notJPEG          // not stored as a JPEG alone (its one filter DCT)
        case noRecordedHash
        case hashDiffers
        case bytesNotInFile
        case pageNotInFile    // the record names a page past the file's last
        // The page as drawn, read by the box check itself (PageDrawingReader).
        case drawingNotRead
        case fileRevised
        case documentKeyNotListed
        case pageKeyNotListed
        case resourceNotListed
        case operatorNotListed
        case textNotInvisible
        case pictureNotDrawnOnce
        case pictureNotOverThePage
        case pictureKeyNotListed
        case pictureColourNotListed
        case pictureSizeDiffers
        case unlistedSegment

        /// The fault this reason reads as: the picture is not the one the
        /// record names, or it could not be read for this check.
        var fault: FaultName {
            switch self {
            case .noRecordedHash, .hashDiffers, .bytesNotInFile, .pageNotInFile: .wrongSubject
            case .noStartMarker, .markerExpected, .fillByteBeforeMarker, .segmentOutsideStream,
                 .markerNotAllowed, .notBaselineSequential, .precisionNotEightBits, .componentCount,
                 .samplingFactor, .colourSampledAboveBrightness, .secondFrame, .frameSideZero,
                 .tooManyBlocks, .noJFIFHeader, .secondJFIFHeader, .jfifHeaderLength, .jfifThumbnail,
                 .adobeSegment, .unlistedSegmentsOverLimit, .quantiserTable, .quantiserStepZero, .huffmanTable,
                 .tableDefinedTwice, .restartDefinition, .scanBeforeFrame, .scanNotEveryComponent,
                 .scanNotSequential, .tableNotDefined, .tableNeverUsed, .scanCutShort,
                 .markerInsideScan, .restartMarkerNotDeclared, .restartMarkerOrder,
                 .huffmanCodeNotInTable, .coefficientSize, .coefficientRun, .noEndMarker,
                 .bytesAfterEndMarker, .noPageImage, .twoPageImages, .formsOverLimit, .notJPEG,
                 .drawingNotRead, .fileRevised, .documentKeyNotListed, .pageKeyNotListed, .resourceNotListed,
                 .operatorNotListed, .textNotInvisible, .pictureNotDrawnOnce, .pictureNotOverThePage,
                 .pictureKeyNotListed, .pictureColourNotListed, .pictureSizeDiffers, .unlistedSegment:
                .unreadableInput
            }
        }
    }

    let reason: Reason
    let offset: Int
}

/// One 8-by-8 block as the walk leaves it: its mean level (the DC value
/// times the file's own step) and whether every other coefficient is zero.
struct CodedBlock: Equatable, Sendable {
    let dcTimesStep: Int32
    let flat: Bool
}

/// One component of the frame: its id and sampling factors.
struct FrameComponent: Equatable, Sendable {
    let id: Int
    let horizontal: Int
    let vertical: Int
}

/// A segment outside the list the header admits, by kind and length.
struct UnlistedSegment: Equatable, Sendable {
    let marker: UInt8
    /// The segment's bytes, its marker included.
    let length: Int
}

/// A page picture read to its end marker. Built by the walker alone.
struct PageImageWalk: Sendable {
    let width: Int
    let height: Int
    let components: [FrameComponent]
    /// The block groups the frame declares, every one decoded.
    let blockGroupCount: Int
    let restartCount: Int
    let bytesConsumed: Int
    /// The SHA-256 of the image stream as read.
    let sha256: Data
    let unlistedSegments: [UnlistedSegment]
    /// Boundaries whose padding bits were not all ones (counted, not refused).
    let paddingNotOnes: Int
    /// For each component, its blocks in raster order, `blocksWide[c]` a row.
    let blocks: [[CodedBlock]]
    let blocksWide: [Int]
    let blocksHigh: [Int]

    /// True when the picture carries colour (three components).
    var hasColour: Bool { components.count == 3 }

    /// Only the walker's file can make a seal, so only the walker builds a walk.
    init(seal: JPEGEntropyWalk.Seal, width: Int, height: Int, components: [FrameComponent],
         blockGroupCount: Int, restartCount: Int, bytesConsumed: Int, sha256: Data,
         unlistedSegments: [UnlistedSegment], paddingNotOnes: Int,
         blocks: [[CodedBlock]], blocksWide: [Int], blocksHigh: [Int]) {
        _ = seal
        self.width = width
        self.height = height
        self.components = components
        self.blockGroupCount = blockGroupCount
        self.restartCount = restartCount
        self.bytesConsumed = bytesConsumed
        self.sha256 = sha256
        self.unlistedSegments = unlistedSegments
        self.paddingNotOnes = paddingNotOnes
        self.blocks = blocks
        self.blocksWide = blocksWide
        self.blocksHigh = blocksHigh
    }
}

/// One page's outcome.
enum PageImageOutcome: Sendable {
    case completed(PageImageWalk)
    case couldNotFinish(PageImageRefusal)

    var kind: OutcomeKind {
        switch self {
        case .completed: .completed
        case .couldNotFinish(let refusal): .fault(refusal.reason.fault)
        }
    }
}

/// The reader's answer for a document: every page's outcome, or, when the
/// run has no record, one answer for the whole document.
enum PageImageReport: Sendable {
    case pages([PageImageOutcome])
    case noRecord

    /// What each answer is about, and how the reader ended on it.
    var outcomes: [(unit: CheckUnit, kind: OutcomeKind)] {
        switch self {
        case .noRecord: [(.document, .fault(.noRecord))]
        case .pages(let pages): pages.enumerated().map { (.page($0.offset), $0.element.kind) }
        }
    }
}
