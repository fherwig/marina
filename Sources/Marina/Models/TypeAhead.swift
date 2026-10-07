import Foundation

/// Type-ahead that cycles.
///
/// AppKit's own accumulates everything typed inside its timeout, so pressing
/// "a" three times quickly searched for something named "aaa" and sat still —
/// only a pause between letters made it look like it was stepping through the
/// "a"s. Here a repeat of the same prefix walks the matches instead of
/// extending the search, so it cycles at whatever speed you type. Different
/// letters still narrow, and a prefix that matches nothing falls back to the
/// key on its own rather than leaving you stuck.
///
/// The rule lives here rather than in each view, because it is subtle enough
/// to be worth getting right once.
struct TypeAhead {
    /// Letters, digits, and the punctuation real names start with. No space:
    /// Quick Look and the sidebar's action menu own that key.
    static let characters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+~"))

    /// How long a typed prefix stays alive. Past this the next key starts over.
    private static let window: TimeInterval = 0.9

    private var prefix = ""
    private var stamp = Date.distantPast

    /// Which of `names` to select for this keystroke, or nil if nothing
    /// matches. `current` is where the selection is now, so a repeated prefix
    /// can step past it. Names that cannot be selected — section headers —
    /// belong in the array as "", which never matches.
    mutating func next(_ typed: String, in names: [String], from current: Int?) -> Int? {
        let now = Date()
        let stale = now.timeIntervalSince(stamp) > Self.window
        stamp = now

        let key = typed.lowercased()
        let previous = prefix
        var candidate = stale || prefix == key ? key : prefix + key
        var matches = indices(matching: candidate, in: names)
        if matches.isEmpty, candidate != key {
            candidate = key
            matches = indices(matching: candidate, in: names)
        }
        guard !matches.isEmpty else { return nil }
        prefix = candidate

        // the prefix did not grow, so this keystroke means "the next one"
        if candidate == previous, let current, let at = matches.firstIndex(of: current) {
            return matches[(at + 1) % matches.count]
        }
        return matches[0]
    }

    private func indices(matching prefix: String, in names: [String]) -> [Int] {
        names.indices.filter { !names[$0].isEmpty && names[$0].lowercased().hasPrefix(prefix) }
    }
}
