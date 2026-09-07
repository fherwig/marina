import Foundation
import AppKit

struct FileEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let size: Int64?
    let modified: Date?

    var id: String { url.path }

    /// Folders you navigate into. Packages (.app, .assets, …) are directories
    /// on disk but behave as leaves, like in Finder.
    var isNavigable: Bool { isDirectory && !isPackage }

    // sortable projections for the table columns
    var sortSize: Int64 { isNavigable ? -1 : (size ?? 0) }
    var sortDate: Date { modified ?? .distantPast }

    static func list(of directory: URL, showHidden: Bool) -> [FileEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: options
        ) else { return [] }

        var result: [FileEntry] = []
        result.reserveCapacity(urls.count)
        for url in urls {
            let rv = try? url.resourceValues(forKeys: Set(keys))
            let isLink = rv?.isSymbolicLink ?? false
            var isDir = rv?.isDirectory ?? false
            if isLink {
                // follow the link so symlinked folders navigate like folders
                var d: ObjCBool = false
                isDir = fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
            }
            result.append(FileEntry(
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDir,
                isPackage: rv?.isPackage ?? false,
                isSymlink: isLink,
                isHidden: rv?.isHidden ?? false,
                size: (rv?.fileSize).map(Int64.init),
                modified: rv?.contentModificationDate
            ))
        }
        // base order: by name; PaneState applies the pane's sort order on top
        result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var displaySize: String {
        if isDirectory { return "—" }
        guard let size else { return "—" }
        return Self.byteFormatter.string(fromByteCount: size)
    }

    var displayDate: String {
        guard let modified else { return "—" }
        if Calendar.current.isDateInToday(modified) {
            return Self.timeFormatter.string(from: modified)
        }
        return Self.dateFormatter.string(from: modified)
    }
}

enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for entry: FileEntry) -> NSImage {
        let key = entry.url.path as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = NSWorkspace.shared.icon(forFile: entry.url.path)
        img.size = NSSize(width: 16, height: 16)
        cache.setObject(img, forKey: key)
        return img
    }
}
