import CoreGraphics
import Foundation
import OSLog
import PDFKit
import PDFKitGuard

// A text-layer box on a page whose text lies over a page-scale image is fitted
// to the ink it names. Such a text layer was laid down over a picture of the
// page (an earlier Searchable export, a vendor OCR layer) and its glyph boxes
// need not sit on the printed letters: a monospaced layer on a snapped grid sits
// low and to one side, so a box from its selection leaves letter tops and word
// ends outside the fill (SECURITY: ink outside the box survives the redaction).
// The fitted box is the selection's box united with the ink of the word under
// it, read from a render of the box's neighbourhood: the hidden glyphs stay
// covered, and so does the ink. Only a page whose glyphs are inkless — text
// shown in an invisible render mode over a page-scale image — is fitted; every
// other page keeps its selection boxes as they are.

extension DocumentSearcher {

    /// Posted on the main thread when a page's read lands in the background:
    /// a live preview that drew unfitted boxes asks again.
    public static let inkFitDidUpdate = Notification.Name("DocumentSearcher.inkFitDidUpdate")

    /// The render scale for the fit: the OCR leg's 300 dpi.
    static let inkFitScale: CGFloat = 300.0 / 72.0

    /// The margin (points) past the fitted ink on a side the box may grow;
    /// half of it above and below.
    static let inkFitMargin: CGFloat = 1.0

    /// How far (points) a hidden layer was measured to sit from its ink along
    /// its line, plus a margin: 28.7 pt the most for a word that occurs once
    /// on its page, over the statement, packet, multi-column, form, rotated
    /// and third-party inputs (Latin script).
    static let inkFitDriftBound: CGFloat = 36

    /// The growth along the line for each wide (CJK) character before the
    /// match on its line, as a share of the line's height: a fixed-pitch
    /// layer advances 0.6 em where an ideograph takes 1 em, so its drift grows
    /// about 0.4 em a character (50 pt measured, 13 characters in).
    static let inkFitDriftPerWide: CGFloat = 0.5

    /// How far (points) at least a layer may sit above or below its ink:
    /// 7.1 pt measured, 11.7 on a heading whose layer is 8.5 pt tall (one
    /// and a half line heights when larger).
    static let inkFitDriftAcross: CGFloat = 10

    /// The growth along the line for each point between the line's start and
    /// the match's end: a layer set smaller than its ink (a heading's layer
    /// held to the page's usual line height) falls behind it in proportion,
    /// up to 0.42 of the way measured on 18 pt headings.
    static let inkFitDriftPerPoint: CGFloat = 0.45

    /// The constant (points) on top of an aligned word's residual from its
    /// line's drift: 2.25 measured as the least that rejects no true word,
    /// with 1.25 of headroom.
    static let inkFitResidualSlack: CGFloat = 3.5

    /// The line scales a drift model may have (read along the line over the
    /// layer along it); past them the model is not used.
    static let inkFitScaleRange: ClosedRange<CGFloat> = 0.5...2

    /// The margin (points) on an open side of a read word's box when its ink
    /// was not verified (half `inkFitMargin` on a side cut from a longer token).
    static let inkFitAnchorMargin: CGFloat = 1.5

    /// How far (as a share of its height) a read word's box whose ink was not
    /// verified reaches above and below it at the least.
    static let inkFitAnchorReach: CGFloat = 0.3

    /// Text lighter than the ink threshold (a grey label, a faint scan) is
    /// read again with a pixel this dark (of 255) as its ink.
    static let inkFitLightThreshold: UInt8 = 232

    /// A pixel this dark (of 255, DeviceGray) is ink.
    static let inkFitThreshold: UInt8 = 128

    /// A row inked across this share of the window is a rule, an underline or
    /// a border, not a glyph: the fit neither follows it nor rides it.
    static let inkFitRuleShare = 0.9

    /// Past this share of inked pixels the window is a dark ground (a shaded
    /// cell, light text on dark, a photograph): no fit; the box stays as it is.
    static let inkFitDarkGroundShare = 0.35

    static let inkFitLogger = Logger(subsystem: "com.resecta.app", category: "search")

    /// `rect` (normalized, post-rotation, bottom-left) — the selection box of
    /// `text` — united with the ink of that text, on a page whose glyphs are
    /// inkless over a page-scale image; `rect` itself on any other page.
    /// The ink is found by the words Vision reads on the page (`inkTokens`):
    /// the token on the box's line that holds each word of `text`, the
    /// nearest when it repeats, cut to the word's share (a character wider each side) when the token is
    /// longer (a word inside "INDN:DELIA"). Its rows are then checked against
    /// the render (`inkBox`: a dot or a cap above the token box joins it). A
    /// word Vision did not read is fitted by the render alone, from the
    /// selection box.
    nonisolated static func inkFittedRect(
        _ rect: CGRect, page: PDFPage, text: String?, range: NSRange? = nil, paintOnly: Bool = false
    ) -> CGRect {
        inkFit(rect, page: page, text: text, range: range, paintOnly: paintOnly).rect
    }

    /// `inkFittedRect`, and whether the fit was degraded (no read or render in
    /// time, or no private copy to draw from): the box is then the drift
    /// envelope, and the caller reports the page as not fully analysed.
    nonisolated static func inkFit(
        _ rect: CGRect, page: PDFPage, text: String?, range: NSRange? = nil, paintOnly: Bool = false
    ) -> (rect: CGRect, degraded: Bool) {
        guard !rect.isEmpty, let cgPage = page.pageRef, carriesHiddenTextOverImage(page, cgPage: cgPage) else { return (rect, false) }
        let visual = effectiveBounds(page.bounds(for: .cropBox), rotation: page.rotation).size
        guard visual.width > 0, visual.height > 0 else { return (rect, false) }
        let pageKey = InkTokenCache.key(page: page, cgPage: cgPage, visual: visual)
        var job = InkFitJob(rect: rect, cgPage: cgPage, rotation: page.rotation, visual: visual, pageKey: pageKey,
                            pageText: page.string ?? "", text: text, range: range, paintOnly: paintOnly,
                            frame: readingFrame(of: page, visual: visual),
                            wideBefore: range != nil ? wideCharacters(before: range, in: page.string ?? "")
                                : wideCharacters(before: NSRange(location: 0, length: ((text ?? "") as NSString).length), in: text ?? ""),
                            fromLineStart: 0)
        if let known = InkFitCache.shared.fitted(for: job.key) { return (known, false) }
        // The main thread (the live preview) reads only what a search returned
        // off the main thread: its fit, or the degraded box it painted (so the
        // preview shows what will be applied). It renders, reads and copies
        // nothing, and asks again on `inkFitDidUpdate`.
        if Thread.isMainThread {
            if let shown = InkFitCache.shared.displayed(for: job.key) { return (shown, true) }
            return (rect, false)
        }
        let readingBox = job.frame.toReading(CGRect(x: rect.minX * visual.width, y: rect.minY * visual.height,
                                                    width: rect.width * visual.width, height: rect.height * visual.height))
        job.fromLineStart = distanceFromLineStart(of: range, box: readingBox, page: page, visual: visual, frame: job.frame)
        let frame = job.frame
        job.layerBox = { index in
            page.selection(for: NSRange(location: index, length: 1)).flatMap { DocumentSearcher().normalizedRect(for: $0, page: page) }
                .map { frame.toReading(CGRect(x: $0.minX * visual.width, y: $0.minY * visual.height,
                                              width: $0.width * visual.width, height: $0.height * visual.height)) }
        }
        // A search, on its own copy of the document: the queue draws from a
        // private copy of that copy, made here on the copy's own thread through
        // the guarded data path, so a job that outlives its wait never touches
        // the copy the search goes on reading.
        guard let document = page.document, case let index = document.index(for: page), index != NSNotFound,
              let privateCopy = PrivatePDFCopies.shared.copy(of: document),
              let privatePage = privateCopy.page(at: index + 1) else {
            inkFitLogger.log("ink fit: no private copy of the document to draw from; the box is the drift envelope")
            let wide = job.envelope()
            InkFitCache.shared.finish(job.key, fitted: nil, displayed: wide)
            InkFitUpdates.shared.post()
            return (wide, true)
        }
        let onCopy = job.with(privatePage)
        let fitted = onCopy.run()
        let degraded = onCopy.uncached.isRaised
        // A deferred run's envelope stands in until the page is read: not shown.
        let placeholder = InkFitDeferral.current != nil && degraded
        InkFitCache.shared.finish(job.key, fitted: degraded ? nil : fitted, displayed: degraded && !placeholder ? fitted : nil)
        if !placeholder { InkFitUpdates.shared.post() }
        return (fitted, degraded)
    }

    /// Where the ink of a match whose layer box is `box` (reading frame) can
    /// lie: the drift bound along its line, grown with its distance from the
    /// line's start and for the wide characters before it there, and one
    /// and a half line heights (at least `inkFitDriftAcross`) above and below.
    nonisolated static func driftBound(around box: CGRect, wideBefore: Int = 0, fromLineStart: CGFloat = 0) -> CGRect {
        box.insetBy(dx: -(inkFitDriftBound + inkFitDriftPerPoint * max(fromLineStart, 0)
                            + inkFitDriftPerWide * box.height * CGFloat(wideBefore)),
                    dy: -max(1.5 * box.height, inkFitDriftAcross))
    }

    /// Fits in the job's reading frame (`InkFitFrame`): the selection box,
    /// the read tokens, the renders and the fitted box are turned into it,
    /// and the fitted box turned back.
    nonisolated static func fit(_ job: InkFitJob) -> CGRect {
        let (rect, visual, cgPage, frame) = (job.rect, job.visual, job.cgPage, job.frame)
        let size = frame.size
        let box = frame.toReading(CGRect(x: rect.minX * visual.width, y: rect.minY * visual.height,
                                         width: rect.width * visual.width, height: rect.height * visual.height))
        // A read that did not finish in time: the conservative envelope, never
        // the selection box alone (that is the drifted box), and not cached.
        func envelope() -> CGRect {
            inkFitLogger.log("ink fit: no read or render in time; the box is the selection grown by the drift bound")
            return job.envelope()
        }
        // A cancelled search's remaining words: the envelope, with no render.
        if Task.isCancelled { return job.envelope() }
        // The read of the match's line (its script's, on a page of several).
        let lineRead = job.read
        if InkTokenCache.shared.value(for: lineRead.key) == nil {
            // A search's matching run before its page was read: the envelope
            // for now, and the read noted (`withInkFitRead`).
            if let deferral = InkFitDeferral.current { deferral.want(); return job.envelope() }
            // A task thread never waits on a page read (Vision finishes its
            // work on the task pool, which threads waiting on it can starve):
            // a page whose awaited read failed, timed out or never ran takes
            // the envelope at once. The next search awaits the read again.
            if withUnsafeCurrentTask(body: { $0 != nil }) {
                inkFitLogger.log("ink fit: the page was not read before its fit; the box is the drift envelope")
                return job.envelope()
            }
        }
        // Read in the reading frame: Vision sees the text upright, and its
        // boxes come back in this frame.
        guard let tokens = inkTokens(key: lineRead.key, cgPage: cgPage, rotation: job.rotation, visual: visual,
                                     languages: lineRead.languages, frame: frame) else {
            return envelope()
        }
        // A match on an interleaved layer line has no place of its own.
        if let band = interleavedBand(job, readKey: lineRead.key, tokens: tokens, box: box) { return band }
        // The read word's own box when the alignment places it: the painted box
        // is then the word's ink alone. It may grow past a side where Vision's
        // box ends (a letter the box clipped), never into the rest of a longer
        // token it was cut from.
        var anchor: (rect: CGRect, growLeft: Bool, growRight: Bool, whole: CGRect?, cuts: [InkCut])?
        var model: InkLineModel?
        if let range = job.range { anchor = alignedBox(range: range, pageText: job.pageText as NSString, near: box, tokens: tokens, model: &model) }
        let aligned = anchor != nil
        if anchor == nil, let text = job.text { anchor = tokenBox(for: text, near: box, tokens: tokens) }
        // No read word placed: where the word's ink lies is not known, so the
        // box is the envelope (a fit from the drifted box alone can land on
        // the next word's ink).
        guard let placed = anchor else {
            inkFitLogger.log("ink fit: no read word matched a text-layer box; the box is the drift envelope")
            return job.envelope()
        }
        // A read word where its line's drift does not put it is a wrong one
        // (another word, another row): the envelope, never a fit there. An
        // aligned word is held to its line's own drift, read from the line's
        // first and last agreeing letters (a near-linear drift along the
        // line); a word placed without its line, to the fixed bound.
        // The line's own drift: from the agreeing letters on the match's
        // band in the layer (a layer line can hold a cell's wrapped lines,
        // read as rows of their own), the first and the last.
        func onBand(_ index: Int) -> CGRect? {
            job.layerBox(index).flatMap { abs($0.midY - box.midY) <= 0.5 * box.height ? $0 : nil }
        }
        var ends: (first: (CGRect, CGFloat), last: (CGRect, CGFloat))?
        if aligned, let model {
            let probe = model.letters
            let head = probe.prefix(24).lazy.compactMap { l in onBand(l.text).map { ($0, l.read) } }.first
            let tail = probe.reversed().prefix(24).lazy.compactMap { l in onBand(l.text).map { ($0, l.read) } }.first
            if let head, let tail, tail.0.midX - head.0.midX > 1 { ends = (head, tail) }
        }
        // Where the line's drift puts the word, and how far a true word was
        // measured to sit from that (the residual): one cell (the layer
        // word's width over its characters, for the fixed-pitch grid's
        // saw-tooth) and a constant on top, sized on the measured inputs.
        var prediction: (center: CGFloat, residual: CGFloat, scale: CGFloat)?
        if let (first, last) = ends, case let scale = (last.1 - first.1) / (last.0.midX - first.0.midX),
           inkFitScaleRange.contains(scale) {
            let cell = box.width / CGFloat(max(job.range?.length ?? job.text.map { ($0 as NSString).length } ?? 1, 1))
            prediction = (first.1 + (box.midX - first.0.midX) * scale,
                          max(0.75 * box.height, 5) + 0.5 * box.width + cell + inkFitResidualSlack, scale)
        }
        // The envelope for a word whose line has a drift model: around the
        // predicted place, the residual and half the word (at the line's
        // scale) along the line, the drift bound across it, and never wider
        // than the drift envelope. A line without one: the drift envelope.
        // A placed read word whose ink the render did not verify: its box,
        // grown to its printed line's band (the read words beside it at its
        // height: ascenders and descenders), with a margin, degraded.
        func anchorEnvelope() -> CGRect {
            let wide = job.envelope()
            guard let a = anchor else { return wide }
            let row = tokens.filter { t in
                let overlap = min(t.rect.maxY, a.rect.maxY) - max(t.rect.minY, a.rect.minY)
                return overlap >= 0.5 * min(t.rect.height, a.rect.height) && abs(t.rect.midX - a.rect.midX) <= 200
            }
            let low = row.map(\.rect.minY).min() ?? a.rect.minY, high = row.map(\.rect.maxY).max() ?? a.rect.maxY
            // At least an ascender's or a descender's reach past the read
            // box (Vision's box can stop at the x-height's neighbours).
            let reach = inkFitAnchorReach * a.rect.height
            var bottom = max(min(low, a.rect.minY - reach), a.rect.minY - a.rect.height)
            var top = min(max(high, a.rect.maxY + reach), a.rect.maxY + a.rect.height)
            // Never into the printed rows above and below (a column of
            // figures sits a line apart): the reach stops at their read
            // boxes' edges, and the word's own ascenders and descenders, in
            // the gap between, stay inside.
            let column = tokens.filter { $0.rect.maxX > a.rect.minX - a.rect.width && $0.rect.minX < a.rect.maxX + a.rect.width }
            if let above = column.filter({ $0.rect.midY > a.rect.maxY }).map(\.rect.minY).min() {
                top = min(top, max(a.rect.maxY, above))
            }
            if let below = column.filter({ $0.rect.midY < a.rect.minY }).map(\.rect.maxY).max() {
                bottom = max(bottom, min(a.rect.minY, below))
            }
            // A side cut from a longer token takes half a margin: past its
            // verified glyph runs, or past a share cut, which already reaches
            // a character beyond its share (`alignedBox`, `tokenBox`).
            // An open side's margin; a CJK word's read box is placed less
            // closely across a character, so half a character there.
            let characters = max(job.text.map { ($0 as NSString).length } ?? job.range?.length ?? 1, 1)
            let cjk = job.text.map { wideCharacters(before: NSRange(location: 0, length: ($0 as NSString).length), in: $0) > 0 } ?? false
            let open = cjk ? max(inkFitAnchorMargin, 0.5 * a.rect.width / CGFloat(characters)) : inkFitAnchorMargin
            let left: CGFloat = a.growLeft ? open : inkFitMargin / 2
            let right: CGFloat = a.growRight ? open : inkFitMargin / 2
            let grown = CGRect(x: a.rect.minX - left, y: bottom - inkFitMargin / 2,
                               width: a.rect.width + left + right, height: top - bottom + inkFitMargin)
                .intersection(CGRect(origin: .zero, size: size))
            guard !grown.isNull, !grown.isEmpty else { return wide }
            let back = frame.toVisual(grown)
            return CGRect(x: back.minX / visual.width, y: back.minY / visual.height,
                          width: back.width / visual.width, height: back.height / visual.height).clampedToNormalized()
        }
        func lineEnvelope() -> CGRect {
            let wide = job.envelope()
            guard let p = prediction else { return wide }
            let half = 0.5 * box.width * max(p.scale, 1) + inkFitMargin
            let across = box.insetBy(dx: 0, dy: -max(1.5 * box.height, inkFitDriftAcross))
            let around = CGRect(x: p.center - p.residual - half, y: across.minY,
                                width: 2 * (p.residual + half), height: across.height)
                .intersection(CGRect(origin: .zero, size: size))
            guard !around.isNull, !around.isEmpty else { return wide }
            let back = frame.toVisual(around)
            let normalized = CGRect(x: back.minX / visual.width, y: back.minY / visual.height,
                                    width: back.width / visual.width, height: back.height / visual.height)
            let held = normalized.intersection(wide)
            return held.isNull || held.isEmpty ? wide : held.clampedToNormalized()
        }
        // The same occurrence of its text in the layer and in the read row,
        // or not this word (a repeated word read in another place). The
        // layer's occurrences count on the match's own printed row: a layer
        // line can hold a cell's wrapped lines, which Vision reads as rows of
        // their own.
        func sameOrdinal(_ model: InkLineModel) -> Bool {
            let onRow = model.layerOccurrences.filter { $0 == model.matchText || onBand($0) != nil }
            return onRow.count == model.readTotal && onRow.filter { $0 < model.matchText }.count == model.readBefore
        }
        if aligned, let model, !sameOrdinal(model) {
            inkFitLogger.log("ink fit: the read word placed is another occurrence of its text; the box is the envelope"); return lineEnvelope()
        }
        if let p = prediction {
            guard abs(placed.rect.midX - p.center) <= p.residual,
                  abs(placed.rect.midY - box.midY) <= max(1.5 * box.height, inkFitDriftAcross) else {
                // The line's model and the read word disagree: neither places
                // the word, so the box is the drift envelope.
                inkFitLogger.log("ink fit: the read word placed is off its line's drift; the box is the drift envelope"); return job.envelope()
            }
        } else {
            let fixed = driftBound(around: box, wideBefore: job.wideBefore).insetBy(dx: -inkFitMargin, dy: -inkFitMargin)
            guard fixed.contains(placed.rect) else {
                inkFitLogger.log("ink fit: the read word placed lies outside the drift bound; the box is the drift envelope")
                return job.envelope()
            }
        }
        // A cut from a longer token by the token's own glyphs: its ink split
        // into columns at blank columns, one run per character as read; the
        // cut is the runs of its characters. The character-share cut stays
        // when the runs do not count the characters (touching glyphs).
        if let a = anchor, !a.cuts.isEmpty {
            var glyphCuts: CGRect? = nil
            var exact = true
            var runs: [(cut: InkCut, columns: [ClosedRange<CGFloat>])] = []
            for cut in a.cuts {
                guard let columns = glyphColumns(of: cut.token, cgPage: cgPage, rotation: job.rotation, visual: visual,
                                                 key: job.pageKey, frame: frame)
                else { exact = false; continue }
                runs.append((cut, columns))
                guard glyphRunsMatch(cut.token.raw, columns), cut.rawLo <= cut.rawHi, cut.rawHi < columns.count
                else { exact = false; continue }
                // A cut side takes half the blank gap to the next glyph, at
                // most half the margin: a render a pixel off from this one
                // still holds the glyph's edge, and the next glyph stays out.
                let half = inkFitMargin / 2
                let left = columns[cut.rawLo].lowerBound
                    - (cut.rawLo > 0 ? min(half, (columns[cut.rawLo].lowerBound - columns[cut.rawLo - 1].upperBound) / 2) : 0)
                let right = columns[cut.rawHi].upperBound
                    + (cut.rawHi + 1 < columns.count ? min(half, (columns[cut.rawHi + 1].lowerBound - columns[cut.rawHi].upperBound) / 2) : 0)
                let rect = CGRect(x: left, y: cut.token.rect.minY, width: right - left, height: cut.token.rect.height)
                glyphCuts = glyphCuts.map { $0.union(rect) } ?? rect
            }
            if exact, let glyphCuts {
                anchor = (a.whole.map { $0.union(glyphCuts) } ?? glyphCuts, a.growLeft, a.growRight, a.whole, a.cuts)
            } else {
                inkFitLogger.log("ink fit: a cut token's glyphs did not resolve into columns; cut by character share")
                // A share cut's side inside the token can end inside its last
                // glyph's ink: the side walks out to the end of that ink run
                // (the blank column before the next glyph), at most half a
                // character, so it never takes the next glyph.
                var rect = a.rect
                for (cut, columns) in runs {
                    let half = cut.token.rect.width / CGFloat(max(cut.token.raw.count, 1)) / 2
                    if cut.rawHi < cut.token.raw.count - 1, cut.token.rect.minX < rect.maxX, rect.maxX < cut.token.rect.maxX,
                       let run = columns.first(where: { $0.lowerBound < rect.maxX && rect.maxX < $0.upperBound }) {
                        rect.size.width += min(run.upperBound, rect.maxX + half) - rect.maxX
                    }
                    if cut.rawLo > 0, cut.token.rect.minX < rect.minX, rect.minX < cut.token.rect.maxX,
                       let run = columns.first(where: { $0.lowerBound < rect.minX && rect.minX < $0.upperBound }) {
                        let left = max(run.lowerBound, rect.minX - half)
                        rect = CGRect(x: left, y: rect.minY, width: rect.maxX - left, height: rect.height)
                    }
                }
                anchor = (rect, a.growLeft, a.growRight, a.whole, a.cuts)
            }
        }
        let seed = anchor?.rect ?? box
        let height = max(seed.height, box.height)
        let vPad = max(height, 4), hPad = max(0.75 * height, 3)
        let window = seed.insetBy(dx: -hPad, dy: -vPad).intersection(CGRect(origin: .zero, size: size))
        var fitted = anchor?.rect ?? box
        let page = InkFitPage(cgPage)
        var stalled = false
        #if DEBUG
        // A stalled render (the test seam) only stalls, on a queue of its own.
        if let injected = inkFitInjectedRenderStalls.value(for: job.pageKey) {
            _ = onInkFitQueue(key: job.pageKey, timeout: injected.timeout,
                              queue: DispatchQueue(label: "com.resecta.search.inkfit.stalled-render")) {
                Thread.sleep(forTimeInterval: injected.stall)
            }
            stalled = true
        }
        #endif
        let rendered: GrayBitmap?? = stalled ? nil : window.isNull || window.width <= 0 || window.height <= 0 ? .some(nil)
            : drawn(page, key: job.pageKey) {
                // A failed render is tried once more before it counts.
                renderGray(page.page, rotation: job.rotation, visual: visual, window: window, frame: frame)
                    ?? renderGray(page.page, rotation: job.rotation, visual: visual, window: window, frame: frame)
            }
        // No render (in time, or at all): the envelope, even with a read word
        // to stand on. Vision's word box alone can leave a glyph's top or foot
        // outside; only the render's ink rows close it.
        guard let finished = rendered, let bitmap = finished else {
            inkFitLogger.log("ink fit: no render in time; the box is the read word's box, degraded"); return anchorEnvelope()
        }
        // The ink rows: at the ink threshold; text lighter than it (grey
        // labels, a faint scan) read again at `inkFitLightThreshold`; light
        // text on a dark ground read as light ink.
        func read(_ map: GrayBitmap) -> (box: CGRect?, outcome: InkFitOutcome) {
            inkBox(in: map, box: seed, window: window,
                   growLeft: anchor?.growLeft ?? true, growRight: anchor?.growRight ?? true)
        }
        var reading = read(bitmap)
        if reading.box == nil, reading.outcome == .darkGround {
            reading = read(bitmap.reading(threshold: inkFitThreshold, light: true))
        } else if reading.box == nil {
            let light = read(bitmap.reading(threshold: inkFitLightThreshold))
            if light.box != nil { reading = light }
        }
        // No ink rows read for the word (text lighter than the ink
        // threshold, light text on a dark ground, or no inked line on the
        // box): nothing verifies a box against its glyphs, and Vision's box
        // alone can leave a glyph's top or foot outside. The envelope.
        guard let ink = reading.box else {
            switch reading.outcome {
            case .darkGround: inkFitLogger.log("ink fit: dark ground around a text-layer box; the box is the read word's box, degraded"); return anchorEnvelope()
            case .otherLine: inkFitLogger.log("ink fit: no inked line overlaps half the box; the box is the read word's box, degraded"); return anchorEnvelope()
            default: inkFitLogger.log("ink fit: no ink read on the box; the box is the read word's box, degraded"); return anchorEnvelope()
            }
        }
        if reading.outcome == .capped { inkFitLogger.log("ink fit reached its window: the box grew to the cap") }
        // The height is the ink's own rows: Vision's box can reach past its
        // line's ink into the leading, toward the next line.
        let minX = min(fitted.minX, ink.minX), maxX = max(fitted.maxX, ink.maxX)
        fitted = CGRect(x: minX, y: ink.minY, width: maxX - minX, height: ink.height)
        // A margin past the ink on every side the box may grow (a render's
        // half-inked edge, a round letter's overshoot): never on a side cut
        // from a longer token, which would paint its next letter.
        let side = inkFitMargin, cap = inkFitMargin / 2
        fitted = CGRect(x: fitted.minX - ((anchor?.growLeft ?? true) ? side : 0), y: fitted.minY - cap,
                        width: fitted.width + ((anchor?.growLeft ?? true) ? side : 0) + ((anchor?.growRight ?? true) ? side : 0),
                        height: fitted.height + 2 * cap)
        // The selection box too, unless the caller strips the hidden glyphs by
        // their own rect (`textLayerAndInkRects`): a fill that covers them is
        // then the only thing that removes them from a Searchable export.
        // The fit past its read word's window (a render that grew onto
        // another word): the envelope.
        guard window.insetBy(dx: -inkFitMargin, dy: -inkFitMargin).contains(fitted) else {
            inkFitLogger.log("ink fit: the fitted box reaches past its window; the box is the read word's box, degraded"); return anchorEnvelope()
        }
        if !job.paintOnly { fitted = fitted.union(box) }
        let back = frame.toVisual(fitted)
        return CGRect(x: back.minX / visual.width, y: back.minY / visual.height,
                      width: back.width / visual.width, height: back.height / visual.height)
            .clampedToNormalized()
    }

    /// The page's read tokens: one full-page render at the fit's scale, read
    /// once per page content (`InkTokenCache`, keyed by the page's text, its
    /// image and box, so a search on a fresh copy of the document reads the
    /// cache and two pages that share a text never share tokens).
    /// In `frame` (the page's reading frame, upright when nil); the frame
    /// follows from the page's layer, which its key carries.
    nonisolated static func inkTokens(key: Int, cgPage: CGPDFPage, rotation: Int, visual: CGSize,
                                      languages: [String]? = nil, frame: InkFitFrame? = nil) -> [InkToken]? {
        if let known = InkTokenCache.shared.value(for: key) { return known }
        guard let tokens = readTokens(cgPage, rotation: rotation, visual: visual, key: key, languages: languages,
                                      frame: frame) else { return nil }
        InkTokenCache.shared.set(tokens, for: key)
        return tokens
    }

    /// How long a page read may run once at the Vision lane's head (and a
    /// read's draw waits for its copy) before the read is given up and its
    /// fits fall back to the box without the fit (`inkFitReadBackstop`).
    static let inkFitTimeout: TimeInterval = 30

    #if DEBUG
    /// Test seam: per page content key, a stall in place of its read and a
    /// shorter wait for it. The stalled job runs on a queue of its own and
    /// does no work after its stall (no second reader beside the lane), so
    /// other pages, and other tests, are untouched.
    static let inkFitInjectedStalls = InkFitStalls()
    /// Test seam: the same for the fit's renders on a page (and a token's glyph runs), after its read.
    static let inkFitInjectedRenderStalls = InkFitStalls()
    /// Test seam: a stall in place of every job for a page on the Vision
    /// lane, and that job's limit there.
    static let inkFitInjectedLaneStalls = InkFitStalls()
    #endif

    /// `work` on an ink-fit Vision lane (`InkFitQueueState`); nil on a timeout, a
    /// stuck page or a cancelled task. The wait times the job at the head of
    /// the lane against its own limit (`timeout`, else `inkFitTimeout`), not
    /// the time spent behind other jobs. A head job past its limit retires its
    /// lane and marks its page `key` stuck: a caller whose job is that one
    /// gets nil, the others move to the fresh lane. A caller waits at most
    /// `inkFitWaitCeiling` on lanes that move. On a queue of the caller's own
    /// (`queue`) it waits at most `timeout`. Never called from a task thread
    /// (`fit`): the caller is a dispatch thread (`InkFitPendingRead.run`).
    nonisolated static func onInkFitQueue<T>(key: Int? = nil, timeout: TimeInterval? = nil,
                                             queue: DispatchQueue? = nil, state: InkFitQueueState = .vision,
                                             _ work: @escaping () -> T) -> T? {
        if DispatchQueue.getSpecific(key: InkFitLane.tag) == true { return work() }
        if Task.isCancelled { return nil }
        let box = InkFitResult<T>()
        if let queue {
            queue.async { box.value = work(); box.done.signal() }
            guard box.done.wait(timeout: .now() + (timeout ?? inkFitTimeout)) == .success else {
                inkFitLogger.log("ink fit: a page read or render did not finish in time; the box is the drift envelope")
                return nil
            }
            return box.value
        }
        if state.isStuck(key: key) { return nil }
        var limit = timeout ?? inkFitTimeout, stall: TimeInterval = 0
        #if DEBUG
        if state === InkFitQueueState.vision, let key, let injected = inkFitInjectedLaneStalls.value(for: key) { (stall, limit) = injected }
        #endif
        let runLimit = limit, runStall = stall
        func enqueue(on lane: InkFitLane) {
            lane.queue.async {
                guard box.claim() else { return }
                lane.began(key: key, limit: runLimit)
                // A stalled job (the test seam) only stalls: it adds no reader beside the lane.
                if runStall > 0 { Thread.sleep(forTimeInterval: runStall) } else { box.value = work() }
                lane.ended()
                state.ended(on: lane)
                box.done.signal()
            }
        }
        let queued = Date()
        var lane = state.current
        enqueue(on: lane)
        while box.done.wait(timeout: .now() + 0.25) != .success {
            if let hung = lane.overrun() {
                state.retire(lane, key: hung.key)
                if box.isRunning {
                    inkFitLogger.log("ink fit: a page read or render ran past its timeout; the box is the drift envelope")
                    return nil
                }
                // A job for the hung job's page does not move: it would only
                // hang beside it.
                if state.isStuck(key: key) {
                    box.abandon()
                    if box.isRunning { continue }
                    inkFitLogger.log("ink fit: a job behind a hung one shares its page; the box is the drift envelope")
                    return nil
                }
                lane = state.current
                enqueue(on: lane)
                continue
            }
            if Task.isCancelled || Date().timeIntervalSince(queued) > inkFitWaitCeiling {
                box.abandon()
                if box.isRunning { continue }
                inkFitLogger.log("ink fit: the ink-fit lane did not reach this job in time; the box is the drift envelope")
                return nil
            }
        }
        return box.value
    }

    /// The longest a caller waits behind other jobs on a queue that is still moving.
    static let inkFitWaitCeiling: TimeInterval = 90

    nonisolated static func readTokens(_ cgPage: CGPDFPage, rotation: Int, visual: CGSize, key: Int? = nil,
                                       languages: [String]? = nil, frame: InkFitFrame? = nil) -> [InkToken]? {
        let size = frame?.size ?? visual
        let page = InkFitPage(cgPage)
        var stall: TimeInterval = 0, timeout: TimeInterval? = nil, queue: DispatchQueue? = nil
        #if DEBUG
        if let key, let injected = inkFitInjectedStalls.value(for: key) {
            (stall, timeout) = injected
            queue = DispatchQueue(label: "com.resecta.search.inkfit.stalled")
        }
        #endif
        // A stalled job only stalls: a seam must not add a reader beside the lanes.
        if stall > 0 {
            _ = onInkFitQueue(key: key, timeout: timeout, queue: queue) { Thread.sleep(forTimeInterval: stall) }
            return nil
        }
        // The page drawn on this thread (under its copy's draw lock), then
        // read on the Vision lane. A failed render or read is tried once more
        // before it counts; one that timed out, or failed both times, is no
        // read (the caller falls back to the envelope, and nothing is cached).
        for attempt in 1...2 {
            // Nil: no draw slot or lock in time (no read); nil inside: no render.
            let image: InkFitImage?? = InkFitReadThreads.shared.drawing {
                drawn(page, key: key, wait: inkFitTimeout) {
                    renderGrayImage(page.page, rotation: rotation, visual: visual, frame: frame).map(InkFitImage.init)
                }
            } ?? nil
            guard let image else { return nil }
            guard let image else {
                inkFitLogger.log("ink fit: the page did not render for its read (attempt \(attempt))")
                continue
            }
            let read: [OCREngine.Token]?? = onInkFitQueue(key: key) {
                do { return try OCREngine.recognizeTokens(in: image.image, languages: languages) } catch {
                    inkFitLogger.log("ink fit: the page read failed (attempt \(attempt)): \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            guard let finished = read else { return nil }
            if let tokens = finished { return inkTokens(from: tokens, size: size) }
        }
        return nil
    }

    /// The whole page as a DeviceGray image at the fit's scale, under the OCR
    /// leg's pixel ceiling.
    /// The whole page at the fit's scale, turned into `frame` when given.
    nonisolated static func renderGrayImage(_ cgPage: CGPDFPage, rotation: Int, visual: CGSize,
                                            frame: InkFitFrame? = nil) -> CGImage? {
        let size = frame?.size ?? visual
        let width = Int((size.width * inkFitScale).rounded(.up)), height = Int((size.height * inkFitScale).rounded(.up))
        guard width > 0, height > 0, width <= 10_000, height <= 10_000, CGFloat(width * height) <= 36_000_000,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: inkFitScale, y: inkFitScale)
        if let frame, frame.turn != .upright { ctx.concatenate(frame.transform) }
        ctx.concatenate(PageRasterizer.drawingTransform(
            for: cgPage, box: .cropBox, rotation: rotation, targetRect: CGRect(origin: .zero, size: visual)))
        ctx.clip(to: cgPage.getBoxRect(.cropBox))
        ctx.drawPDFPage(cgPage)
        return ctx.makeImage()
    }
}
