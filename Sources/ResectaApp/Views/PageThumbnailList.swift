import SwiftUI
import PDFKit
import UIKit
import RedactionEngine

// UI_UX §6.3: iPad sidebar with page thumbnails and region count badges.
// GAP-6 §9.1: Per-page text layer status indicators.
// GAP-6 §9.2: "With Text" filter chip for large documents.

// §9.2: Page filter — amends deferred A14.1.
private enum PageFilter: String, CaseIterable {
    case all = "All Pages"
    case withRegions = "With Regions"
    case withText = "With Text"
}

struct PageThumbnailList: View {
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState

    /// Per-page modes from the verification report, only when modes are mixed.
    /// nil when not in .verified phase or all pages used the same mode.
    private var perPageModes: [PipelineMode]? {
        guard case .verified(let report) = documentState.phase else { return nil }
        return report.perPageModes.hasMixedModes ? report.perPageModes : nil
    }

    /// PD-5: per-page fallback reasons beside the modes — non-nil entries
    /// only for pages whose mode fell back in a Searchable-mode run, so
    /// secure-raster runs keep their plain badges.
    private var perPageFallbackReasons: [TextLayerDetector.FallbackReason?]? {
        guard case .verified(let report) = documentState.phase else { return nil }
        return report.perPageFallbackReasons.hasAnyFallbackReason
            ? report.perPageFallbackReasons : nil
    }

    /// Badge text for a page's mode row: "Rasterized — right-to-left text"
    /// when the page fell back with a recorded reason, else the plain mode
    /// name. Static-shaped for testability via `PageThumbnailList.badgeText`.
    static func badgeText(
        mode: PipelineMode, reason: TextLayerDetector.FallbackReason?
    ) -> String {
        if let reason {
            return "\(mode.shortDisplayName) — \(reason.shortReasonText)"
        }
        return mode.shortDisplayName
    }

    // §9.2: Filter state for large documents (pageCount >= 50).
    @State private var pageFilter: PageFilter = .all

    // §9.2: Filtered page indices based on selected filter.
    private var filteredPages: [Int] {
        switch pageFilter {
        case .all:
            return Array(0..<documentState.pageCount)
        case .withRegions:
            return (0..<documentState.pageCount).filter { index in
                (redactionState.regions[index]?.count ?? 0) > 0
            }
        case .withText:
            return (0..<documentState.pageCount).filter { index in
                documentState.textLayerStatus[index] == .rich
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // §9.2: Segmented filter — shown only for large documents (A14.1 threshold).
            if documentState.pageCount >= 50 {
                Picker("Filter", selection: $pageFilter) {
                    Text(PageFilter.all.rawValue).tag(PageFilter.all)
                    Text(PageFilter.withRegions.rawValue).tag(PageFilter.withRegions)
                    if documentState.hasAnyTextLayer {
                        Text(PageFilter.withText.rawValue).tag(PageFilter.withText)
                    }
                }
                .pickerStyle(.segmented)
                .padding(ResectaTokens.Spacing.sm)
            }

            ScrollViewReader { proxy in
                List {
                    ForEach(filteredPages, id: \.self) { index in
                        let regionCount = redactionState.regions[index]?.count ?? 0
                        Button {
                            documentState.currentPageIndex = index
                        } label: {
                            HStack {
                                PageThumbnailView(
                                    document: documentState.sourceDocument,
                                    pageIndex: index
                                )
                                .frame(width: 60, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                // R4/D3: Status dots — orange dot = has regions, none = untouched.
                                // Pattern from Working Copy / PDF Expert.
                                .overlay(alignment: .topTrailing) {
                                    if regionCount > 0 {
                                        Circle()
                                            .fill(.orange)
                                            .frame(width: 8, height: 8)
                                            .padding(2)
                                    }
                                }

                                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                                    Text("Page \(index + 1)")
                                        .font(.subheadline)

                                    // §9.1: Text layer indicator — amends deferred A14.2.
                                    if let status = documentState.textLayerStatus[index] {
                                        HStack(spacing: ResectaTokens.Spacing.xxs) {
                                            switch status {
                                            case .rich:
                                                Image(systemName: "text.justify.left")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                Text("Text")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            case .sparse:
                                                Image(systemName: "text.justify.left")
                                                    .font(.caption2)
                                                    .foregroundStyle(.quaternary)
                                            case .none:
                                                EmptyView()
                                            }
                                        }
                                    }

                                    // Per-page mode badge (only when modes are mixed + verified).
                                    // PD-5: fallback pages carry the short reason.
                                    if let modes = perPageModes, index < modes.count {
                                        let reason = perPageFallbackReasons
                                            .flatMap { index < $0.count ? $0[index] : nil }
                                        Label(Self.badgeText(mode: modes[index], reason: reason),
                                              systemImage: modes[index].symbolName)
                                            .font(.caption2)
                                            .foregroundStyle(modes[index].badgeColor)
                                    }

                                    if regionCount > 0 {
                                        Text("\(regionCount) region\(regionCount == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                        .id(index)
                        .accessibilityLabel(thumbnailAccessibilityLabel(index: index, regionCount: regionCount))
                        .listRowBackground(
                            index == documentState.currentPageIndex
                                ? ResectaTokens.BrandTeal.tint.opacity(0.15) : nil
                        )
                    }
                }
                // WP6a: Auto-scroll sidebar to current page on navigation
                .onChange(of: documentState.currentPageIndex) { _, newIndex in
                    withAnimation(ResectaTokens.Anim.stateChange) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .navigationTitle("Pages")
        .accessibilityIdentifier("pageThumbnailList")
        .onChange(of: documentState.sourceDocument) {
            ThumbnailCache.clear()
            pageFilter = .all
        }
    }
}

// MARK: - Thumbnail Cache

/// NSCache-backed thumbnail cache. Auto-evicts on memory pressure.
/// Keyed by page index; cleared when the source document changes.
///
/// RES-05 (Pkg N): explicit `countLimit` and `totalCostLimit` so the
/// cache cannot grow without bound on multi-hundred-page documents.
/// NSCache's default limits are zero (unbounded) and rely on system
/// memory-pressure callbacks to evict. The explicit ceilings give the
/// app a deterministic upper bound that's reached before iOS would
/// otherwise issue a memory warning. Sized for typical iPhone /
/// iPad page-thumbnail workloads — 200 thumbnails is well past the
/// visible page set on either device class, and 64 MB caps the
/// retained bitmaps at roughly 320 KB / thumb (the rasterized PDFKit
/// thumbnail size at the sidebar scale).
private enum ThumbnailCache {
    // nonisolated(unsafe): all callers are MainActor-isolated (SwiftUI views).
    // NSCache is thread-safe internally but not Sendable.
    nonisolated(unsafe) static let cache: NSCache<NSNumber, UIImage> = {
        let c = NSCache<NSNumber, UIImage>()
        c.countLimit = 200
        c.totalCostLimit = 64 * 1024 * 1024  // 64 MB
        return c
    }()
    static let writeQueue = DispatchQueue(label: "thumbnailCache.write")
    static func get(_ pageIndex: Int) -> UIImage? {
        cache.object(forKey: NSNumber(value: pageIndex))
    }
    static func set(_ image: UIImage, for pageIndex: Int) {
        writeQueue.async {
            cache.setObject(image, forKey: NSNumber(value: pageIndex))
        }
    }
    static func clear() { cache.removeAllObjects() }
}

// MARK: - Accessibility Helpers

extension PageThumbnailList {
    fileprivate func thumbnailAccessibilityLabel(index: Int, regionCount: Int) -> String {
        var label = "Page \(index + 1)"
        if regionCount > 0 {
            label += ", \(regionCount) region\(regionCount == 1 ? "" : "s")"
        }
        if let status = documentState.textLayerStatus[index], status == .rich {
            label += ", has text layer"
        }
        return label
    }
}

// MARK: - Page Thumbnail Renderer

/// Renders a PDF page thumbnail asynchronously to avoid blocking MainActor.
/// Uses ThumbnailCache to avoid re-rendering on repeated sidebar scrolls.
struct PageThumbnailView: View {
    let document: PDFDocument?
    let pageIndex: Int

    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ShimmerPlaceholder()
            }
        }
        .task(id: pageIndex) {
            // Check cache first
            if let cached = ThumbnailCache.get(pageIndex) {
                thumbnail = cached
                return
            }
            guard let page = document?.page(at: pageIndex) else { return }
            // PDFPage is not Sendable; render via nonisolated(unsafe) bridge.
            nonisolated(unsafe) let unsafePage = page
            // Phase 5A: Render at display size (60×80pt), not 2× oversized.
            // Saves ~75% pixel work and cache memory per thumbnail.
            let scale = UITraitCollection.current.displayScale
            let size = CGSize(width: 60 * scale, height: 80 * scale)
            let rendered = await Task.detached(priority: .utility) {
                unsafePage.thumbnail(of: size, for: .cropBox)
            }.value
            if !Task.isCancelled {
                ThumbnailCache.set(rendered, for: pageIndex)
                thumbnail = rendered
            }
        }
        .onChange(of: document) {
            // New document loaded — discard stale thumbnail so the
            // placeholder shows until the .task re-renders.
            thumbnail = nil
        }
    }
}

/// Shimmer loading placeholder for thumbnails.
private struct ShimmerPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                // 04-ux-ui-audit.md §1.3.c: `.primary.opacity(0.10)`
                // inverts per scheme so the shimmer band reads against
                // `.quaternary` in both light and dark.
                LinearGradient(
                    colors: [.clear, .primary.opacity(0.10), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase * 200)
            }
            .clipped()
            .accessibilityLabel("Loading page thumbnail")
            .onAppear {
                // 04-ux-ui-audit.md §3.4.b: mirror the
                // VerificationProgressView reduce-motion gate — skip the
                // perpetual shimmer animation when the user prefers
                // reduced motion.
                guard !reduceMotion else { return }
                withAnimation(
                    .linear(duration: 1.5)
                    .repeatForever(autoreverses: false)
                ) {
                    phase = 1
                }
            }
    }
}
