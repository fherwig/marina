import Foundation
import Combine

/// Every change Marina makes to the disk, kept so ⌘Z can take it back and
/// ⇧⌘Z can make it again.
///
/// Everything reduces to two kinds of fact. Something MOVED from one place to
/// another — a move, a rename, a trip to the Trash. Or something was CREATED —
/// a copy, a new folder, a new file. Reverting a move moves it back; reverting
/// a creation sends it to the Trash, and remembers where in the Trash it went,
/// so a redo can bring it back out rather than having to make it again. Nothing
/// is ever deleted outright, so no undo or redo can lose a file.
///
/// One history for the whole app, as Finder keeps it: a file moved in one
/// window is just as moved in another.
@MainActor
final class FileUndo: ObservableObject {
    static let shared = FileUndo()

    final class Change {
        /// What the menu calls it: "Move of 3 Items", "Rename", …
        let title: String
        /// Done in this order, from → to.
        var moves: [(from: URL, to: URL)]
        /// Exist now because of this change.
        var created: [URL]
        /// Where each created item went when the change was reverted.
        var parkedInTrash: [URL: URL] = [:]

        init(title: String, moves: [(from: URL, to: URL)] = [], created: [URL] = []) {
            self.title = title
            self.moves = moves
            self.created = created
        }
    }

    @Published private(set) var undoStack: [Change] = []
    @Published private(set) var redoStack: [Change] = []

    /// Deep enough for any afternoon, small enough to stay meaningless in memory.
    private let depth = 100

    var undoTitle: String? { undoStack.last?.title }
    var redoTitle: String? { redoStack.last?.title }

    func record(_ change: Change) {
        guard !change.moves.isEmpty || !change.created.isEmpty else { return }
        undoStack.append(change)
        if undoStack.count > depth { undoStack.removeFirst() }
        // a new action forks history; what was undone before it cannot be redone
        redoStack.removeAll()
    }

    /// A placeholder that is being taken back by other means (a cancelled
    /// "New Markdown File") must not stay in the history pointing at nothing.
    func forget(created url: URL) {
        guard let last = undoStack.last, last.created == [url], last.moves.isEmpty else { return }
        undoStack.removeLast()
    }

    /// Returns what went wrong, if anything. A step that cannot be taken back
    /// — its file was moved or deleted outside Marina since — is reported, and
    /// the rest of the change is still undone.
    @discardableResult
    func undo() -> String? {
        guard let change = undoStack.popLast() else { return nil }
        let problem = revert(change)
        redoStack.append(change)
        return problem
    }

    @discardableResult
    func redo() -> String? {
        guard let change = redoStack.popLast() else { return nil }
        let problem = reapply(change)
        undoStack.append(change)
        return problem
    }

    // MARK: - The two directions

    private func revert(_ change: Change) -> String? {
        let fm = FileManager.default
        var problems: [String] = []
        // creations first, then moves backwards: a copy made into a folder
        // that was itself moved must leave before the folder goes back
        for url in change.created {
            var parked: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &parked)
                if let parked { change.parkedInTrash[url] = parked as URL }
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for step in change.moves.reversed() {
            do {
                // moveItem refuses to replace: never clobber what is there now
                try fm.moveItem(at: step.to, to: step.from)
            } catch {
                problems.append("\(step.to.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private func reapply(_ change: Change) -> String? {
        let fm = FileManager.default
        var problems: [String] = []
        for step in change.moves {
            do {
                try fm.moveItem(at: step.from, to: step.to)
            } catch {
                problems.append("\(step.from.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for url in change.created {
            guard let parked = change.parkedInTrash[url] else { continue }
            do {
                try fm.moveItem(at: parked, to: url)
                change.parkedInTrash[url] = nil
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    static func title(_ verb: String, count: Int) -> String {
        count == 1 ? verb : "\(verb) of \(count) Items"
    }
}

/// Finder's rule for what a drag does, so a drop in Marina means what it would
/// mean in Finder: within one disk it MOVES, onto another disk it COPIES. ⌥
/// held forces a copy, ⌘ held forces a move.
enum DropIntent {
    static func shouldMove(_ sources: [URL], into folder: URL,
                           option: Bool, command: Bool) -> Bool {
        if option { return false }
        if command { return true }
        guard let target = volume(of: folder) else { return false }
        // one item from another disk makes the whole drop a copy: a drag
        // that half moves and half copies would be impossible to predict
        return sources.allSatisfy { volume(of: $0).map { $0.isEqual(target) } ?? false }
    }

    private static func volume(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }
}
