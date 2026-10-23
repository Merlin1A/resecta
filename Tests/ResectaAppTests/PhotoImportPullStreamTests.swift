import Testing
import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import RedactionEngine
@testable import ResectaApp

// The Photos door hands the loader one picked image at a time. Each image's
// bytes load only when the loader asks for the next one, so at most one
// picked image is resident while the loader works — a pick of twenty large
// photos is never twenty buffers at once. At the parent the door loaded every
// pick into an unbounded buffer ahead of the loader.

@Suite("Photos door: the pull stream, the type gate and the error mapping")
struct PhotoImportPullStreamTests {

    /// Counts loads and the bytes handed out and not yet taken back.
    actor Ledger {
        var loads = 0
        var outstanding = 0
        var mostOutstanding = 0
        func loaded() { loads += 1; outstanding += 1; mostOutstanding = max(mostOutstanding, outstanding) }
        func released() { outstanding -= 1 }
    }

    /// A refusal's name, or the error's type.
    static func label(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard case PipelineError.importError(let failure) = error else { return "\(type(of: error))" }
        switch failure {
        case .corrupt: return "corrupt"
        case .unsupportedFormat: return "unsupportedFormat"
        default: return "\(failure)"
        }
    }

    @Test("Each picked image loads only when the loader asks for it: never more than one resident")
    func loadsOnDemandOneAtATime() async throws {
        let ledger = Ledger()
        let stream = PhotoImportModifier.pullStream(count: 5) { index in
            await ledger.loaded()
            return Data(repeating: UInt8(index), count: 1_024)
        }
        var seen = 0
        for try await data in stream {
            // A slow consumer gives an eager producer time to run ahead.
            try await Task.sleep(for: .milliseconds(20))
            #expect(await ledger.loads == seen + 1, "item \(seen): no load ahead of the consumer")
            #expect(data.first == UInt8(seen))
            seen += 1
            await ledger.released()
        }
        #expect(seen == 5)
        #expect(await ledger.mostOutstanding == 1)
    }

    @Test("An error ends the stream: a cancellation and a refusal as themselves, anything else as damaged")
    func errorsEndTheStream() async throws {
        struct Unexpected: Error {}
        for (thrown, expected) in [
            (PipelineError.importError(.unsupportedFormat) as any Error, "unsupportedFormat"),
            (Unexpected() as any Error, "corrupt"),
            (CancellationError() as any Error, "cancelled"),
        ] {
            let ledger = Ledger()
            let stream = PhotoImportModifier.pullStream(count: 3) { index in
                await ledger.loaded()
                if index == 1 { throw thrown }
                return Data([1])
            }
            var received = 0
            var ended = "finished"
            do {
                for try await _ in stream { received += 1 }
            } catch { // LegalPhrases:safe (Swift keyword)
                ended = Self.label(error)
            }
            #expect(ended == expected)
            #expect(received == 1)
            #expect(await ledger.loads == 2, "no item after the failing one is loaded")
        }
    }

    @Test("A pick whose declared types are not an accepted image type is refused before any load")
    func declaredTypeGate() async throws {
        #expect(PhotoImportModifier.conforms([.jpeg]) && PhotoImportModifier.conforms([.png]) && PhotoImportModifier.conforms([.heic]))
        #expect(PhotoImportModifier.conforms([.gif, .jpeg]), "any accepted type among the declared ones")
        #expect(!PhotoImportModifier.conforms([.gif]) && !PhotoImportModifier.conforms([.webP]) && !PhotoImportModifier.conforms([.pdf]))
        #expect(!PhotoImportModifier.conforms([]))

        var fetched = false
        do {
            _ = try await PhotoImportModifier.loadItem(declaredTypes: [.gif]) { fetched = true; return Data([1]) }
            Issue.record("a GIF pick loaded")
        } catch { // LegalPhrases:safe (Swift keyword)
            #expect(Self.label(error) == "unsupportedFormat")
        }
        #expect(!fetched, "a refused type is never loaded")
        do {
            _ = try await PhotoImportModifier.loadItem(declaredTypes: [.jpeg]) { nil }
            Issue.record("an empty load opened")
        } catch { // LegalPhrases:safe (Swift keyword)
            #expect(Self.label(error) == "corrupt")
        }
        let data = try await PhotoImportModifier.loadItem(declaredTypes: [.heic]) { Data([7]) }
        #expect(data == Data([7]))
    }

    @Test("A drop of several files names that only the first was opened")
    func multiItemDropNotice() {
        #expect(ImportService.dropOpenedFirstMessage(droppedCount: 3)
                == "Only the first of the 3 dropped files was opened. Drop the others one at a time.")
    }

    // MARK: - The loader's size arms, exercised

    @Test("An image over the declared-pixel cap is refused at the size read; one at the cap opens")
    func declaredPixelCapArm() async {
        var limits = ImportLimits.standard
        limits.maxDeclaredImagePixels = 1_000_000
        #expect(await ImageImportLoaderTests.refusal(ImageFixtures.jpeg(width: 2_000, height: 1_000, marker: false), limits: limits)
                == "invalidPageDimensions")
        #expect(await ImageImportLoaderTests.refusal(ImageFixtures.jpeg(width: 1_000, height: 1_000, marker: false), limits: limits)
                == "open")
    }

    @Test("A real image over the decode budget is decoded down to the budget")
    func decodeIsBoundedByTheBudget() async throws {
        var limits = ImportLimits.standard
        limits.maxDecodedImagePixels = 1_000_000
        let loaded = try await ImageImportLoaderTests.load(ImageFixtures.jpeg(width: 4_000, height: 3_000, marker: false), limits: limits)
        let (w, h) = try #require(ImageImportLoaderTests.embeddedImageSize(try ImageImportLoaderTests.page(loaded)))
        #expect(w * h <= limits.maxDecodedImagePixels, "\(w) × \(h)")
        #expect(abs(Double(w) / Double(h) - 4.0 / 3.0) < 0.01, "the aspect is kept")
    }
}
