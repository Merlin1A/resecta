import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import RedactionEngine

// The Photos door: the system picker, out of process, with no library
// access and no usage string — the app receives only the items the user
// picks, one at a time, in the order picked. This is the only PhotosUI
// import in the app.

/// Presents the Photos picker and hands the pick to `onPick` as a stream of
/// each image's bytes plus the count, in pick order.
struct PhotoImportModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: (AsyncThrowingStream<Data, any Error>, Int) -> Void
    @State private var selection: [PhotosPickerItem] = []

    /// The most images one pick may hold; the loader's cap is the same number.
    static let maxSelection = ImportLimits.standard.maxImagesPerImport

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $isPresented, selection: $selection,
                maxSelectionCount: Self.maxSelection, selectionBehavior: .ordered,
                matching: .images, preferredItemEncoding: .current)
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                let picked = items
                selection = []
                onPick(Self.stream(for: picked), picked.count)
            }
    }

    /// One item at a time, in pick order, loaded only when the loader asks
    /// for the next one: at most one picked image's bytes are resident, as
    /// `DocumentLoader` promises. An item whose declared types do not
    /// conform to an accepted image type is never loaded: the stream throws
    /// the unsupported-format refusal and the whole import refuses. An item
    /// that fails to load is refused as damaged.
    static func stream(for items: [PhotosPickerItem]) -> AsyncThrowingStream<Data, any Error> {
        pullStream(count: items.count) { index in
            let item = items[index]
            return try await loadItem(declaredTypes: item.supportedContentTypes) {
                try await item.loadTransferable(type: Data.self)
            }
        }
    }

    /// A stream of `count` items whose `load` runs for item n only when the
    /// consumer asks for item n — never ahead of it. An error ends the
    /// stream: a cancellation as itself, a refusal as itself, anything else
    /// as the damaged-file refusal.
    static func pullStream(
        count: Int, load: @escaping @Sendable (Int) async throws -> Data
    ) -> AsyncThrowingStream<Data, any Error> {
        let cursor = PullCursor()
        return AsyncThrowingStream(unfolding: {
            let index = await cursor.next()
            guard index < count else { return nil }
            do {
                try Task.checkCancellation()
                return try await load(index)
            } catch is CancellationError { // LegalPhrases:safe (Swift keyword)
                throw CancellationError()
            } catch let error as PipelineError { // LegalPhrases:safe (Swift keyword)
                throw error
            } catch { // LegalPhrases:safe (Swift keyword)
                throw PipelineError.importError(.corrupt)
            }
        })
    }

    /// One picked item: refused by its declared types before any load, and
    /// as damaged when the load yields nothing.
    static func loadItem(
        declaredTypes: [UTType], fetch: () async throws -> Data?
    ) async throws -> Data {
        guard conforms(declaredTypes) else {
            throw PipelineError.importError(.unsupportedFormat)
        }
        guard let data = try await fetch() else {
            throw PipelineError.importError(.corrupt)
        }
        return data
    }

    /// Whether any of an item's declared types is an accepted image type.
    static func conforms(_ types: [UTType]) -> Bool {
        types.contains { declared in
            ImportService.acceptedImageTypes.contains { declared.conforms(to: $0) }
        }
    }
}

extension View {
    /// The Photos door. `onPick` receives the images' bytes as a stream in
    /// pick order and the number of images picked.
    func photoImport(isPresented: Binding<Bool>,
                     onPick: @escaping (AsyncThrowingStream<Data, any Error>, Int) -> Void) -> some View {
        modifier(PhotoImportModifier(isPresented: isPresented, onPick: onPick))
    }
}

/// The index of the next item a pull stream loads.
private actor PullCursor {
    private var index = 0
    func next() -> Int {
        defer { index += 1 }
        return index
    }
}
