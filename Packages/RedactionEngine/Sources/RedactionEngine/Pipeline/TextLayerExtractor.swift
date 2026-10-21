import PDFKit
import CoreGraphics

// PDFSelection-based character extraction.
// Uses composed-character-sequence iteration to handle surrogate pairs,
// emoji, and other multi-codeunit characters correctly.
// Avoids PDFPage.characterBounds(at:) due to iOS 18 regression (FB14843671, KI-2).

/// Stateless text extractor for the Searchable Redaction pipeline.
/// Extracts character positions from source PDF pages BEFORE rasterization
/// to preserve text layer data.
public struct TextLayerExtractor: Sendable {

    public init() {}

    /// Extract all characters and their bounding boxes from a PDF page.
    ///
    /// Uses PDFSelection-based workaround for character bounds (KI-2).
    /// Iterates using composed-character-sequence ranges to correctly
    /// handle surrogate pairs, emoji, and composed characters.
    /// Synthesized separator offsets whose selection clamps to a
    /// neighboring glyph produce no entry, and neither does a whitespace
    /// offset whose selection box spans an inter-run gutter (see the
    /// in-loop notes); word-spacing whitespace keeps its entry.
    /// Each entry carries `lineIndex` — the count of line-separator
    /// offsets seen before it in `page.string`; the line-aware
    /// character filter derives its per-line bands from this partition.
    ///
    /// - Parameter hasHiddenOCG: Doc-level OCG hidden-layer presence flag.
    ///   Computed once per document at import (ImportService.swift) so the
    ///   page-level check does not depend on `PDFDocument.documentURL`,
    ///   which is nil for `PDFDocument(data:)`. Defaults to `false` for
    ///   call sites that load fixtures via URL.
    /// - Throws: `PipelineError.redactionError(.reconstructionFailed)` if the
    ///   page references hidden OCG layers.
    /// - Returns: Array of CharacterInfo in document order.
    @concurrent
    public func extractCharacters(
        from page: PDFPage, hasHiddenOCG: Bool = false
    ) async throws -> [CharacterInfo] {
        try Task.checkCancellation()

        // OCG hidden text defense: page.string extracts ALL
        // text including text in OCG layers marked /OFF. If hidden OCGs are
        // detected, throw to trigger per-page fallback to Secure Rasterization.
        if Self.pageReferencesHiddenOCG(page, hasHiddenOCG: hasHiddenOCG) {
            throw PipelineError.redactionError(.reconstructionFailed)
        }

        guard let pageText = page.string else { return [] }
        let nsText = pageText as NSString
        let totalCodeUnits = page.numberOfCharacters  // UTF-16 count
        var characters: [CharacterInfo] = []
        characters.reserveCapacity(totalCodeUnits)

        // Canonical coordinate contract — `sel.bounds(for:)` returns
        // coordinates in the source page's ABSOLUTE, UNROTATED (MediaBox/user)
        // space: it includes the cropBox origin offset (pinned for a
        // non-zero origin by `nonZeroCropBoxSelectionFrameProbe`) and is
        // INVARIANT under /Rotate (PDFKit treats /Rotate as a pure display
        // attribute; pinned for all four rotations by
        // `e1SelectionFrameUnderRotation`). To land every `CharacterInfo.bounds`
        // in OUTPUT-page coordinates — zero-origin AND rotation-applied
        // (displayed) — from extraction onward, the full source→output transform
        // is applied per glyph below:
        //   Translation: subtract the cropBox origin → cropBox-LOCAL.
        //   Rotation (T_rot): rotate the local rect into displayed space.
        // Order is local-FIRST-then-rotate: the mirror terms are only
        // meaningful against local extents, so rotation × non-zero CropBox
        // composes correctly only in this order. The rasterizer builds its
        // region-conversion basis on the matching zero-origin displayed output
        // page (`effectiveSize`), so the filter, the layout/bridge check,
        // and the Layer-7 digest all compare in ONE frame; the region side needs
        // NO mirror — it is produced in displayed space by every producer
        // Read the cropBox ONCE (not per glyph); `extractCharacters`
        // is a concurrency-validated PDFKit surface. For a
        // zero-origin, unrotated source page the transform is identity (the
        // PR #153 fixtures stay bit-identical).
        let cropBox = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360

        // Composed-character-sequence iteration via NSString.
        // PDFKit APIs use UTF-16 offsets.
        // 256-iteration band counter — a 10k-character
        // page otherwise exceeds the 50 ms p95 cancel→surrender budget.
        var utf16Offset = 0
        var bandCounter = 0
        // Line partition: ticks at every line-separator source offset,
        // including offsets the guards below skip (nil selection, zero-size
        // bounds), so `lineIndex` is a property of the string alone.
        var lineIndex = 0
        // Break reference: the previous appended entry's PRE-rotation
        // width. Pre-rotation because /Rotate 90/270 swaps the axes and the
        // gutter test below compares along the advance axis.
        var previousLocalWidth: CGFloat?
        while utf16Offset < totalCodeUnits {
            if bandCounter & 0xFF == 0 { try Task.checkCancellation() }
            bandCounter += 1
            let composedRange = nsText.rangeOfComposedCharacterSequence(at: utf16Offset)

            let substring = nsText.substring(with: composedRange)
            if substring.contains(where: \.isNewline) {
                lineIndex += 1
                // Only a PURE separator cluster is consumed here. NSString
                // can compose a separator with a following combining mark
                // into one cluster ("\n" + U+0301); the mark is content and
                // its offset falls through to the normal walk (where the
                // clamp-signature skip still applies), keeping extraction
                // byte-identical to the pre-partition walk for such
                // clusters.
                if substring.allSatisfy(\.isNewline) {
                    utf16Offset += max(composedRange.length, 1)
                    continue
                }
            }

            guard let sel = page.selection(for: composedRange) else {
                utf16Offset += max(composedRange.length, 1)
                continue
            }
            let localBounds = sel.bounds(for: page)
                .offsetBy(dx: -cropBox.origin.x, dy: -cropBox.origin.y)  // cropBox-local translation
            let bounds = Self.rotateRectIntoOutputSpace(
                localBounds, sourceCropSize: cropBox.size, rotation: rotation
            )  // T_rot
            // Skip zero-size bounds (whitespace, control characters)
            guard bounds.width > 0, bounds.height > 0 else {
                utf16Offset += max(composedRange.length, 1)
                continue
            }

            let char = sel.string ?? substring
            if SandwichMetrics.isLineageWhitespace(substring) {
                // `page.string` interleaves synthesized separator characters
                // (inter-run newlines/spaces) that have no glyph of their
                // own; `selection(for:)` over such an offset clamps to the
                // preceding glyph and reports that glyph's character with
                // its full-size, non-zero bounds — the zero-size guard above
                // does not exclude it. A whitespace-source offset
                // (`SandwichMetrics.isLineageWhitespace`, the lineage-walk
                // predicate) whose selection returns a DIFFERENT character
                // is that clamp case: skip it.
                if char != substring {
                    utf16Offset += max(composedRange.length, 1)
                    continue
                }
                // Some whitespace offsets get a selection box
                // spanning a whole inter-run gutter (measured 17–397pt on
                // the sample fixture vs 1.9–6.8pt word spaces). Such an
                // entry sits gap-free against BOTH flanking columns, so the
                // run grouping can never split there and the drawn line
                // compresses the gutter to one cell — glyph geometry lands
                // far off the raster. The skip threshold is the grouping
                // adjacency break itself (`runMemberGroups`: a gap is a run
                // break at ≥ prev.width × 1.5): a whitespace entry at least
                // that wide is exactly one able to bridge a break — drop it
                // and the flanks split and bridge at raster-true positions.
                // Narrower whitespace cannot change grouping and keeps its
                // entry, so word spacing inside runs is preserved.
                let breakReference = previousLocalWidth ?? localBounds.height
                if localBounds.width >= breakReference * 1.5 {
                    utf16Offset += max(composedRange.length, 1)
                    continue
                }
            }
            characters.append(CharacterInfo(
                character: char, bounds: bounds, stringIndex: utf16Offset,
                lineIndex: lineIndex
            ))
            previousLocalWidth = localBounds.width

            utf16Offset += composedRange.length  // Advances by 2 for surrogate pairs
        }
        return characters
    }

    // MARK: - Rotation transform (T_rot)

    /// Map a cropBox-LOCAL rect (origin already subtracted) into OUTPUT-page
    /// space: zero-origin and rotation-applied (DISPLAYED). `/Rotate r` displays
    /// the page rotated r° clockwise (ISO 32000, clause 8.3.2; PixelOperations.swift
    /// note); PDFKit clamps r to {0, 90, 180, 270}, and the caller pre-normalizes.
    ///
    /// `size` is the SOURCE cropBox size, PRE-swap — the same `(w, h)` whose swap
    /// produces `effectiveSize`, never the effective/displayed dims.
    /// `page.bounds(for: .cropBox)` reports this unrotated size for all rotations
    /// (pinned by E1). The four-case derivation (independently re-derived and
    /// corner-checked) follows, with local rect `(x, y, wr, hr)`:
    ///   • r = 0:   identity.
    ///   • r = 90:  origin (y, w − x − wr), size (hr, wr).
    ///   • r = 180: origin (w − x − wr, h − y − hr), size (wr, hr) — double origin
    ///              mirror, NO dimension swap.
    ///   • r = 270: origin (h − y − hr, x), size (hr, wr).
    /// The region side needs no mirror (it is produced in displayed space by every
    /// producer), so both filter inputs end in one displayed frame.
    static func rotateRectIntoOutputSpace(
        _ rect: CGRect, sourceCropSize size: CGSize, rotation: Int
    ) -> CGRect {
        let x = rect.minX, y = rect.minY, wr = rect.width, hr = rect.height
        let w = size.width, h = size.height
        switch rotation {
        case 90:
            return CGRect(x: y, y: w - x - wr, width: hr, height: wr)
        case 180:
            return CGRect(x: w - x - wr, y: h - y - hr, width: wr, height: hr)
        case 270:
            return CGRect(x: h - y - hr, y: x, width: hr, height: wr)
        default:  // 0 — and any unexpected value after clamping — is identity
            return rect
        }
    }

    /// The inverse of `rotateRectIntoOutputSpace`: a DISPLAYED (output-page)
    /// rect back in cropBox-LOCAL source space. `size` is again the SOURCE
    /// crop size, pre-swap. Each case solves the forward case for
    /// `(x, y, wr, hr)`; the four-rotation round-trip is pinned by
    /// `TextLayerExtractorTests`. With displayed rect `(X, Y, W, H)`:
    ///   • r = 90:  origin (w − Y − H, X), size (H, W).
    ///   • r = 180: origin (w − X − W, h − Y − H), size (W, H) — self-inverse.
    ///   • r = 270: origin (Y, h − X − W), size (H, W).
    static func unrotateRectIntoSourceSpace(
        _ rect: CGRect, sourceCropSize size: CGSize, rotation: Int
    ) -> CGRect {
        let x = rect.minX, y = rect.minY, wr = rect.width, hr = rect.height
        let w = size.width, h = size.height
        switch rotation {
        case 90:
            return CGRect(x: w - y - hr, y: x, width: hr, height: wr)
        case 180:
            return CGRect(x: w - x - wr, y: h - y - hr, width: wr, height: hr)
        case 270:
            return CGRect(x: y, y: h - x - wr, width: hr, height: wr)
        default:
            return rect
        }
    }

    /// `rotateRectIntoOutputSpace` on a point (a zero-size rect: every
    /// corner is the point, so the rect map is the point map).
    static func rotatePointIntoOutputSpace(
        _ point: CGPoint, sourceCropSize size: CGSize, rotation: Int
    ) -> CGPoint {
        rotateRectIntoOutputSpace(
            CGRect(origin: point, size: .zero), sourceCropSize: size, rotation: rotation
        ).origin
    }

    /// `unrotateRectIntoSourceSpace` on a point.
    static func unrotatePointIntoSourceSpace(
        _ point: CGPoint, sourceCropSize size: CGSize, rotation: Int
    ) -> CGPoint {
        unrotateRectIntoSourceSpace(
            CGRect(origin: point, size: .zero), sourceCropSize: size, rotation: rotation
        ).origin
    }

    // MARK: - OCG Hidden Layer Defense

    /// Check if a page references Optional Content Groups with hidden layers.
    /// Conservative approach for v1.0: any hidden OCG triggers fallback.
    ///
    /// page.string extracts text from ALL OCGs including those marked /OFF.
    /// If hidden text exists, the character filter could miss it (text is in
    /// page.string but not visually positioned), creating a leakage path.
    ///
    /// The doc-level walk (`/OCProperties → /D`) is precomputed at import
    /// time and supplied via `hasHiddenOCG`. The previous in-engine walk went
    /// through `page.document?.documentURL`, which is nil for
    /// `PDFDocument(data:)` — i.e. every production import path — so the
    /// defense silently failed open. The page-level check stays here because
    /// it varies per page: it reads the page's own resource dictionary or the
    /// one it inherits from the page tree, and every form XObject reachable
    /// from it, for a `/Properties` entry (how content names a group) or an
    /// `/OC` entry on the XObject itself.
    static func pageReferencesHiddenOCG(
        _ page: PDFPage, hasHiddenOCG: Bool
    ) -> Bool {
        guard hasHiddenOCG else { return false }

        // A page whose dictionary cannot be read is not known to be free of
        // hidden content: it reads as referencing one, and takes the secure
        // path through the fallback the caller already has.
        guard let pageRef = page.pageRef,
              let dict = pageRef.dictionary else { return true }

        switch inheritedResources(of: dict) {
        case .none:
            return false
        case .unreadable:
            return true
        case .found(let resources):
            var visited = WalkVisited()
            return resourcesNameOptionalContent(resources, depth: 0, visited: &visited)
        }
    }

    /// Bound on the `/Parent` chain walked for an inherited `/Resources`.
    static let maxPageTreeDepth = 32
    /// Bound on form XObjects nested inside one another.
    static let maxFormXObjectDepth = 8

    /// What one walk has already read. A resource dictionary answers the
    /// same way on every visit, so N forms that share one dictionary cost
    /// one enumeration of it rather than N; a stream seen before is not
    /// walked twice (a form that draws itself).
    struct WalkVisited {
        var streams: Set<CGPDFStreamRef> = []
        var resources: Set<CGPDFDictionaryRef> = []
    }

    /// What the page-tree walk found: the resource dictionary in force, none
    /// anywhere on the chain, or a chain the walk could not follow to its end.
    enum ResourceLookup {
        case found(CGPDFDictionaryRef)
        case none
        case unreadable
    }

    /// The page's own `/Resources`, or the nearest ancestor's through the
    /// `/Parent` chain (the entry is inheritable; ISO 32000-1 §7.7.3.4). A
    /// chain longer than `maxPageTreeDepth` is not read to its end.
    static func inheritedResources(of page: CGPDFDictionaryRef) -> ResourceLookup {
        var node = page
        for _ in 0..<maxPageTreeDepth {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(node, "Resources", &resources), let resources {
                return .found(resources)
            }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(node, "Parent", &parent), let parent else {
                return .none
            }
            node = parent
        }
        return .unreadable
    }

    /// True when a resource dictionary names optional content — a
    /// `/Properties` entry — or when a form XObject reachable through its
    /// `/XObject` entries carries `/OC` or names optional content through
    /// its own resources. A nesting past `maxFormXObjectDepth`, an XObject
    /// whose dictionary cannot be read, or a walk cancelled part-way is not
    /// known to be clean and reads as naming it.
    static func resourcesNameOptionalContent(
        _ resources: CGPDFDictionaryRef, depth: Int, visited: inout WalkVisited
    ) -> Bool {
        if visited.resources.contains(resources) { return false }
        visited.resources.insert(resources)
        var properties: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Properties", &properties),
           properties != nil {
            return true
        }
        return formXObjects(in: resources, depth: depth, visited: &visited) { dictionary in
            var optionalContent: CGPDFObjectRef?
            return CGPDFDictionaryGetObject(dictionary, "OC", &optionalContent)
        } recurse: { inner, visited in
            resourcesNameOptionalContent(inner, depth: depth + 1, visited: &visited)
        }
    }

    /// True when a `/Properties` value in `resources`, or the `/OC` value of
    /// a form XObject reachable from it, is anything but a plain group: a
    /// membership dictionary (`/Type /OCMD`, whose `/P` or `/VE` can hide
    /// content while every group is on), a dictionary with no type, a value
    /// that is no dictionary, or one that cannot be read. The document walk
    /// reads such a reference as hidden without evaluating it.
    static func resourcesNameMembershipDictionary(
        _ resources: CGPDFDictionaryRef, depth: Int, visited: inout WalkVisited
    ) -> Bool {
        if visited.resources.contains(resources) { return false }
        visited.resources.insert(resources)
        var properties: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Properties", &properties), let properties {
            var other = false
            CGPDFDictionaryApplyBlock(properties, { _, value, _ in
                if isPlainGroup(value) { return true }
                other = true
                return false
            }, nil)
            if other { return true }
        }
        return formXObjects(in: resources, depth: depth, visited: &visited) { dictionary in
            var optionalContent: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(dictionary, "OC", &optionalContent),
                  let optionalContent else { return false }
            return !isPlainGroup(optionalContent)
        } recurse: { inner, visited in
            resourcesNameMembershipDictionary(inner, depth: depth + 1, visited: &visited)
        }
    }

    /// A dictionary of `/Type /OCG`. Anything else — a membership
    /// dictionary, a dictionary with no type, a non-dictionary — is not a
    /// plain group.
    static func isPlainGroup(_ value: CGPDFObjectRef) -> Bool {
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary else {
            return false
        }
        var type: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Type", &type), let type else { return false }
        return String(cString: type) == "OCG"
    }

    /// Walks the form XObjects under `resources`' `/XObject` entry once each:
    /// `carries` reads the form's own dictionary, `recurse` its `/Resources`.
    /// A nesting past `maxFormXObjectDepth`, an entry or dictionary that
    /// cannot be read, or a cancelled task answers true (not known clean).
    static func formXObjects(
        in resources: CGPDFDictionaryRef, depth: Int, visited: inout WalkVisited,
        carries: (CGPDFDictionaryRef) -> Bool,
        recurse: (CGPDFDictionaryRef, inout WalkVisited) -> Bool
    ) -> Bool {
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
              let xobjects else { return false }
        guard depth < maxFormXObjectDepth else { return true }

        var streams: [CGPDFStreamRef] = []
        var unreadable = false
        CGPDFDictionaryApplyBlock(xobjects, { _, value, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(value, .stream, &stream), let stream {
                streams.append(stream)
            } else {
                unreadable = true
            }
            return true
        }, nil)
        if unreadable { return true }

        for stream in streams {
            if Task.isCancelled { return true }
            if visited.streams.contains(stream) { continue }
            visited.streams.insert(stream)
            guard let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Form" else { continue }
            if carries(dictionary) { return true }
            var inner: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner), let inner,
               recurse(inner, &visited) {
                return true
            }
        }
        return false
    }

    /// Doc-level OCG check intended to run once at import time, when raw bytes
    /// are still available to build a `CGPDFDocument`. Walks the catalog for
    /// `/OCProperties → /D` and reports whether the document can hide a
    /// group's content: a non-empty `/OFF` array; a `/BaseState` of `OFF`
    /// with a group in `/OCGs` that the `/ON` array does not name (the
    /// groups are matched one by one, so a list that names one group twice
    /// does not stand in for another; no `/ON` at all turns every group
    /// off); a usage-application entry (`/AS`), by which a viewer turns
    /// groups off on its own events; or, anywhere a page or a form names
    /// optional content, a membership dictionary (`/Type /OCMD`), whose
    /// policy or visibility expression can hide content while every group is
    /// on. The last two are read as hidden, not evaluated. A catalog the
    /// reader cannot give, an `/OCProperties` without its `/D`, or an OFF
    /// base state with no readable group list answers true: the document is
    /// not known to be free of hidden content. The page-level companion
    /// `pageReferencesHiddenOCG(_:hasHiddenOCG:)` consumes this flag and adds
    /// the per-page resource check.
    public static func documentHasHiddenOCG(_ document: CGPDFDocument) -> Bool {
        guard let catalog = document.catalog else { return true }

        var ocProps: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "OCProperties", &ocProps),
              let ocProperties = ocProps else { return false }

        // /D is required beside /OCGs (ISO 32000-1 §8.11.4.2): its absence is
        // a malformed dictionary, not a document with no hidden layer.
        var defaultConfig: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(ocProperties, "D", &defaultConfig),
              let config = defaultConfig else { return true }

        if defaultConfigurationHidesAGroup(config, groupsIn: ocProperties) { return true }

        // Usage application (ISO 32000-1 §8.11.4.4): the viewer may turn
        // groups off on view, print or export events. Not evaluated here.
        var usageApplication: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(config, "AS", &usageApplication) { return true }

        return pagesNameMembershipDictionary(in: document)
    }

    /// The default configuration's own hiding: a non-empty `/OFF`, or an OFF
    /// base state with a group the `/ON` array does not name.
    static func defaultConfigurationHidesAGroup(
        _ config: CGPDFDictionaryRef, groupsIn ocProperties: CGPDFDictionaryRef
    ) -> Bool {
        var offArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(config, "OFF", &offArray), let off = offArray,
           CGPDFArrayGetCount(off) > 0 {
            return true
        }

        // A base state of OFF hides every group the `/ON` array does not
        // name (ISO 32000-1 §8.11.4.3).
        var baseState: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(config, "BaseState", &baseState), let baseState,
              String(cString: baseState) == "OFF" else { return false }
        var groups: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(ocProperties, "OCGs", &groups), let groups else {
            return true
        }
        let groupCount = CGPDFArrayGetCount(groups)
        guard groupCount > 0 else { return false }
        var onArray: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(config, "ON", &onArray), let on = onArray else {
            return true
        }
        // The reader resolves one indirect object to one dictionary, so the
        // groups are matched by identity; an entry that is no dictionary
        // names no group. A group the list does not name is hidden.
        var named: Set<CGPDFDictionaryRef> = []
        for index in 0..<CGPDFArrayGetCount(on) {
            var group: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(on, index, &group), let group {
                named.insert(group)
            }
        }
        for index in 0..<groupCount {
            var group: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(groups, index, &group), let group,
                  named.contains(group) else { return true }
        }
        return false
    }

    /// True when any page's resources (own or inherited), or a form XObject
    /// reachable from them, name optional content through anything but a
    /// plain group. A page whose dictionary cannot be read answers true.
    static func pagesNameMembershipDictionary(in document: CGPDFDocument) -> Bool {
        var visited = WalkVisited()
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { return false }
        for index in 1...pageCount {
            if Task.isCancelled { return true }
            guard let page = document.page(at: index), let dictionary = page.dictionary else {
                return true
            }
            switch inheritedResources(of: dictionary) {
            case .none:
                continue
            case .unreadable:
                return true
            case .found(let resources):
                if resourcesNameMembershipDictionary(resources, depth: 0, visited: &visited) {
                    return true
                }
            }
        }
        return false
    }
}

