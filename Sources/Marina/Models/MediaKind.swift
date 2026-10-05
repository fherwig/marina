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
    /// Word and its relatives, read natively by AppKit.
    case document
    /// Workbooks, read by SheetJS in the viewer page.
    case spreadsheet
    case text
    /// Nothing of ours fits: hand it to Quick Look, which covers Office
    /// documents, archives, fonts and whatever else the system knows.
    case other

    init(url: URL) {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            self = .other
            return
        }
        // By extension, and FIRST: RTF conforms to public.text, so the type
        // checks below would show a .rtf as its raw markup.
        let ext = url.pathExtension.lowercased()
        if Self.documentExtensions.contains(ext) { self = .document; return }
        if Self.spreadsheetExtensions.contains(ext) { self = .spreadsheet; return }
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

    /// What NSAttributedString reads natively: Word old and new, OpenDocument
    /// text, RTF. No library, and measured at 15–45 ms for a 39 000-character
    /// .docx once warm.
    static let documentExtensions: Set<String> = ["docx", "doc", "odt", "rtf", "rtfd", "wordml"]

    /// What SheetJS reads. CSV and TSV are deliberately not here: the raw text
    /// is often what you want to see of those, and the plain view handles them.
    static let spreadsheetExtensions: Set<String> = ["xlsx", "xlsm", "xls", "ods"]

    /// A workbook is handed to the page in one piece (base64); past this it is
    /// opened in its own app instead of being previewed.
    static let spreadsheetByteLimit = 20 * 1024 * 1024

    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "log", "json", "yaml", "yml", "toml",
        "ini", "cfg", "conf", "csv", "tsv", "swift", "py", "sh", "zsh", "bash",
        "c", "h", "cc", "cpp", "hpp", "m", "mm", "js", "mjs", "ts", "tsx",
        "jsx", "html", "css", "scss", "xml", "plist", "tex", "bib", "sql",
        "rb", "go", "rs", "java", "kt", "pl", "r", "jl", "f90", "f", "for",
        "patch", "diff", "env", "gitignore", "gitattributes", "editorconfig",
        // code the viewer highlights, whose extensions macOS has no type for
        "f77", "f95", "f03", "f08", "hh", "hxx", "cxx", "sty", "cls", "pyw",
        "cjs", "ipynb", "mk",
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

/// What sort of text a `.text` file is, for the viewer: markdown is rendered,
/// code is highlighted, and everything else — logs, CSV, notes — stays in the
/// fast plain view, which also copes with files far larger than a web page
/// should be asked to lay out.
enum TextFlavor: Equatable {
    case markdown
    /// Carries the Prism language name the page highlights it with.
    case code(String)
    case plain

    init(url: URL) {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { self = .markdown; return }
        if name == "makefile" || name == "gnumakefile" || ext == "mk" { self = .code("makefile"); return }
        if let language = Self.languages[ext] { self = .code(language); return }
        self = .plain
    }

    /// Extension → Prism language. Every name here must be one viewer.html
    /// loads; a missing grammar shows the file unhighlighted, not an error.
    private static let languages: [String: String] = [
        "swift": "swift",
        "py": "python", "pyw": "python",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "json": "json", "ipynb": "json",
        "yaml": "yaml", "yml": "yaml",
        "toml": "toml",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "c": "c", "h": "c",
        "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
        "tex": "latex", "sty": "latex", "cls": "latex",
        "html": "markup", "htm": "markup", "xml": "markup", "plist": "markup",
        "css": "css", "scss": "css",
        "diff": "diff", "patch": "diff",
        "f90": "fortran", "f95": "fortran", "f03": "fortran", "f08": "fortran",
        "f": "fortran-fixed", "for": "fortran-fixed", "f77": "fortran-fixed",
    ]
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
