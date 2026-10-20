import Foundation

/// The tile view's cursor and marks, and the selection they make.
///
/// The arrows move the cursor, Space marks the tile under it or unmarks it,
/// Esc drops the marks. What every action works on is the marked tiles, or
/// the cursor's tile when none is marked. Kept apart from the view, which a
/// test cannot drive (keys only reach a window that has the keyboard), so
/// Support/Tiles/tests can: `order` is the folder's ids as shown.
struct TileSelection: Equatable {
    var cursor: String?
    var marks = Set<String>()

    var selection: Set<String> {
        marks.isEmpty ? Set(cursor.map { [$0] } ?? []) : marks
    }

    enum Move { case left, right, up, down, first, last }

    /// Where a key takes the cursor, as an index, in a grid `columns` wide.
    static func target(of move: Move, from current: Int?, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return move == .last ? count - 1 : 0 }
        let columns = max(columns, 1)
        switch move {
        case .left: return max(current - 1, 0)
        case .right: return min(current + 1, count - 1)
        case .up: return current - columns >= 0 ? current - columns : current
        case .down:
            if current + columns < count { return current + columns }
            // a short last row below: its last tile, as in Finder
            return current / columns < (count - 1) / columns ? count - 1 : current
        case .first: return 0
        case .last: return count - 1
        }
    }

    private func index(of id: String?, in order: [String]) -> Int? {
        id.flatMap { order.firstIndex(of: $0) }
    }

    mutating func move(_ move: Move, order: [String], columns: Int, extend: Bool) {
        guard let next = Self.target(of: move, from: index(of: cursor, in: order),
                                     count: order.count, columns: columns) else { return }
        moveTo(next, order: order, extend: extend)
    }

    /// `extend` (⇧): mark every tile passed over. Otherwise the marks stay
    /// where they are while the cursor moves on.
    mutating func moveTo(_ next: Int, order: [String], extend: Bool) {
        guard order.indices.contains(next) else { return }
        if extend {
            if marks.isEmpty, let cursor { marks = [cursor] }
            let from = index(of: cursor, in: order) ?? next
            for i in min(from, next)...max(from, next) { marks.insert(order[i]) }
        }
        cursor = order[next]
    }

    /// Space: mark or unmark the cursor's tile.
    mutating func toggleMark() {
        guard let cursor else { return }
        if marks.contains(cursor) { marks.remove(cursor) } else { marks.insert(cursor) }
    }

    /// A click: that tile alone. ⌘: mark or unmark it, keeping the rest,
    /// the cursor's tile included. ⇧: mark the run from the cursor to it.
    mutating func click(_ id: String, order: [String], command: Bool, shift: Bool) {
        if command {
            if marks.isEmpty, let cursor { marks = [cursor] }
            if marks.contains(id) { marks.remove(id) } else { marks.insert(id) }
        } else if shift, let from = index(of: cursor, in: order), let to = order.firstIndex(of: id) {
            marks = Set(order[min(from, to)...max(from, to)])
        } else {
            marks = []
        }
        cursor = id
    }

    /// A drag from a tile outside the selection drags that tile alone.
    mutating func dragStarts(on id: String) {
        guard !selection.contains(id) else { return }
        marks = []
        cursor = id
    }

    /// The selection was set from outside: a new folder, a reveal, ⌘A, a
    /// right-click on a tile. Put the cursor and marks where it is.
    mutating func adopt(_ selection: Set<String>, order: [String]) {
        guard selection != self.selection else { return }
        if selection.count <= 1 {
            marks = []
            cursor = selection.first
        } else {
            marks = selection
            if cursor.map({ !selection.contains($0) }) ?? true {
                cursor = order.first { selection.contains($0) }
            }
        }
    }
}
