import Foundation
import Testing
@testable import RedactionEngine

// B03 — Swift<->Python context-feature parity (Swift side).
//
// The C1 scorer's 13 features must be computed identically wherever they are
// produced (the seam builder here, the File-5 fire dump, the Python trainer).
// These fixed ASCII cases assert the production `contextFeatures(...)` builder
// produces the GOLDEN 13-vectors — the language-agnostic feature contract. The
// DataPipeline test `tests/test_context_feature_parity.py` asserts the SAME
// golden vectors via a faithful Python port over the SAME inputs; both green ⇒
// Swift and Python agree. This suite is an ASCII-only oracle: for ASCII input
// the NSString UTF-16 offsets the builder uses equal Python string indices, so
// the two ports align by construction. The A1/A2/A3 cases extend it past the
// ASCII boundary (BMP-accent, NBSP, supplementary-plane) where codepoint indices
// and UTF-16 offsets diverge — per the DataPipeline format contract
// (feature-unit provenance). Canonical unit = Swift/UTF-16 (device = ground truth).
//
// 0.833… = 1/(1 + 2/10); 0.909… = 1/(1 + 1/10); 0.714… = 1/(1 + 4/10).

@Suite("Context feature parity (Swift<->Python golden)")
struct ContextFeatureParityTests {

    private struct Case {
        let name: String
        let text: String
        let loc: Int
        let len: Int
        let kind: RedactionRegion.PIIKind
        let doctype: DoctypeClass
        let golden: [Double]
    }

    private static let cases: [Case] = [
        Case(name: "account/financial", text: "Account: 1234567890", loc: 9, len: 10,
             kind: .account, doctype: .financial,
             golden: [1, 0, 0.8333333333333334, 0, 10, 0, 1, 0, 0, 0, 1, 0, 0]),
        Case(name: "phone/generic-neg", text: "Case No: 5551234567 filed", loc: 9, len: 10,
             kind: .phone, doctype: .generic,
             golden: [0, 1, 0, 0.8333333333333334, 10, 0, 1, 0, 0, 0, 0, 0, 1]),
        Case(name: "mrn/medical-linestart-sep", text: "Patient chart\nMR-9988776", loc: 14, len: 10,
             kind: .medicalRecord, doctype: .medical,
             golden: [1, 0, 0.9090909090909091, 0, 7, 1, 0, 1, 0, 1, 0, 0, 0]),
        Case(name: "account/court", text: "Acct #: 0001112223", loc: 8, len: 10,
             kind: .account, doctype: .court,
             golden: [1, 0, 0.8333333333333334, 0, 10, 0, 1, 0, 1, 0, 0, 0, 0]),
        Case(name: "ein/foia-sep", text: "EIN: 12-3456789", loc: 5, len: 10,
             kind: .ein, doctype: .foia,
             golden: [1, 0, 0.8333333333333334, 0, 9, 1, 1, 0, 0, 0, 0, 1, 0]),

        // --- D09-pipeline-parity-F2 — non-ASCII parity cases (A1/A2/A3). loc/len
        // and all distances are NSString UTF-16 offsets; the faithful Python port
        // reproduces them via its _u16 helper. Goldens hand-derived from the
        // contextFeatures(...) arithmetic and shared byte-for-byte with
        // tests/test_context_feature_parity.py (a half-updated pair reds one suite).

        // A1 — BMP accented (em-dash U+2014 + ü U+00FC) AFTER the match. BMP scalars
        // are 1 UTF-16 unit each, so offsets stay codepoint-aligned and the accented
        // tail is inert; pins .lowercased()/.lower() + em-dash whitespace-split parity.
        Case(name: "account/bmp-accent", text: "Acct: 1234567890 \u{2014} M\u{00FC}ller", loc: 6, len: 10,
             kind: .account, doctype: .generic,
             golden: [1, 0, 0.8333333333333334, 0, 10, 0, 1, 0, 0, 0, 0, 0, 1]),
        // A2 — NBSP (U+00A0) between a newline and the match. at_line_start treats
        // NBSP as whitespace (Swift CharacterSet.whitespaces; the Python port matches
        // via Unicode "Zs" + tab), so the back-walk reaches the newline ⇒ at_line_start
        // = 1. A naive (" ","\t")-only port would read 0 here.
        Case(name: "phone/nbsp-linestart", text: "Tel\n\u{00A0}5551234567", loc: 5, len: 10,
             kind: .phone, doctype: .generic,
             golden: [1, 0, 0.8333333333333334, 0, 10, 0, 0, 1, 0, 0, 0, 0, 1]),
        // A3 — a supplementary-plane scalar (U+10437, 2 UTF-16 units) inside the gap
        // between "acct" and the match: the keyword→match gap is 4 UTF-16 units (":"
        // + space + 2 surrogate units) ⇒ nearest_positive = 1/(1+4/10). A codepoint-
        // indexed port mis-measures the gap; the _u16-faithful port agrees.
        Case(name: "account/supplementary", text: "Acct: \u{10437}1234567890", loc: 8, len: 10,
             kind: .account, doctype: .financial,
             golden: [1, 0, 0.7142857142857143, 0, 10, 0, 0, 0, 0, 0, 1, 0, 0]),
    ]

    @Test("contextFeatures matches the golden 13-vectors on fixed ASCII")
    func goldenVectors() {
        for c in Self.cases {
            let text = c.text as NSString
            let matchText = text.substring(with: NSRange(location: c.loc, length: c.len))
            let match = PIIDetector.PIIMatch(
                text: matchText,
                range: NSRange(location: c.loc, length: c.len),
                kind: c.kind,
                confidence: 0.75
            )
            let got = contextFeatures(
                match: match,
                doctype: c.doctype,
                effectiveDoctype: c.doctype,
                pageText: c.text
            )
            #expect(got.count == ContextFeatureContract.featureOrder.count, "\(c.name) arity")
            #expect(got.count == 13, "\(c.name) arity == 13")
            for i in got.indices {
                let delta = abs(got[i] - c.golden[i])
                #expect(delta < 1e-9, "\(c.name) feature \(ContextFeatureContract.featureOrder[i]): got \(got[i]) want \(c.golden[i])")
            }
        }
    }
}
