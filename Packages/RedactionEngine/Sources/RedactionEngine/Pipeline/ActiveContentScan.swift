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
    /// The catalog's `/AA` (document-level additional actions) carries a
    /// JavaScript or launch action on one of its triggers.
    case catalogAdditionalAction
    /// A non-widget annotation on the page carries an `/AA` dictionary with
    /// a JavaScript or launch action on one of its triggers.
    case annotationAdditionalAction(pageIndex: Int)
    /// A form field dictionary that is not itself a widget carries an `/AA`
    /// dictionary with a JavaScript or launch action on one of its triggers.
    case fieldAdditionalAction
    /// The walk could not read the structure it inspects — no catalog, a
    /// page with no dictionary, an action chain or a field tree past its
    /// depth bound — so the document is not known to be clean. The app
    /// refuses it as a file it cannot read, never as active content.
    case couldNotScan
}

/// The import-time active-content walk. Runs once at import over the raw
/// bytes' `CGPDFDocument` (the same moment `TextLayerExtractor
/// .documentHasHiddenOCG` runs) and reports the first location at which the
/// document carries JavaScript or a launch action. The app refuses the
/// import on a non-nil result; the verification pass's structural check
/// re-inspects the OUTPUT independently.
///
/// Scope: the catalog-top keys, the four ISO-canonical carriers of document
/// JavaScript, the catalog's own additional actions, additional actions on
/// non-widget annotations, additional actions on form-field dictionaries
/// that are not themselves widgets, and a rendition action's `/JS` entry
/// anywhere an action is read. Additional actions on widget annotations
/// (`/AA` on a widget — format and keystroke scripts on text fields,
/// including a merged field-widget dictionary) are NOT walked: they are
/// common in ordinary forms, the export raster is built from the page
/// content stream without them, and the verification pass reports them on
/// the output if they survive.
public enum ActiveContentScan {

    /// Catalog-top keys the original guard refused; kept as the first step.
    static let catalogKeys = ["JavaScript", "JS", "Launch"]

    /// Action subtypes treated as active content.
    static let activeActionSubtypes: Set<String> = ["JavaScript", "Launch"]

    /// Bound on the `/Next` chain walk so a cyclic or absurdly long action
    /// chain cannot stall the import.
    static let maxActionChainDepth = 8

    /// Bound on the `/Kids` nesting walked in the `/AcroForm /Fields` tree.
    static let maxFieldTreeDepth = 8

    /// The first location of active content; nil when the walk sees none;
    /// `.couldNotScan` when the walk could not read the catalog, a page's
    /// dictionary, an action chain or the field tree to its depth bound — a
    /// document that is not known to be clean. Order: catalog-top keys →
    /// `/Names → /JavaScript` → `/OpenAction` → the catalog's `/AA` → per
    /// page: `/AA`, then each annotation's `/A` and, off a widget, its `/AA`
    /// → the `/AcroForm /Fields` tree.
    public static func firstLocation(in document: CGPDFDocument) -> ActiveContentLocation? {
        guard let catalog = document.catalog else { return .couldNotScan }

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
        if CGPDFDictionaryGetObject(catalog, "OpenAction", &openAction), let openAction {
            switch actionChainIsActive(openAction) {
            case true: return .openAction
            case nil: return .couldNotScan
            case false: break
            }
        }

        var catalogActions: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "AA", &catalogActions), let catalogActions {
            switch additionalActionsAreActive(catalogActions) {
            case true: return .catalogAdditionalAction
            case nil: return .couldNotScan
            case false: break
            }
        }

        let pageCount = document.numberOfPages
        guard pageCount > 0 else { return nil }
        for number in 1...pageCount {
            guard let page = document.page(at: number)?.dictionary else { return .couldNotScan }
            let pageIndex = number - 1

            var additionalActions: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(page, "AA", &additionalActions), let additionalActions {
                switch additionalActionsAreActive(additionalActions) {
                case true: return .pageAdditionalAction(pageIndex: pageIndex)
                case nil: return .couldNotScan
                case false: break
                }
            }

            var annotations: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations {
                for slot in 0..<CGPDFArrayGetCount(annotations) {
                    var annotation: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(annotations, slot, &annotation),
                          let annotation else { continue }
                    var action: CGPDFObjectRef?
                    if CGPDFDictionaryGetObject(annotation, "A", &action), let action {
                        switch actionChainIsActive(action) {
                        case true: return .annotationAction(pageIndex: pageIndex)
                        case nil: return .couldNotScan
                        case false: break
                        }
                    }
                    var annotationActions: CGPDFDictionaryRef?
                    if !isWidget(annotation),
                       CGPDFDictionaryGetDictionary(annotation, "AA", &annotationActions),
                       let annotationActions {
                        switch additionalActionsAreActive(annotationActions) {
                        case true: return .annotationAdditionalAction(pageIndex: pageIndex)
                        case nil: return .couldNotScan
                        case false: break
                        }
                    }
                }
            }
        }

        var acroForm: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm {
            var fields: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(acroForm, "Fields", &fields), let fields {
                var visited: Set<CGPDFDictionaryRef> = []
                switch fieldTreeIsActive(fields, depth: 0, visited: &visited) {
                case true: return .fieldAdditionalAction
                case nil: return .couldNotScan
                case false: break
                }
            }
        }
        return nil
    }

    /// Whether a dictionary names itself a widget annotation.
    static func isWidget(_ dictionary: CGPDFDictionaryRef) -> Bool {
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else {
            return false
        }
        return String(cString: subtype) == "Widget"
    }

    /// True when a field dictionary in the tree that is not itself a widget
    /// carries an active `/AA`; nil when a `/Kids` nesting runs past
    /// `maxFieldTreeDepth` or an `/AA` chain could not be read to its end.
    /// `visited` keeps a field that lists itself from being walked twice.
    static func fieldTreeIsActive(
        _ fields: CGPDFArrayRef, depth: Int, visited: inout Set<CGPDFDictionaryRef>
    ) -> Bool? {
        guard depth < maxFieldTreeDepth else { return nil }
        for slot in 0..<CGPDFArrayGetCount(fields) {
            var field: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(fields, slot, &field), let field else { continue }
            guard visited.insert(field).inserted else { continue }
            var fieldActions: CGPDFDictionaryRef?
            if !isWidget(field),
               CGPDFDictionaryGetDictionary(field, "AA", &fieldActions), let fieldActions {
                switch additionalActionsAreActive(fieldActions) {
                case true: return true
                case nil: return nil
                case false: break
                }
            }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(field, "Kids", &kids), let kids {
                switch fieldTreeIsActive(kids, depth: depth + 1, visited: &visited) {
                case true: return true
                case nil: return nil
                case false: break
                }
            }
        }
        return false
    }

    /// True when the action, or any action its `/Next` chain reaches (a
    /// dictionary or an array of them), is active (`isActiveAction`); nil
    /// when the chain runs past `maxActionChainDepth` or loops back on
    /// itself, so the walk could not read it to the end. A non-dictionary
    /// object (an `/OpenAction` destination array, say) is not an action.
    /// The chain is read once per action (`readActionGraph`) and then
    /// walked (`actionGraphIsActive`).
    static func actionChainIsActive(_ object: CGPDFObjectRef) -> Bool? {
        actionGraphIsActive(readActionGraph(from: object))
    }

    /// Whether the action dictionary's `/S` is JavaScript or Launch, or it is
    /// a Rendition action carrying a `/JS` entry.
    static func isActiveAction(_ dictionary: CGPDFDictionaryRef) -> Bool {
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "S", &subtype), let subtype else { return false }
        let name = String(cString: subtype)
        if activeActionSubtypes.contains(name) { return true }
        var script: CGPDFObjectRef?
        return name == "Rendition" && CGPDFDictionaryGetObject(dictionary, "JS", &script)
    }

    /// An action chain as values: node 0 is the starting object, and each
    /// node lists the nodes its `/Next` names, in order. An action
    /// dictionary named more than once is one node.
    struct ActionGraph: Equatable, Sendable {
        struct Node: Equatable, Sendable {
            var isActive: Bool
            var next: [Int]
        }
        var nodes: [Node]
    }

    /// Reads the actions reachable from `object` through `/Next`, nearest
    /// first, each action dictionary once. An action reached only at
    /// `maxDepth` hops or more is not opened (the walk answers nil there
    /// before reading it), and an active action's own `/Next` is not read
    /// (the walk stops at it). A non-dictionary object is a node with no
    /// `/Next` that is not active.
    static func readActionGraph(from object: CGPDFObjectRef, maxDepth: Int = maxActionChainDepth) -> ActionGraph {
        var nodes: [ActionGraph.Node] = []
        var index: [CGPDFDictionaryRef: Int] = [:]
        var toRead: [(dictionary: CGPDFDictionaryRef, node: Int, depth: Int)] = []
        func node(for object: CGPDFObjectRef, depth: Int) -> Int {
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else {
                nodes.append(.init(isActive: false, next: []))
                return nodes.count - 1
            }
            if let known = index[dictionary] { return known }
            let active = isActiveAction(dictionary)
            nodes.append(.init(isActive: active, next: []))
            index[dictionary] = nodes.count - 1
            if !active, depth < maxDepth { toRead.append((dictionary, nodes.count - 1, depth)) }
            return nodes.count - 1
        }
        _ = node(for: object, depth: 0)
        var head = 0
        while head < toRead.count {
            let (dictionary, current, depth) = toRead[head]
            head += 1
            var next: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(dictionary, "Next", &next), let next else { continue }
            var chain: CGPDFArrayRef?
            if CGPDFObjectGetValue(next, .array, &chain), let chain {
                for slot in 0..<CGPDFArrayGetCount(chain) {
                    var item: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(chain, slot, &item), let item else { continue }
                    let child = node(for: item, depth: depth + 1)
                    nodes[current].next.append(child)
                }
            } else {
                let child = node(for: next, depth: depth + 1)
                nodes[current].next.append(child)
            }
        }
        return ActionGraph(nodes: nodes)
    }

    /// The walk over an action graph from node 0, depth first in `/Next`
    /// order: true at the first active node, nil at the first node met at
    /// `maxDepth` hops or more or met again while still on the current path
    /// (a loop), false when neither happens. Each node keeps the deepest
    /// depth at which its own chain was read clean; meeting it again at
    /// that depth or shallower answers false without reading it again, and
    /// only a deeper meeting reads it again, so each node is read at most
    /// `maxDepth` times. The answer is the same as reading every path in
    /// full to the depth bound.
    static func actionGraphIsActive(_ graph: ActionGraph, maxDepth: Int = maxActionChainDepth) -> Bool? {
        guard !graph.nodes.isEmpty else { return false }
        var onPath = [Bool](repeating: false, count: graph.nodes.count)
        var cleanAtDepth = [Int](repeating: -1, count: graph.nodes.count)
        func walk(_ node: Int, depth: Int) -> Bool? {
            guard depth < maxDepth, !onPath[node] else { return nil }
            if depth <= cleanAtDepth[node] { return false }
            if graph.nodes[node].isActive { return true }
            onPath[node] = true
            defer { onPath[node] = false }
            for next in graph.nodes[node].next {
                switch walk(next, depth: depth + 1) {
                case true: return true
                case nil: return nil
                case false: continue
                }
            }
            cleanAtDepth[node] = depth
            return false
        }
        return walk(0, depth: 0)
    }

    /// Every value in an additional-actions dictionary is an action keyed by
    /// its trigger (`/O` open, `/C` close, and so on); any active one counts,
    /// and a chain the walk could not read to the end answers nil.
    static func additionalActionsAreActive(_ additionalActions: CGPDFDictionaryRef) -> Bool? {
        var verdict: Bool? = false
        CGPDFDictionaryApplyBlock(additionalActions, { _, value, _ in
            switch actionChainIsActive(value) {
            case true:
                verdict = true
                return false
            case nil:
                verdict = nil
                return false
            case false:
                return true
            }
        }, nil)
        return verdict
    }
}
