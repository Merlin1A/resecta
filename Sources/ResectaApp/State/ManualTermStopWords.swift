import Foundation

// The English stop list the manual-region capture reads: a single token of a
// multi-word run joins the verifier's term set only when it carries a digit,
// or has four or more scalars and is not listed here — articles, prepositions,
// pronouns, auxiliaries, conjunctions and the common nouns of forms and
// statements. Non-English text keeps the four-scalar rule alone. The count
// is pinned by a test; the verification corpus mirror carries the same list.

nonisolated enum ManualTermStopWords {

    /// The list, lowercase, every entry four scalars or longer (shorter
    /// tokens never reach it); a token is looked up lowercased.
    static let words: Set<String> = [
        // articles and determiners
        "this", "that", "these", "those", "each", "every", "some", "none",
        "both", "either", "neither", "other", "another", "such", "same",
        // prepositions
        "with", "from", "into", "over", "under", "about", "after", "before",
        "between", "through", "during", "without", "within", "upon", "among",
        "against", "toward", "across", "along", "around", "behind", "below",
        "above", "beside", "beyond", "near", "onto", "until", "since",
        // pronouns
        "mine", "ours", "your", "yours", "hers", "they", "them", "their",
        "theirs", "whom", "whose", "which", "what", "where", "when",
        // auxiliaries
        "were", "been", "being", "have", "having", "does", "doing", "will",
        "would", "shall", "should", "could", "might", "must",
        // conjunctions and adverbs
        "then", "else", "because", "although", "though", "while", "whether",
        "unless", "also", "only", "just", "more", "most", "less", "than",
        "here", "there", "very",
        // the common nouns of forms and statements
        "account", "number", "name", "date", "page", "pages", "total",
        "amount", "address", "phone", "email", "city", "state", "code",
        "country", "street", "item", "items", "order", "invoice", "balance",
        "payment", "type", "form", "line", "note", "notes", "time", "month",
        "year", "title", "first", "last", "file", "document", "section",
        "part", "reference", "data", "value", "list", "table", "column",
        "field", "label", "status", "subtotal", "rate", "unit", "units",
        "price", "quantity", "description", "details", "signature", "copy",
        "original", "draft", "final", "attachment",
    ]

    /// The admission rule for one token of a multi-word run: kept when it
    /// carries a digit; else kept when it has four or more scalars and is
    /// not listed.
    static func admits(_ token: String) -> Bool {
        if token.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
            return true
        }
        return token.unicodeScalars.count >= 4 && !words.contains(token.lowercased())
    }
}
