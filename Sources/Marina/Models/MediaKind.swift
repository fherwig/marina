import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How the viewer should show a file. Classification is by content type, not by
/// extension — a `.jpg` that is really a PNG still shows, and an extensionless
/// file whose type macOS knows is still handled.
enum MediaKind: Equatable {
    case image
    case movie
    case audio
    case pdf
    case text
    /// Nothing of ours fits: hand it to Quick Look, which covers Office
    /// documents, archives, fonts and whatever else the system knows.
    case other

    init(url: URL) {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            self = .other
            return
        }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        if let type {
            if type.conforms(to: .image) { self = .image; return }
            if type.conforms(to: .movie) || type.conforms(to: .video) { self = .movie; return }
            if type.conforms(to: .audio) { self = .audio; return }
            if type.conforms(to: .pdf) { self = .pdf; return }
            if type.conforms(to: .text) { self = .text; return }
        }
        // Types macOS has no entry for: a Makefile, a .toml, a dotfile. These
        // are text far more often than not, and showing text as text beats
        // handing it to Quick Look, which shows a generic icon.
        self = Self.textExtensions.contains(url.pathExtension.lowercased())
            || Self.textNames.contains(url.lastPathComponent.lowercased())
            ? .text : .other
    }

    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "log", "json", "yaml", "yml", "toml",
        "ini", "cfg", "conf", "csv", "tsv", "swift", "py", "sh", "zsh", "bash",
        "c", "h", "cc", "cpp", "hpp", "m", "mm", "js", "mjs", "ts", "tsx",
        "jsx", "html", "css", "scss", "xml", "plist", "tex", "bib", "sql",
        "rb", "go", "rs", "java", "kt", "pl", "r", "jl", "f90", "f", "for",
        "patch", "diff", "env", "gitignore", "gitattributes", "editorconfig",
    ]

    private static let textNames: Set<String> = [
        "makefile", "dockerfile", "readme", "license", "licence", "changelog",
        "notes", ".gitignore", ".zshrc", ".bashrc", ".profile",
    ]

    /// Text is read into memory in one go, so there has to be a ceiling. A log
    /// of a few megabytes is read to here and marked truncated rather than
    /// freezing the pane.
    static let textByteLimit = 2 * 1024 * 1024
}

enum ImageProbe {
    /// Pixel dimensions without decoding the image.
    static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { return nil }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }
}

enum TextFile {
    /// UTF-8 first, then the two encodings that actually turn up in old files.
    /// A file too big to show is cut off with a line saying so, rather than
    /// taking the pane down with it.
    static func read(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "(cannot read \(url.lastPathComponent))"
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: MediaKind.textByteLimit + 1)) ?? Data()
        let truncated = data.count > MediaKind.textByteLimit
        let body = truncated ? data.prefix(MediaKind.textByteLimit) : data
        let text = String(data: body, encoding: .utf8)
            ?? String(data: body, encoding: .isoLatin1)
            ?? String(data: body, encoding: .macOSRoman)
            ?? "(not text)"
        return truncated ? text + "\n\n… truncated at 2 MB …\n" : text
    }
}
