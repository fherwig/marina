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

    /// What reading a directory produced. The failure has to travel with the
    /// entries: an unreadable folder yields an empty list, which looks exactly
    /// like an empty folder — that is how iCloud Drive came up blank with
    /// nothing said about why.
    struct Listing {
        var entries: [FileEntry] = []
        var failure: Failure?

        struct Failure {
            let message: String
            /// macOS refused on privacy grounds rather than file permissions,
            /// so the remedy is in System Settings, not chmod.
            let needsPermission: Bool
        }
    }

    static func list(of directory: URL, showHidden: Bool) -> Listing {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: options)
        } catch {
            return Listing(failure: failure(from: error))
        }

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
        return Listing(entries: result)
    }

    /// Both a mode-based refusal and a privacy one arrive as
    /// NSFileReadNoPermissionError, and they are not worth telling apart: the
    /// message covers both, because the protected locations (iCloud Drive at
    /// ~/Library/Mobile Documents, another app's data) are the ones where the
    /// mode looks fine and macOS refuses anyway.
    private static func failure(from error: Error) -> Listing.Failure {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain,
              nsError.code == NSFileReadNoPermissionError else {
            return Listing.Failure(message: nsError.localizedDescription,
                                   needsPermission: false)
        }
        return Listing.Failure(
            message: "macOS is blocking access to this folder.",
            needsPermission: true)
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
