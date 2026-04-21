import Foundation

// Pure, headless-testable helpers for building FTS5 MATCH expressions out of
// user input. Keeps the SQLite layer free of string-munging logic.
//
// ## Why sanitization is load-bearing
//
// FTS5's query syntax reserves several characters:
//
//   - `"` — string-literal quoting
//   - `-` — column filter / negation (`title:-foo` / `-foo`)
//   - `(` `)` — grouping
//   - `*` — prefix wildcard (kept, it's useful)
//   - `:` — column filter separator
//   - `^` — first-token match
//
// A raw input like `row-42` is parsed as *column `row`, NOT `42`* and throws
// "no such column: row". Paths like `file:///tmp/x.swift` hit both `:` and `/`.
//
// `SearchQuery.sanitize(_:)` turns arbitrary user input into a syntactically-safe
// MATCH expression. The strategy: tokenize on whitespace, quote any token that
// contains a reserved character, and AND the tokens together. Quoted FTS tokens
// treat the reserved characters as literal — that's how we neutralize them
// without losing search power.
public enum SearchQuery {

    /// Characters that force a token to be double-quoted when passed to FTS5.
    /// Per the FTS5 docs a token must be a "bareword" (alnum + a few non-ASCII
    /// letters) to skip quoting — any reserved/punctuation character means we
    /// wrap the token.
    private static let reserved: Set<Character> = [
        "\"", "-", "(", ")", ":", "^", ".", "/", "\\",
        "'", "`", ",", ";", "!", "?", "@", "#", "$",
        "%", "&", "=", "+", "<", ">", "[", "]", "{", "}",
        "|", "~"
    ]

    /// Turns arbitrary user input into a syntactically-safe FTS5 MATCH string.
    ///
    /// Contract:
    ///   - Empty / whitespace-only input → `""` (caller should short-circuit).
    ///   - Whitespace tokenization: every run of whitespace is a token boundary.
    ///   - A token that contains a reserved character is wrapped in double
    ///     quotes; any literal `"` inside is doubled (`""`).
    ///   - A bare `*` suffix on a token is preserved as a prefix wildcard (the
    ///     common case of "type-ahead").
    ///   - Resulting tokens are joined by a single space — FTS5 reads this as
    ///     an implicit AND across tokens.
    ///
    /// The output is **not** further validated against FTS5's parser. Callers
    /// are expected to run it through `captures_fts MATCH ?` which will surface
    /// real parse errors at query time.
    public static func sanitize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        var out: [String] = []
        out.reserveCapacity(8)

        for rawToken in trimmed.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(rawToken)
            if token.isEmpty { continue }

            // Preserve a trailing '*' wildcard: `foo*` → keep as `foo*`,
            // but quote the body if it holds reserved characters.
            let hasWildcard = token.hasSuffix("*") && token.count > 1
            let body = hasWildcard ? String(token.dropLast()) : token
            if body.isEmpty { continue }

            let needsQuote = body.contains(where: { reserved.contains($0) })
            let safeBody: String
            if needsQuote {
                let escaped = body.replacingOccurrences(of: "\"", with: "\"\"")
                safeBody = "\"\(escaped)\""
            } else {
                safeBody = body
            }

            out.append(hasWildcard ? "\(safeBody)*" : safeBody)
        }

        return out.joined(separator: " ")
    }

    /// Convenience for the common "rank results by created_at DESC" case. The
    /// `LibraryIndex.searchIDs` API already sorts by `created_at DESC`, so this
    /// is currently just the identity function on the id list, exposed as an
    /// extension point for a future bm25-weighted ordering.
    ///
    /// See `bm25Score(_:_:)` for the numeric-score variant.
    public static func rankByRecency(_ ids: [String]) -> [String] {
        ids
    }

    /// Coarse "boost" for a result based on a simple signal: whether the row's
    /// id (used here as a stand-in for row-level metadata) contains a given
    /// marker. Exposed for tests / future ranking work. Zero-cost no-op for
    /// the main query path.
    public static func bm25Score(_ query: String, _ candidate: String) -> Double {
        // Placeholder for a future bm25 pull-through. The real scoring lives in
        // FTS5 itself via `bm25(captures_fts)`; we don't need it for the v0.1
        // search overlay, which only shows the top-N recency-ordered hits.
        guard !query.isEmpty, candidate.localizedCaseInsensitiveContains(query) else {
            return 0
        }
        return 1
    }
}
