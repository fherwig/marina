import Foundation
import Combine

/// A named, collapsible group of favourites. Sections are the user's own —
/// created, renamed and reordered by hand — so identity is a UUID rather than
/// the name, and renaming never orphans the contents.
struct FavouriteSection: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var urls: [URL] = []
    var collapsed = false
}

/// The favourites are one list for the whole app, not one per window: add a
/// folder in one Marina and every other Marina shows it straight away. Written
/// to defaults on every change, so it also survives a restart — and no window
/// can overwrite another's additions with its own older copy.
@MainActor
final class FavouritesStore: ObservableObject {
    static let shared = FavouritesStore()

    private static let key = "marina.favourites.sections"
    /// The pre-sections flat list. Still written on every save so that going
    /// back to an older build shows the favourites rather than an empty
    /// sidebar — losing this list once was bad enough.
    private static let legacyKey = "marina.favourites"

    static let defaultSectionName = "Favourites"

    @Published private(set) var sections: [FavouriteSection] = []

    /// Every favourite in sidebar order, sections flattened away — for callers
    /// that only ask "is this folder a favourite?".
    var items: [URL] { sections.flatMap(\.urls) }

    private init() { load() }

    // MARK: - Items

    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return sections.contains { $0.urls.contains { $0.path == path } }
    }

    /// Add a favourite. With no destination it goes to the end of the first
    /// section; an item that is already a favourite stays where it is.
    func add(_ url: URL, toSection sectionID: UUID? = nil, at position: Int? = nil) {
        let std = url.standardizedFileURL
        if contains(std) {
            // already here — an explicit destination means "move it there"
            if let sectionID { move(std, toSection: sectionID, at: position ?? .max) }
            return
        }
        if sections.isEmpty { sections = [FavouriteSection(name: Self.defaultSectionName)] }
        let s = sectionID.flatMap { id in sections.firstIndex { $0.id == id } } ?? 0
        let at = clamp(position ?? .max, to: sections[s].urls.count)
        sections[s].urls.insert(std, at: at)
        sections[s].collapsed = false
        save()
    }

    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        for i in sections.indices { sections[i].urls.removeAll { $0.path == path } }
        save()
    }

    /// Drag-reorder: pull the favourite out of wherever it is and put it back
    /// at `position` in `sectionID`. Removing first shifts everything after it
    /// up by one, so a move down within a section has to compensate.
    func move(_ url: URL, toSection sectionID: UUID, at position: Int) {
        guard let target = sections.firstIndex(where: { $0.id == sectionID }) else { return }
        let path = url.standardizedFileURL.path
        var at = position
        if let from = sections.firstIndex(where: { $0.urls.contains { $0.path == path } }),
           let old = sections[from].urls.firstIndex(where: { $0.path == path }) {
            sections[from].urls.remove(at: old)
            if from == target && old < at { at -= 1 }
        }
        sections[target].urls.insert(url.standardizedFileURL, at: clamp(at, to: sections[target].urls.count))
        save()
    }

    /// Which section holds this favourite, if any.
    func section(of url: URL) -> FavouriteSection? {
        let path = url.standardizedFileURL.path
        return sections.first { $0.urls.contains { $0.path == path } }
    }

    // MARK: - Sections

    @discardableResult
    func addSection(named name: String) -> UUID {
        let section = FavouriteSection(name: cleaned(name))
        sections.append(section)
        save()
        return section.id
    }

    func renameSection(_ id: UUID, to name: String) {
        guard let i = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[i].name = cleaned(name)
        save()
    }

    /// Delete a section without deleting its favourites: they move to the
    /// section above (or below, for the first one). The last section stays —
    /// there has to be somewhere for a new favourite to land.
    func deleteSection(_ id: UUID) {
        guard sections.count > 1, let i = sections.firstIndex(where: { $0.id == id }) else { return }
        let orphans = sections[i].urls
        let keep = i == 0 ? 1 : i - 1
        sections[keep].urls.append(contentsOf: orphans)
        sections.remove(at: i)
        save()
    }

    func moveSection(_ id: UUID, by delta: Int) {
        guard let i = sections.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard sections.indices.contains(j) else { return }
        sections.swapAt(i, j)
        save()
    }

    func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let i = sections.firstIndex(where: { $0.id == id }), sections[i].collapsed != collapsed else { return }
        sections[i].collapsed = collapsed
        save()
    }

    func setAllCollapsed(_ collapsed: Bool) {
        guard sections.contains(where: { $0.collapsed != collapsed }) else { return }
        for i in sections.indices { sections[i].collapsed = collapsed }
        save()
    }

    func toggleCollapsed(_ id: UUID) {
        guard let i = sections.firstIndex(where: { $0.id == id }) else { return }
        setCollapsed(id, !sections[i].collapsed)
    }

    /// A name that is unique enough to tell apart in the sidebar.
    func uniqueSectionName(basedOn base: String = "New Section") -> String {
        var name = base
        var n = 2
        while sections.contains(where: { $0.name == name }) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    // MARK: - Persistence

    private func clamp(_ i: Int, to count: Int) -> Int { min(max(i, 0), count) }

    private func cleaned(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? uniqueSectionName() : trimmed
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([FavouriteSection].self, from: data),
           !decoded.isEmpty {
            sections = decoded
            return
        }
        // upgrade from the flat list
        if let paths = UserDefaults.standard.stringArray(forKey: Self.legacyKey) {
            sections = [FavouriteSection(name: Self.defaultSectionName,
                                        urls: paths.map { URL(fileURLWithPath: $0) })]
            save()
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let starters = [
            home,
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads"),
            URL(fileURLWithPath: "/Applications")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        sections = [FavouriteSection(name: Self.defaultSectionName, urls: starters)]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sections) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        UserDefaults.standard.set(items.map(\.path), forKey: Self.legacyKey)
    }
}
