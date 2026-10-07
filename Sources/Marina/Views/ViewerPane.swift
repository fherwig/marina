import SwiftUI
import AppKit
import AVKit
import PDFKit
import QuickLookUI
import WebKit

/// The ⌘3 pane: whatever the file list has selected, shown. It takes the slot a
/// second file pane would take, because the two are alternatives — ⌘2 is "the
/// same folder twice", ⌘3 is "this folder, and a look at what I am on".
///
/// The keyboard deliberately stays in the file list: arrowing down a folder of
/// photos and watching them go past is the whole point, so the viewer has no
/// focus of its own and no keys to learn. Media controls are the system's.
struct ViewerPane: View {
    @ObservedObject var tab: TabState
    @AppStorage("marina.viewerImageZoom") private var imageZoom = ImageZoom.fit
    @ObservedObject var pane: PaneState

    /// What is actually on screen. Separate from the selection so the pane can
    /// lag a beat behind fast arrowing instead of loading every file passed
    /// over on the way down.
    @State private var shown: URL?

    private var selected: URL? {
        guard pane.selection.count == 1 else { return nil }
        return pane.selectedEntries.first?.url
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .task(id: selected) {
            // a held-down arrow key walks a folder in milliseconds; waiting out
            // the walk means one file is loaded instead of forty
            if shown != nil {
                try? await Task.sleep(for: .milliseconds(120))
                if Task.isCancelled { return }
            }
            shown = selected
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(shown?.lastPathComponent ?? "Viewer")
                .font(.system(size: 12))
                .foregroundStyle(shown == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Button {
                tab.toggleViewer()
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close Viewer (⌘3)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var symbol: String {
        guard let shown else { return "eye" }
        switch MediaKind(url: shown) {
        case .image: return "photo"
        case .movie: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }

    /// Size, and for an image its pixel dimensions — the two things you want to
    /// know about the file you are looking at.
    private var caption: String? {
        guard let shown, let entry = pane.selectedEntries.first else { return nil }
        var parts: [String] = []
        if MediaKind(url: shown) == .image {
            if let size = ImageProbe.pixelSize(of: shown) {
                parts.append("\(Int(size.width)) × \(Int(size.height))")
            }
            parts.append(imageZoom.label)
        }
        if !entry.isDirectory { parts.append(entry.displaySize) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if let url = shown {
            switch MediaKind(url: url) {
            case .image:
                ImageViewer(url: url, zoom: imageZoom) { imageZoom = imageZoom.next }
            case .movie, .audio:
                MediaViewer(url: url)
            case .pdf:
                PDFViewer(url: url)
            case .document:
                DocumentViewer(url: url)
            case .spreadsheet:
                PageViewer(url: url)
            case .text:
                switch TextFlavor(url: url) {
                case .plain:
                    TextViewer(url: url)
                case .markdown, .code:
                    // one WebKit page for both, so arrowing between a note
                    // and a script swaps content instead of rebuilding WebKit
                    PageViewer(url: url)
                }
            case .other:
                QuickLookViewer(url: url)
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(pane.selection.count > 1
                 ? "\(pane.selection.count) items selected"
                 : "Select a file to see it here")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Image

/// NSImageView rather than SwiftUI's Image: it animates GIFs, reads everything
/// ImageIO knows (HEIC, RAW, TIFF) and scales without a trip through SwiftUI's
/// layout on every selection change.
private struct ImageViewer: NSViewRepresentable {
    let url: URL
    let zoom: ImageZoom
    /// A click on the image: the pane steps to the next zoom.
    let onClick: () -> Void

    func makeNSView(context: Context) -> ZoomingImageView {
        let view = ZoomingImageView()
        view.onClick = onClick
        view.show(url, zoom: zoom)
        return view
    }

    func updateNSView(_ view: ZoomingImageView, context: Context) {
        view.onClick = onClick
        view.show(url, zoom: zoom)
    }
}

/// How an image fills the pane. A click steps through them in this order, and
/// the choice is remembered from one image to the next — arrowing through a
/// folder of scans at "fit width" should stay at "fit width".
enum ImageZoom: String, CaseIterable {
    /// The whole image, as large as the pane allows.
    case fit
    /// As wide as the pane; scroll down through a tall one.
    case fitWidth
    /// One image pixel to one screen pixel; scroll both ways.
    case actual

    var next: ImageZoom {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var label: String {
        switch self {
        case .fit: return "fit"
        case .fitWidth: return "fit width"
        case .actual: return "actual size"
        }
    }
}

/// A scroll view whose document is the image, sized for the zoom and centred
/// when it is smaller than the pane. NSImageView alone can only scale to fit;
/// "as wide as the pane" and "one pixel per pixel" both need the image larger
/// than the view, which is what the scroll view is for.
final class ZoomingImageView: NSScrollView {
    var onClick: (() -> Void)?
    private let canvas = FlippedView()
    private let imageView = NSImageView()
    private var url: URL?
    private var zoom: ImageZoom = .fit
    /// The image's true pixel size, which "actual size" is measured in.
    private var pixels = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        imageView.imageScaling = .scaleAxesIndependently   // the frame carries the aspect
        imageView.animates = true                          // GIFs
        imageView.allowsCutCopyPaste = false
        canvas.addSubview(imageView)
        documentView = canvas
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        canvas.addGestureRecognizer(click)
        toolTip = "Click to switch: fit → fit width → actual size"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ url: URL, zoom: ImageZoom) {
        let newImage = url != self.url
        guard newImage || zoom != self.zoom else { return }
        if newImage {
            self.url = url
            let image = NSImage(contentsOf: url)
            imageView.image = image
            pixels = ImageProbe.pixelSize(of: url)
                ?? image?.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
                ?? image?.size ?? .zero
        }
        self.zoom = zoom
        needsLayout = true
        layoutSubtreeIfNeeded()
        // start at the top left, as a document does
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    override func layout() {
        super.layout()
        let pane = contentView.bounds.size
        guard pixels.width > 0, pixels.height > 0, pane.width > 0, pane.height > 0 else {
            canvas.frame = NSRect(origin: .zero, size: pane)
            imageView.frame = canvas.bounds
            return
        }
        let aspect = pixels.height / pixels.width
        let size: CGSize
        switch zoom {
        case .fit:
            let scale = min(pane.width / pixels.width, pane.height / pixels.height)
            size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        case .fitWidth:
            size = CGSize(width: pane.width, height: pane.width * aspect)
        case .actual:
            let screen = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            size = CGSize(width: pixels.width / screen, height: pixels.height / screen)
        }
        // the canvas is at least the pane, so a small image sits in the middle
        // instead of the top-left corner
        let canvasSize = CGSize(width: max(size.width, pane.width), height: max(size.height, pane.height))
        canvas.frame = NSRect(origin: .zero, size: canvasSize)
        imageView.frame = NSRect(x: (canvasSize.width - size.width) / 2,
                                 y: (canvasSize.height - size.height) / 2,
                                 width: size.width, height: size.height)
    }

    @objc private func clicked() { onClick?() }

    /// Top-left origin, so scrolling starts at the top of a tall image.
    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

// MARK: - Video and audio

/// Paused, with the system's controls. Not autoplay: arrowing through a folder
/// of videos should not start playing sound at you.
private struct MediaViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard (view.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        view.player?.pause()
        view.player = AVPlayer(url: url)
    }

    /// Without this the sound carries on after the pane is gone.
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

// MARK: - PDF

private struct PDFViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document?.documentURL != url else { return }
        view.document = PDFDocument(url: url)
    }
}

// MARK: - Text

private struct TextViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            text.textContainerInset = NSSize(width: 8, height: 8)
            text.drawsBackground = true
            text.backgroundColor = .textBackgroundColor
        }
        fill(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { fill(scroll) }

    private func fill(_ scroll: NSScrollView) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.string = TextFile.read(url)
        view.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}

// MARK: - Markdown and code

/// Markdown rendered — headings, tables, images, maths through KaTeX, fenced
/// code highlighted — and source files highlighted by language with line
/// numbers. The page is Support/Viewer: markdown-it, KaTeX and Prism from their
/// upstream distributions, plus Marina's own glue and Fortran grammar.
///
/// The page loads once; each file is then handed to it as data, so moving
/// through a folder does not reload WebKit for every file.
private struct PageViewer: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        if let page = Bundle.main.url(forResource: "viewer", withExtension: "html",
                                      subdirectory: "Viewer") {
            // read access to the whole disk, not just the page's folder: a
            // note's images live next to the note, wherever that is. The page
            // runs only Marina's own scripts — markdown-it is set to html:false,
            // so nothing in a file can add one.
            view.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        } else {
            view.loadHTMLString("<p style='font:13px -apple-system;padding:20px'>"
                + "The viewer page is missing from Marina.app (Contents/Resources/Viewer).</p>",
                baseURL: nil)
        }
        context.coordinator.show(url)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.show(url)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        private var loaded = false
        private var shown: URL?
        /// Asked for before the page finished loading: kept until it has.
        private var pending: URL?

        func show(_ url: URL) {
            guard url != shown else { return }
            guard loaded else { pending = url; return }
            shown = url
            render(url)
        }

        private func render(_ url: URL) {
            guard let json = Self.payload(for: url) else { return }
            view?.evaluateJavaScript("marinaRender(\(json))")
        }

        /// What the page is handed. JSON is the escaping: the file goes in as
        /// data, never as code.
        private static func payload(for url: URL) -> String? {
            var payload: [String: String]
            if MediaKind(url: url) == .spreadsheet {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > MediaKind.spreadsheetByteLimit {
                    payload = ["kind": "markdown", "dir": "/", "lang": "",
                               "text": "This workbook is \(size / 1_048_576) MB — too large to preview here. "
                                     + "Open it with ⌘O."]
                } else {
                    let data = (try? Data(contentsOf: url)) ?? Data()
                    payload = ["kind": "sheet", "data": data.base64EncodedString()]
                }
            } else {
                payload = textPayload(for: url)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private static func textPayload(for url: URL) -> [String: String] {
            let flavor = TextFlavor(url: url)
            return [
                "kind": flavor == .markdown ? "markdown" : "code",
                "lang": { if case .code(let language) = flavor { return language }; return "" }(),
                "text": TextFile.read(url),
                "dir": url.deletingLastPathComponent().path,
            ]
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let next = pending { pending = nil; show(next) }
        }

        /// The page itself is the only thing this view ever loads. Anything
        /// else — a clicked link, whatever its navigation type — is cancelled
        /// and handed to the system: a browser for the web, the default app for
        /// a file. Allowing "everything but link clicks" would let any other
        /// kind of navigation carry the viewer off its own page for good.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let target = action.request.url else { decisionHandler(.cancel); return }
            if target.isFileURL, target.lastPathComponent == "viewer.html",
               target.deletingLastPathComponent().lastPathComponent == "Viewer" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            NSWorkspace.shared.open(target)
        }
    }
}

// MARK: - Word documents

/// .docx, .doc, .odt, .rtf through AppKit's own reader: fonts, tables, tab
/// stops and all, with no library. On a white page even in dark mode, as Word
/// and Pages show them — a document carries its own text colours, and black
/// type on the dark text background was unreadable (seen in a snapshot).
///
/// Read off the main thread: steady-state it is 15–45 ms, but the FIRST read
/// in a session warms the importer up for ~2.5 s, and arrowing past a .docx
/// must not freeze the file list for that.
private struct DocumentViewer: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .white
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = true
            text.backgroundColor = .white
            text.textContainerInset = NSSize(width: 18, height: 16)
        }
        context.coordinator.scroll = scroll
        context.coordinator.load(url)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.load(url)
    }

    /// Unchecked because the compiler cannot see the rule that makes it safe:
    /// the background block only reads the file into a NEW string, and every
    /// touch of `scroll` and `wanted` happens on the main queue.
    final class Coordinator: @unchecked Sendable {
        weak var scroll: NSScrollView?
        private var wanted: URL?

        func load(_ url: URL) {
            guard url != wanted else { return }
            wanted = url
            (scroll?.documentView as? NSTextView)?.string = ""
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let read = Fresh(value: (try? NSAttributedString(url: url, options: [:],
                                                                documentAttributes: nil))
                    ?? NSAttributedString(string: "(cannot read \(url.lastPathComponent))"))
                DispatchQueue.main.async {
                    // the selection may have moved on while this was reading
                    guard let self, self.wanted == url,
                          let view = self.scroll?.documentView as? NSTextView else { return }
                    view.textStorage?.setAttributedString(read.value)
                    view.scrollRangeToVisible(NSRange(location: 0, length: 0))
                }
            }
        }
    }

    /// A value made on one thread and handed, untouched, to another.
    private struct Fresh<Value>: @unchecked Sendable { let value: Value }
}

// MARK: - Everything else

/// Quick Look's own view, so Office documents, archives, fonts and the rest
/// still show something rather than nothing.
private struct QuickLookViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
