import CoreGraphics
import Foundation

/// Where an imported document's active content sits. Reported on the
/// import refusal and carries no document content — key names and page
/// indices only.
public enum ActiveContentLocation: Sendable, Equatable {
    /// A `/JavaScript`, `/JS` or `/Launch` entry at the top level of the
    /// document catalog (the original guard).
    case catalogKey(String)
    /// The catalog's `/Names → /JavaScript` name tree — the ISO 32000
    /// carrier of document-level JavaScript.
    case namesJavaScript
    /// The catalog's `/OpenAction` is (or chains to) a JavaScript or launch
    /// action.
    case openAction
    /// A page's `/AA` (additional-actions) dictionary carries a JavaScript or
    /// launch action on one of its triggers.
    case pageAdditionalAction(pageIndex: Int)
    /// An annotation on the page carries a `/A` action that is (or chains
    /// to) a JavaScript or launch action.
    case annotationAction(pageIndex: Int)
}

/// The import-time active-content walk. Runs once at import over the raw
/// bytes' `CGPDFDocument` (the same moment `TextLayerExtractor
/// .documentHasHiddenOCG` runs) and reports the first location at which the
/// document carries JavaScript or a launch action. The app refuses the
/// import on a non-nil result; the verification pass's structural check
/// re-inspects the OUTPUT independently.
///
/// Scope, deliberately: the four ISO-canonical carriers of document
/// JavaScript plus the catalog-top keys. Form-field additional actions on
/// widget annotations (`/AA` on a widget — format and keystroke scripts on
/// text fields) are NOT walked: they are common in ordinary forms, the
/// export raster is built from the page content stream without them, and
/// the verification pass reports them on the output if they survive.
public enum ActiveContentScan {

    /// Catalog-top keys the original guard refused; kept as the first step.
    static let catalogKeys = ["JavaScript", "JS", "Launch"]

    /// Action subtypes treated as active content.
    static let activeActionSubtypes: Set<String> = ["JavaScript", "Launch"]

    /// Bound on the `/Next` chain walk so a cyclic or absurdly long action
    /// chain cannot stall the import.
    static let maxActionChainDepth = 8

    /// The first location of active content, or nil when the walk sees
    /// none. Order: catalog-top keys → `/Names → /JavaScript` →
    /// `/OpenAction` → per page: `/AA`, then each annotation's `/A`.
    public static func firstLocation(in document: CGPDFDocument) -> ActiveContentLocation? {
        guard let catalog = document.catalog else { return nil }

        for key in catalogKeys {
            var object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog, key, &object) {
                return .catalogKey(key)
            }
        }

        var names: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names {
            var javaScript: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(names, "JavaScript", &javaScript) {
                return .namesJavaScript
            }
        }

        var openAction: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(catalog, "OpenAction", &openAction),
           let openAction, actionChainIsActive(openAction) {
            return .openAction
        }

        let pageCount = document.numberOfPages
        guard pageCount > 0 else { return nil }
        for number in 1...pageCount {
            guard let page = document.page(at: number)?.dictionary else { continue }
            let pageIndex = number - 1

            var additionalActions: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(page, "AA", &additionalActions),
               let additionalActions, additionalActionsAreActive(additionalActions) {
                return .pageAdditionalAction(pageIndex: pageIndex)
            }

            var annotations: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations {
                for slot in 0..<CGPDFArrayGetCount(annotations) {
                    var annotation: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(annotations, slot, &annotation),
                          let annotation else { continue }
                    var action: CGPDFObjectRef?
                    if CGPDFDictionaryGetObject(annotation, "A", &action),
                       let action, actionChainIsActive(action) {
                        return .annotationAction(pageIndex: pageIndex)
                    }
                }
            }
        }
        return nil
    }

    /// True when the action dictionary's `/S` is JavaScript or Launch, or
    /// when any action in its `/Next` chain (a dictionary or an array of
    /// them) is, to `maxActionChainDepth`. A non-dictionary object — an
    /// `/OpenAction` destination array, say — is not an action.
    static func actionChainIsActive(_ object: CGPDFObjectRef, depth: Int = 0) -> Bool {
        guard depth < maxActionChainDepth else { return false }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary),
              let dictionary else { return false }

        var subtype: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "S", &subtype), let subtype,
           activeActionSubtypes.contains(String(cString: subtype)) {
            return true
        }

        var next: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, "Next", &next), let next else { return false }
        var chain: CGPDFArrayRef?
        if CGPDFObjectGetValue(next, .array, &chain), let chain {
            for slot in 0..<CGPDFArrayGetCount(chain) {
                var item: CGPDFObjectRef?
                if CGPDFArrayGetObject(chain, slot, &item), let item,
                   actionChainIsActive(item, depth: depth + 1) {
                    return true
                }
            }
            return false
        }
        return actionChainIsActive(next, depth: depth + 1)
    }

    /// Every value in an additional-actions dictionary is an action keyed by
    /// its trigger (`/O` open, `/C` close, and so on); any active one counts.
    static func additionalActionsAreActive(_ additionalActions: CGPDFDictionaryRef) -> Bool {
        var active = false
        CGPDFDictionaryApplyBlock(additionalActions, { _, value, _ in
            if actionChainIsActive(value) {
                active = true
                return false
            }
            return true
        }, nil)
        return active
    }
}
