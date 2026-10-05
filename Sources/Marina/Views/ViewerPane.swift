import SwiftUI
import AppKit
import AVKit
import PDFKit
import QuickLookUI

/// The ⌘3 pane: whatever the file list has selected, shown. It takes the slot a
/// second file pane would take, because the two are alternatives — ⌘2 is "the
/// same folder twice", ⌘3 is "this folder, and a look at what I am on".
///
/// The keyboard deliberately stays in the file list: arrowing down a folder of
/// photos and watching them go past is the whole point, so the viewer has no
/// focus of its own and no keys to learn. Media controls are the system's.
struct ViewerPane: View {
    @ObservedObject var tab: TabState
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
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }

    /// Size, and for an image its pixel dimensions — the two things you want to
    /// know about the file you are looking at.
    private var caption: String? {
        guard let shown, let entry = pane.selectedEntries.first else { return nil }
        var parts: [String] = []
        if MediaKind(url: shown) == .image, let size = ImageProbe.pixelSize(of: shown) {
            parts.append("\(Int(size.width)) × \(Int(size.height))")
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
                ImageViewer(url: url)
            case .movie, .audio:
                MediaViewer(url: url)
            case .pdf:
                PDFViewer(url: url)
            case .text:
                TextViewer(url: url)
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

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.allowsCutCopyPaste = false
        view.imageAlignment = .alignCenter
        load(into: view)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) { load(into: view) }

    private func load(into view: NSImageView) {
        view.image = NSImage(contentsOf: url)
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
