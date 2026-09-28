import Foundation
import Combine

@MainActor
final class PaneState: ObservableObject, Identifiable {
    nonisolated let id = UUID()

    @Published private(set) var directory: URL
    @Published private(set) var entries: [FileEntry] = []
    /// Why this folder is empty, when it is empty because it could not be read.
    @Published private(set) var failure: FileEntry.Listing.Failure?
    @Published var selection = Set<String>()
    @Published var showHidden = false {
        didSet { reload() }
    }
    @Published var sortOrder: [KeyPathComparator<FileEntry>] = [
        KeyPathComparator(\FileEntry.name)
    ] {
        didSet { entries = Self.applySort(entries, order: sortOrder) }
    }

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var watcher: DirectoryWatcher?
    private var reloadWork: DispatchWorkItem?

    var onDirectoryChange: ((URL) -> Void)?

    init(directory: URL) {
        self.directory = Self.resolved(directory)
        reload()
        selectFirst()
        startWatching()
    }

    var selectedEntries: [FileEntry] {
        entries.filter { selection.contains($0.id) }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// A pane never points at a symlink, only at what it resolves to.
    /// `fileExists(atPath:)` follows a link, so a symlinked folder passes for a
    /// folder — but `contentsOfDirectory(at:)` does not follow it and fails
    /// with ENOTDIR, so the pane would navigate in and then list nothing. That
    /// is what "~/OneDrive - University of Victoria" is: a link into
    /// ~/Library/CloudStorage. Only links are resolved, so ordinary paths are
    /// not quietly rewritten (/tmp into /private/tmp and the like).
    static func resolved(_ url: URL) -> URL {
        let std = url.standardizedFileURL
        let isLink = (try? std.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        return isLink ? std.resolvingSymlinksInPath() : std
    }

    func navigate(to url: URL, recordHistory: Bool = true) {
        let std = Self.resolved(url)
        guard std.path != directory.path else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: std.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        if recordHistory {
            backStack.append(directory)
            forwardStack.removeAll()
        }
        directory = std
        reload()
        selectFirst()
        startWatching()
        onDirectoryChange?(std)
    }

    func goUp() {
        let from = directory
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { return }
        navigate(to: parent)
        // land on the folder we just came out of
        if entries.contains(where: { $0.id == from.path }) {
            selection = [from.path]
        }
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(directory)
        navigate(to: target, recordHistory: false)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(directory)
        navigate(to: target, recordHistory: false)
    }

    func reload() {
        let listing = FileEntry.list(of: directory, showHidden: showHidden)
        entries = Self.applySort(listing.entries, order: sortOrder)
        failure = listing.failure
        selection = selection.filter { id in entries.contains { $0.id == id } }
        if selection.isEmpty { selectFirst() }
    }

    /// Column sort within the commander convention: folders always group first.
    private static func applySort(
        _ items: [FileEntry],
        order: [KeyPathComparator<FileEntry>]
    ) -> [FileEntry] {
        let sorted = items.sorted(using: order)
        return sorted.filter(\.isNavigable) + sorted.filter { !$0.isNavigable }
    }

    func selectFirst() {
        selection = entries.first.map { [$0.id] } ?? []
    }

    func select(_ url: URL) {
        if entries.contains(where: { $0.id == url.path }) {
            selection = [url.path]
        }
    }

    private func startWatching() {
        watcher = DirectoryWatcher(url: directory) { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
