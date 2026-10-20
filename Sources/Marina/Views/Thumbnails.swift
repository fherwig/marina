import AppKit
import QuickLookThumbnailing

/// The pictures in the tile view, the ones Finder shows: the image itself, a
/// PDF's first page, a frame of a film, a page of text, or the file's icon
/// when Quick Look has nothing better. Made in the background and kept while
/// Marina runs, by file, its date and a size step, so dragging the slider
/// does not ask again at every point.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        // pixels, roughly: a few hundred large tiles
        cache.totalCostLimit = 400 * 1024 * 1024
    }

    /// Thumbnails are made at one of these widths and drawn at the tile's.
    static func step(for side: CGFloat) -> CGFloat {
        [64, 128, 256, 512, 1024].first { $0 >= side } ?? 1024
    }

    private static func key(_ entry: FileEntry, _ step: CGFloat) -> NSString {
        "\(entry.url.path)|\(entry.modified?.timeIntervalSince1970 ?? 0)|\(Int(step))" as NSString
    }

    func cached(_ entry: FileEntry, side: CGFloat) -> NSImage? {
        cache.object(forKey: Self.key(entry, Self.step(for: side)))
    }

    /// nil when the tile went away first, or Quick Look gave nothing.
    func load(_ entry: FileEntry, side: CGFloat, scale: CGFloat) async -> NSImage? {
        let step = Self.step(for: side)
        let key = Self.key(entry, step)
        if let image = cache.object(forKey: key) { return image }
        let request = QLThumbnailGenerator.Request(
            fileAt: entry.url, size: CGSize(width: step, height: step),
            scale: scale, representationTypes: .all)
        let image: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { done in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                    done.resume(returning: thumbnail?.nsImage)
                }
            }
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
        guard let image, !Task.isCancelled else { return nil }
        let pixels = Int(image.size.width * image.size.height * scale * scale * 4)
        cache.setObject(image, forKey: key, cost: pixels)
        return image
    }

    private let icons = NSCache<NSString, NSImage>()

    /// Shown until the thumbnail comes: the file's icon, which draws sharp at
    /// any size. IconCache's are fixed at 16 points for the list.
    func icon(for entry: FileEntry) -> NSImage {
        let key = entry.url.path as NSString
        if let icon = icons.object(forKey: key) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: entry.url.path)
        icons.setObject(icon, forKey: key)
        return icon
    }
}
