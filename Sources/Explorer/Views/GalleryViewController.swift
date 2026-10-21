import AppKit
import Quartz
import AVKit
import VisionKit
import ImageIO
import UniformTypeIdentifiers
import ExplorerKit

/// Gallery view: large preview of the selected item over a horizontal thumbnail strip.
final class GalleryViewController: NSViewController, FileViewing, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var state: BrowserState!
    weak var host: BrowserWindowController?

    private let strip = FileCollectionView()
    private let stripScroll = NSScrollView()
    let preview = ZoomablePreview()
    private var items: [FileItem] = []
    private var suppress = false

    override func loadView() {
        let root = NSView()
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 74, height: 74)
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        strip.collectionViewLayout = layout
        strip.dataSource = self
        strip.delegate = self
        strip.isSelectable = true
        strip.allowsMultipleSelection = true
        strip.backgroundColors = [.clear]
        strip.register(GalleryThumb.self, forItemWithIdentifier: GalleryThumb.id)
        strip.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        strip.registerForDraggedTypes(DropIn.types)
        stripScroll.documentView = strip
        stripScroll.hasHorizontalScroller = true
        stripScroll.autohidesScrollers = true
        stripScroll.drawsBackground = false
        [preview, stripScroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: root.topAnchor),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: stripScroll.topAnchor),
            stripScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stripScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stripScroll.heightAnchor.constraint(equalToConstant: 92),
        ])
        view = root
    }

    func reloadItems() {
        guard isViewLoaded else { return }
        items = state.items
        suppress = true
        strip.reloadData()
        suppress = false
        if state.selection.isEmpty, let first = items.first(where: { !$0.isFolder }) ?? items.first {
            state.selection = [first]
        }
        syncSelection()
    }

    func syncSelection() {
        let ids = Set(state.selection.map(\.id))
        let set = Set(items.enumerated().filter { ids.contains($0.element.id) }.map { IndexPath(item: $0.offset, section: 0) })
        if set != strip.selectionIndexPaths {
            suppress = true
            strip.selectionIndexPaths = set
            suppress = false
            if let f = set.min() { strip.scrollToItems(at: [f], scrollPosition: .centeredHorizontally) }
        }
        preview.liveTextEnabled = state.options.liveText
        preview.show(state.selection.first, state: state)
    }

    func focus() { view.window?.makeFirstResponder(strip) }
    func beginRename(_ url: URL) { host?.renameViaPrompt(url) }
    func setZoom(_ delta: Int) { preview.zoom(by: delta > 0 ? 1.25 : 0.8) }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let t = cv.makeItem(withIdentifier: GalleryThumb.id, for: ip) as! GalleryThumb
        t.configure(items[ip.item], state: state)
        return t
    }
    func collectionView(_ cv: NSCollectionView, didSelectItemsAt ip: Set<IndexPath>) { changed() }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ip: Set<IndexPath>) { changed() }
    private func changed() {
        guard !suppress else { return }
        state.selection = strip.selectionIndexPaths.sorted().map { items[$0.item] }
    }
    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }
    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? { DragOut.writer(for: items[ip.item], state: state) }
    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo, proposedIndexPath ip: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        op.pointee = .before
        return DropIn.validate(info, dest: state.isArchive ? nil : state.currentDirectory, state: state)
    }
    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        DropIn.perform(info, dest: state.currentDirectory, state: state, window: view.window)
    }

    // Image edits (also used by the Info panel)
    func transform(_ t: ImageTransform) {
        guard let it = state.selection.first, it.isImage, it.archivePath == nil else { return }
        do {
            try ImageEditor.apply(t, to: it.url)
            ThumbnailStore.shared.clearCache()
            state.softReload()
            preview.show(it, state: state, force: true)
        } catch {
            Alerts.error("Error transforming image", error.localizedDescription, window: view.window)
        }
    }
}

final class GalleryThumb: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("GalleryThumb")
    private var rid: String?
    override func loadView() {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 4
        iv.layer?.borderWidth = 0
        view = iv
        imageView = iv
    }
    func configure(_ it: FileItem, state: BrowserState) {
        rid = it.id
        imageView?.image = ThumbnailStore.icon(for: it, size: 64)
        if state.options.showThumbnails, it.archivePath == nil {
            let id = it.id
            ThumbnailStore.shared.thumbnail(for: it, size: 64, scale: 2, folderStyle: Preferences.shared.folderThumbnails) { [weak self] img in
                if self?.rid == id { self?.imageView?.image = img }
            }
        }
        update()
    }
    override var isSelected: Bool { didSet { update() } }
    private func update() {
        view.layer?.borderWidth = isSelected ? 3 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}

enum GalleryBackground: Int { case transparent, white, black }

/// Zoomable image preview with Quick Look / AV fallback for non-images.
final class ZoomablePreview: NSView {
    private let scroll = NSScrollView()
    private let imageView = NSImageView()
    private var qlView: QLPreviewView?
    private var player: AVPlayerView?
    private var overlay: NSView?
    private var currentURL: URL?
    var lockZoom = false
    var liveTextEnabled = false
    var background: GalleryBackground = .transparent { didSet { applyBackground() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 20
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = imageView
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: FileItem?, state: BrowserState, force: Bool = false) {
        guard let item else { clear(); return }
        if item.url == currentURL && !force { return }
        currentURL = item.url
        qlView?.removeFromSuperview(); qlView = nil
        player?.removeFromSuperview(); player?.player?.pause(); player = nil
        overlay?.removeFromSuperview(); overlay = nil

        var fileURL = item.url
        if let inner = item.archivePath, let a = state.archive {
            guard !item.isDirectory, let tmp = try? a.extractToTemp([inner]) else { clear(); return }
            fileURL = tmp.appendingPathComponent(inner)
        }
        if item.isImage, let img = NSImage(contentsOf: fileURL) {
            scroll.isHidden = false
            let px = img.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? img.size
            img.size = px
            imageView.image = img
            imageView.frame = NSRect(origin: .zero, size: px)
            applyBackground()
            if !lockZoom { fit() }
            if liveTextEnabled { addLiveText(img) }
        } else if item.isMovie || item.isAudio {
            scroll.isHidden = true
            let p = AVPlayerView()
            p.player = AVPlayer(url: fileURL)
            p.controlsStyle = .floating
            p.translatesAutoresizingMaskIntoConstraints = false
            addSubview(p)
            pin(p)
            player = p
        } else {
            scroll.isHidden = true
            guard let q = QLPreviewView(frame: bounds, style: .normal) else { return }
            q.translatesAutoresizingMaskIntoConstraints = false
            q.previewItem = fileURL as NSURL
            addSubview(q)
            pin(q)
            qlView = q
        }
    }

    private func pin(_ v: NSView) {
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func clear() {
        currentURL = nil
        imageView.image = nil
        qlView?.removeFromSuperview(); qlView = nil
        player?.removeFromSuperview(); player = nil
    }

    func fit() {
        guard let img = imageView.image, img.size.width > 0 else { return }
        layoutSubtreeIfNeeded()
        let k = min(bounds.width / img.size.width, bounds.height / img.size.height, 1)
        scroll.magnification = max(scroll.minMagnification, k)
    }

    func zoom(by f: CGFloat) { scroll.magnification = scroll.magnification * f }
    var zoomPercent: Int { Int(scroll.magnification * 100) }

    override func layout() {
        super.layout()
        if !lockZoom, imageView.image != nil, qlView == nil { fit() }
    }

    private func applyBackground() {
        switch background {
        case .transparent: imageView.layer?.backgroundColor = nil
        case .white: imageView.layer?.backgroundColor = NSColor.white.cgColor
        case .black: imageView.layer?.backgroundColor = NSColor.black.cgColor
        }
    }

    private func addLiveText(_ img: NSImage) {
        guard #available(macOS 13.0, *), ImageAnalyzer.isSupported else { return }
        let ov = ImageAnalysisOverlayView()
        ov.translatesAutoresizingMaskIntoConstraints = false
        ov.preferredInteractionTypes = .automatic
        ov.trackingImageView = imageView
        imageView.addSubview(ov)
        NSLayoutConstraint.activate([
            ov.topAnchor.constraint(equalTo: imageView.topAnchor), ov.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            ov.leadingAnchor.constraint(equalTo: imageView.leadingAnchor), ov.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
        ])
        overlay = ov
        Task {
            let analyzer = ImageAnalyzer()
            let config = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            if let a = try? await analyzer.analyze(img, orientation: .up, configuration: config) {
                await MainActor.run { ov.analysis = a }
            }
        }
    }
}

enum ImageTransform { case rotateCW, rotateCCW, flipH, flipV }

/// Lossless-ish image rewrite via ImageIO: applies the transform to pixels and keeps metadata.
enum ImageEditor {
    static func apply(_ t: ImageTransform, to url: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw OpError.message("Not an Image") }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        // Bake orientation in: we write pixels upright and reset the tag.
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        var ci = CIImage(cgImage: img).oriented(forExifOrientation: Int32(orientation))
        switch t {
        case .rotateCW: ci = ci.oriented(.right)
        case .rotateCCW: ci = ci.oriented(.left)
        case .flipH: ci = ci.oriented(.upMirrored)
        case .flipV: ci = ci.oriented(.downMirrored)
        }
        let ctx = CIContext()
        guard let out = ctx.createCGImage(ci, from: ci.extent) else { throw OpError.message("Error transforming image") }
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff[kCGImagePropertyTIFFOrientation] = 1; props[kCGImagePropertyTIFFDictionary] = tiff }
        props[kCGImagePropertyPixelWidth] = out.width
        props[kCGImagePropertyPixelHeight] = out.height
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { throw OpError.message("Error saving file") }
        props[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(dst, out, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw OpError.message("Error saving file") }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
