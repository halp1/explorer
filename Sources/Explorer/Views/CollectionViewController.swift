import AppKit
import ExplorerKit

/// Icons view and List view (column-flow) on NSCollectionView, with group sections.
final class CollectionViewController: NSViewController, FileViewing, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout, NSTextFieldDelegate {
    enum Mode { case icons, list }
    var state: BrowserState!
    weak var host: BrowserWindowController?
    let mode: Mode

    let collection = FileCollectionView()
    private let scroll = NSScrollView()
    private var sections: [ItemGroup] = []
    private var suppressSelection = false
    private var renaming: URL?

    init(mode: Mode) { self.mode = mode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    var iconSize: CGFloat { mode == .icons ? CGFloat(state?.options.iconSize ?? 64) : 16 + CGFloat(Preferences.shared.fontSizeDelta) }

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.register(CollectionItem.self, forItemWithIdentifier: CollectionItem.id)
        collection.register(GroupHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: GroupHeaderView.id)
        collection.registerForDraggedTypes(DropIn.types)
        collection.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)
        collection.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        collection.owner = self
        scroll.documentView = collection
        scroll.hasVerticalScroller = mode == .icons
        scroll.hasHorizontalScroller = mode == .list
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll
        configureLayout()
    }

    private func configureLayout() {
        guard let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let p = Preferences.shared
        switch mode {
        case .icons:
            layout.scrollDirection = .vertical
            let w = max(iconSize + 24, 90)
            let traits: CGFloat = (state?.options.showTraits ?? false) ? 14 : 0
            layout.itemSize = NSSize(width: w, height: iconSize + 40 + traits)
            layout.minimumInteritemSpacing = CGFloat(p.iconSpacing)
            layout.minimumLineSpacing = CGFloat(p.iconSpacing)
            layout.sectionInset = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        case .list:
            layout.scrollDirection = .horizontal
            let h = 18 + CGFloat(p.fontSizeDelta) + CGFloat(p.listSpacing)
            let width: CGFloat
            if p.listLayout == .fixed {
                width = 240
            } else {
                let longest = state?.items.map { ItemStyle.displayName($0).count }.max() ?? 20
                width = min(420, max(160, CGFloat(longest) * 7 + 40))
            }
            layout.itemSize = NSSize(width: width, height: h)
            layout.minimumInteritemSpacing = 0
            layout.minimumLineSpacing = 8
            layout.sectionInset = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        }
        layout.headerReferenceSize = (state?.options.grouping ?? .none) == .none ? .zero : NSSize(width: 200, height: mode == .icons ? 28 : 22)
        layout.invalidateLayout()
    }

    func reloadItems() {
        guard isViewLoaded else { return }
        sections = state.options.grouping == .none ? [ItemGroup(id: "all", title: "", order: 0, items: state.items)] : state.groups
        configureLayout()
        suppressSelection = true
        collection.reloadData()
        suppressSelection = false
        syncSelection()
        if let r = state.pendingRename { state.pendingRename = nil; beginRename(r) }
    }

    func syncSelection() {
        let ids = Set(state.selection.map(\.id))
        var set = Set<IndexPath>()
        for (s, g) in sections.enumerated() { for (i, it) in g.items.enumerated() where ids.contains(it.id) { set.insert(IndexPath(item: i, section: s)) } }
        if set != collection.selectionIndexPaths {
            suppressSelection = true
            collection.selectionIndexPaths = set
            suppressSelection = false
            if let f = set.min() { collection.scrollToItems(at: [f], scrollPosition: .nearestHorizontalEdge) }
        }
    }

    func focus() { view.window?.makeFirstResponder(collection) }

    func setZoom(_ delta: Int) {
        guard mode == .icons else { return }
        let presets = [32, 48, 64, 96, 128, 192, 256, 384, 512]
        let cur = state.options.iconSize
        let idx = presets.firstIndex { $0 >= cur } ?? 2
        let next = presets[max(0, min(presets.count - 1, idx + delta))]
        state.options.iconSize = next
        reloadItems()
    }

    func item(at ip: IndexPath) -> FileItem? {
        guard sections.indices.contains(ip.section), sections[ip.section].items.indices.contains(ip.item) else { return nil }
        return sections[ip.section].items[ip.item]
    }

    var flatNames: [(IndexPath, String)] {
        sections.enumerated().flatMap { s, g in g.items.enumerated().map { (IndexPath(item: $0, section: s), ItemStyle.displayName($1)) } }
    }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].items.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let ci = cv.makeItem(withIdentifier: CollectionItem.id, for: ip) as! CollectionItem
        guard let it = item(at: ip) else { return ci }
        ci.configure(it, state: state, iconSize: iconSize, list: mode == .list, bold: Preferences.shared.boldRecentChanges && state.recentlyChanged.contains(it.id))
        ci.nameField.delegate = self
        return ci
    }

    func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize {
        guard state.options.grouping != .none, sections.indices.contains(section), !sections[section].title.isEmpty else { return .zero }
        return NSSize(width: cv.bounds.width, height: mode == .icons ? 28 : 22)
    }

    func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at ip: IndexPath) -> NSView {
        let v = cv.makeSupplementaryView(ofKind: kind, withIdentifier: GroupHeaderView.id, for: ip) as! GroupHeaderView
        v.label.stringValue = "\(sections[ip.section].title)  (\(sections[ip.section].items.count))"
        return v
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }

    private func selectionChanged() {
        guard !suppressSelection else { return }
        state.selection = collection.selectionIndexPaths.sorted().compactMap(item(at:))
    }

    func doubleClicked(_ ip: IndexPath) {
        guard let it = item(at: ip) else { return }
        host?.open([it], newWindow: false)
    }

    // MARK: Rename

    func beginRename(_ url: URL) {
        for (s, g) in sections.enumerated() {
            if let i = g.items.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                let ip = IndexPath(item: i, section: s)
                collection.scrollToItems(at: [ip], scrollPosition: .centeredVertically)
                collection.selectionIndexPaths = [ip]
                collection.layoutSubtreeIfNeeded()
                guard let ci = collection.item(at: ip) as? CollectionItem else { return }
                renaming = url
                ci.beginEditing(name: g.items[i].name, isFolder: g.items[i].isFolder)
                return
            }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let url = renaming else { return }
        renaming = nil
        field.isEditable = false
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        if movement == NSTextMovement.cancel.rawValue { reloadItems(); return }
        host?.commitRename(url, to: field.stringValue)
        focus()
    }

    // MARK: Drag & drop

    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
        item(at: ip).flatMap { DragOut.writer(for: $0, state: state) }
    }

    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo, proposedIndexPath ip: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if op.pointee == .on, let it = item(at: ip.pointee as IndexPath), it.isDirectory {
            if state.isArchive { return (state.archive?.isWritable ?? false) ? .copy : [] }
            return DropIn.validate(info, dest: it.url, state: state)
        }
        op.pointee = .before
        return DropIn.validate(info, dest: state.isArchive ? nil : state.currentDirectory, state: state)
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath ip: IndexPath, dropOperation op: NSCollectionView.DropOperation) -> Bool {
        if op == .on, let it = item(at: ip), it.isDirectory {
            return DropIn.perform(info, dest: it.url, archiveInner: it.archivePath, state: state, window: view.window)
        }
        return DropIn.perform(info, dest: state.currentDirectory, state: state, window: view.window)
    }

    func menuFor(_ ip: IndexPath?) -> NSMenu? {
        if let ip {
            if !collection.selectionIndexPaths.contains(ip) { collection.selectionIndexPaths = [ip]; selectionChanged() }
        } else {
            collection.deselectAll(nil); selectionChanged()
        }
        return host?.contextMenu(for: state.selection, inTree: false)
    }
}

final class FileCollectionView: NSCollectionView {
    weak var owner: CollectionViewController?
    private let typeSelect = TypeSelect()

    override func menu(for event: NSEvent) -> NSMenu? {
        let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        return owner?.menuFor(ip)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) { owner?.doubleClicked(ip) }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), owner?.mode == .icons {
            if abs(event.scrollingDeltaY) > 2 { owner?.setZoom(event.scrollingDeltaY > 0 ? 1 : -1) }
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        if owner?.mode == .icons, abs(event.magnification) > 0.05 { owner?.setZoom(event.magnification > 0 ? 1 : -1) }
    }

    override func keyDown(with event: NSEvent) {
        if let host = owner?.host, host.handleKey(event) { return }
        if let ch = event.characters, !ch.isEmpty, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           ch.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || CharacterSet.punctuationCharacters.contains($0) }),
           let owner {
            let names = owner.flatNames
            if let idx = typeSelect.match(ch, in: names.map(\.1)) {
                selectionIndexPaths = [names[idx].0]
                owner.collectionView(self, didSelectItemsAt: [names[idx].0])
                scrollToItems(at: [names[idx].0], scrollPosition: .nearestHorizontalEdge)
                return
            }
        }
        super.keyDown(with: event)
    }
}

final class CollectionItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("CollectionItem")
    let icon = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    let traits = NSTextField(labelWithString: "")
    private let bg = NSView()
    private var representedID: String?
    private var isList = false
    private var constraintsSet: [NSLayoutConstraint] = []

    override func loadView() {
        view = NSView()
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 5
        [bg, icon, nameField, traits].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        icon.imageScaling = .scaleProportionallyUpOrDown
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        traits.font = .systemFont(ofSize: 10)
        traits.textColor = .systemBlue
        traits.alignment = .center
        imageView = icon
        textField = nameField
    }

    func configure(_ it: FileItem, state: BrowserState, iconSize: CGFloat, list: Bool, bold: Bool) {
        representedID = it.id
        isList = list
        NSLayoutConstraint.deactivate(constraintsSet)
        if list {
            constraintsSet = [
                bg.leadingAnchor.constraint(equalTo: view.leadingAnchor), bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                bg.topAnchor.constraint(equalTo: view.topAnchor), bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3), icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: iconSize), icon.heightAnchor.constraint(equalToConstant: iconSize),
                nameField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5), nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
                nameField.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ]
            nameField.alignment = .left
            nameField.maximumNumberOfLines = 1
            nameField.lineBreakMode = ItemStyle.truncation(Preferences.shared.truncateFiles)
            traits.isHidden = true
        } else {
            constraintsSet = [
                icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 4), icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                icon.widthAnchor.constraint(equalToConstant: iconSize), icon.heightAnchor.constraint(equalToConstant: iconSize),
                bg.centerXAnchor.constraint(equalTo: icon.centerXAnchor), bg.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
                bg.widthAnchor.constraint(equalTo: icon.widthAnchor, constant: 8), bg.heightAnchor.constraint(equalTo: icon.heightAnchor, constant: 8),
                nameField.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 5),
                nameField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2), nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                traits.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 0),
                traits.leadingAnchor.constraint(equalTo: view.leadingAnchor), traits.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ]
            nameField.alignment = .center
            nameField.maximumNumberOfLines = 2
            nameField.lineBreakMode = .byTruncatingMiddle
            nameField.cell?.truncatesLastVisibleLine = true
            traits.isHidden = !state.options.showTraits
            traits.stringValue = Self.traits(it)
        }
        NSLayoutConstraint.activate(constraintsSet)
        let s = NSMutableAttributedString(string: ItemStyle.displayName(it), attributes: [
            .font: ItemStyle.font(list ? 13 : 12, bold: bold),
            .foregroundColor: it.isHidden ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        s.append(ItemStyle.badges(it))
        nameField.attributedStringValue = s
        icon.image = ThumbnailStore.icon(for: it, size: iconSize)
        icon.alphaValue = it.isHidden ? 0.5 : 1
        if state.options.showThumbnails, it.archivePath == nil, !it.isFolder || Preferences.shared.folderThumbnails != .systemIcon {
            if let c = ThumbnailStore.shared.cached(it, size: iconSize) { icon.image = c } else {
                let id = it.id
                ThumbnailStore.shared.thumbnail(for: it, size: iconSize, scale: 2, folderStyle: Preferences.shared.folderThumbnails) { [weak self] img in
                    if self?.representedID == id { self?.icon.image = img }
                }
            }
        }
        updateSelection()
    }

    /// Finder-style "item info": pixel size for images, item count for folders, duration for media.
    static func traits(_ it: FileItem) -> String {
        if it.isFolder, it.archivePath == nil {
            if let n = FileItemLoader.childCount(it.url, includeHidden: false) { return String(format: n == 1 ? "%lld item" : "%lld items", n) }
            return ""
        }
        if it.isImage, let src = CGImageSourceCreateWithURL(it.url as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            return "\(w) × \(h)"
        }
        return SizeFormat.string(it.size)
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }

    private func updateSelection() {
        let on = isSelected || highlightState == .forSelection || highlightState == .asDropTarget
        bg.layer?.backgroundColor = on ? NSColor.selectedContentBackgroundColor.withAlphaComponent(isList ? 1 : 0.25).cgColor : nil
        if isList {
            nameField.textColor = on ? .alternateSelectedControlTextColor : nil
        }
    }

    func beginEditing(name: String, isFolder: Bool) {
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.stringValue = name
        nameField.drawsBackground = true
        nameField.backgroundColor = .textBackgroundColor
        view.window?.makeFirstResponder(nameField)
        if let ed = nameField.currentEditor() {
            let stem = isFolder ? name : (name as NSString).deletingPathExtension
            ed.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        }
    }
}

final class GroupHeaderView: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("GroupHeader")
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .boldSystemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let line = NSBox(); line.boxType = .separator; line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8), line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
