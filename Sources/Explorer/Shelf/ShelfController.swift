import AppKit
import Combine
import ExplorerKit

/// The Shelf: a flap on the right edge that expands into a list of collected items.
final class ShelfController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var host: BrowserWindowController?
    private let flap = NSButton()
    private let panel = NSView()
    private let table = ShelfTable()
    private var widthConstraint: NSLayoutConstraint!
    private var cancellables: Set<AnyCancellable> = []
    private var entries: [ShelfEntry] { ShelfStore.shared.items }
    private(set) var isOpen = false
    private let removeAfterUse = NSButton(checkboxWithTitle: "Remove items after use", target: nil, action: nil)

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        flap.bezelStyle = .regularSquare
        flap.isBordered = false
        flap.wantsLayer = true
        flap.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        flap.layer?.cornerRadius = 4
        flap.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "Shelf")
        flap.toolTip = "The Shelf is the temporary collection of items from different locations to be used together later. Adding an item to the Shelf does not move it."
        flap.target = self
        flap.action = #selector(toggle)
        let flapDrop = DropTarget { [weak self] urls in ShelfStore.add(urls); self?.open() }
        flapDrop.translatesAutoresizingMaskIntoConstraints = false

        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.layer?.borderWidth = 1
        let header = NSTextField(labelWithString: "Shelf")
        header.font = .boldSystemFont(ofSize: 12)
        let clear = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear the Shelf")!, target: self, action: #selector(clearShelf))
        clear.isBordered = false
        clear.toolTip = "Clear the Shelf"
        let scroll = NSScrollView()
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.rowHeight = 22
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        table.owner = self
        table.doubleAction = #selector(openItem)
        table.target = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let empty = NSTextField(wrappingLabelWithString: "Drag items here\nor select them and press ⌘→")
        empty.alignment = .center
        empty.textColor = .tertiaryLabelColor
        empty.identifier = .init("empty")
        removeAfterUse.target = self
        removeAfterUse.action = #selector(toggleRemove)
        removeAfterUse.controlSize = .small
        removeAfterUse.state = Preferences.shared.removeShelfItemsAfterUse ? .on : .off
        [header, clear, scroll, empty, removeAfterUse].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview($0) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: panel.topAnchor, constant: 6), header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            clear.centerYAnchor.constraint(equalTo: header.centerYAnchor), clear.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: removeAfterUse.topAnchor, constant: -4),
            removeAfterUse.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8), removeAfterUse.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -20),
        ])

        [panel, flap, flapDrop].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        widthConstraint = root.widthAnchor.constraint(equalToConstant: 14)
        NSLayoutConstraint.activate([
            widthConstraint,
            flap.leadingAnchor.constraint(equalTo: root.leadingAnchor), flap.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            flap.widthAnchor.constraint(equalToConstant: 14), flap.heightAnchor.constraint(equalToConstant: 60),
            flapDrop.leadingAnchor.constraint(equalTo: root.leadingAnchor), flapDrop.topAnchor.constraint(equalTo: root.topAnchor),
            flapDrop.bottomAnchor.constraint(equalTo: root.bottomAnchor), flapDrop.widthAnchor.constraint(equalToConstant: 14),
            panel.leadingAnchor.constraint(equalTo: flap.trailingAnchor), panel.topAnchor.constraint(equalTo: root.topAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor), panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        panel.isHidden = true
        view = root
        ShelfStore.shared.$items.receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }.store(in: &cancellables)
        let m = NSMenu()
        m.addItem(Menus.item("Hide Shelf", #selector(hideShelf), target: self))
        view.menu = m
    }

    private func reload() {
        guard isViewLoaded else { return }
        table.reloadData()
        panel.subviews.first { $0.identifier?.rawValue == "empty" }?.isHidden = !entries.isEmpty
        flap.contentTintColor = entries.isEmpty ? .secondaryLabelColor : .controlAccentColor
    }

    @objc func toggle() { isOpen ? close() : open() }

    func open() {
        isOpen = true
        panel.isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; widthConstraint.animator().constant = 260 }
    }

    func close() {
        isOpen = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; widthConstraint.animator().constant = 14 }, completionHandler: { [weak self] in
            if self?.isOpen == false { self?.panel.isHidden = true }
        })
    }

    @objc private func clearShelf() { ShelfStore.shared.items = [] }
    @objc private func toggleRemove() { Preferences.shared.removeShelfItemsAfterUse = removeAfterUse.state == .on }
    @objc private func hideShelf() { Preferences.shared.showShelf = false; NotificationCenter.default.post(name: .viewSettingsChanged, object: nil) }

    var selectedURLs: [URL] { table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].url : nil } }

    @objc private func openItem() {
        guard let u = selectedURLs.first else { return }
        var d: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &d), d.boolValue { host?.state.go(.directory(u)) } else { NSWorkspace.shared.open(u) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let cell = FileCellView(icon: true)
        let u = e.url
        cell.text.stringValue = u?.lastPathComponent ?? (e.path as NSString).lastPathComponent
        cell.text.textColor = u == nil ? .tertiaryLabelColor : .labelColor
        cell.iconView.image = NSWorkspace.shared.icon(forFile: u?.path ?? e.path)
        cell.toolTip = u?.path ?? "Missing: " + e.path
        // Warn about name collisions on the shelf
        let names = entries.compactMap { $0.url?.lastPathComponent }
        if let n = u?.lastPathComponent, names.filter({ $0 == n }).count > 1 {
            cell.toolTip = "Another shelved item has this name; one of them will be renamed."
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { entries[row].url as NSURL? }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        info.draggingSource as? NSTableView === table ? [] : .link
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        ShelfStore.add(DropIn.urls(info)); return true
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .move, Preferences.shared.removeShelfItemsAfterUse {
            ShelfStore.remove((session.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? [])
        }
    }

    func menu(forRow row: Int) -> NSMenu? {
        if row >= 0, !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        let urls = selectedURLs
        guard !urls.isEmpty else { return view.menu }
        let m = NSMenu()
        m.addItem(Menus.item("Remove from Shelf", #selector(removeSelected), target: self))
        m.addItem(.separator())
        m.addItem(Menus.item("Open", #selector(openItem), target: self))
        let ow = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        ow.submenu = OpenWithMenu.build(for: urls.compactMap { FileItemLoader.load($0) })
        for i in ow.submenu!.items { i.target = self; if i.action == #selector(BrowserWindowController.openWithApp(_:)) { i.action = #selector(openWith(_:)) } }
        m.addItem(ow)
        m.addItem(Menus.item("Batch Rename...", #selector(batchRename), target: self))
        let comp = NSMenuItem(title: "Compress to", action: nil, keyEquivalent: "")
        comp.submenu = Menus.compressMenu()
        for i in comp.submenu!.items { i.target = self; i.action = i.action.map { _ in #selector(compressTo(_:)) } }
        m.addItem(comp)
        m.addItem(Menus.item("Quick Look", #selector(shelfQuickLook), target: self))
        m.addItem(.separator())
        m.addItem(Menus.item("Cut via Trash", #selector(cutItems), target: self))
        m.addItem(Menus.item("Copy", #selector(copyItems), target: self))
        m.addItem(Menus.item("Copy as Path", #selector(copyPaths), target: self))
        let share = NSMenuItem(title: "Share", action: nil, keyEquivalent: ""); share.submenu = Menus.shareMenu(urls)
        m.addItem(share)
        return m
    }

    @objc private func removeSelected() { ShelfStore.remove(selectedURLs) }
    @objc private func openWith(_ s: NSMenuItem) { if let app = s.representedObject as? URL { NSWorkspace.shared.open(selectedURLs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) } }
    @objc private func batchRename() { if let h = host { BatchRenameWindow.show(urls: selectedURLs, host: h) } }
    @objc private func compressTo(_ s: NSMenuItem) {
        guard let f = (s.representedObject as? String).flatMap(ArchiveFormat.init(rawValue:)), let h = host else { return }
        ArchiveOps.compress(selectedURLs, format: f, protected: s.tag == 1, state: h.state, window: view.window)
    }
    @objc private func shelfQuickLook() {
        guard let h = host else { return }
        h.state.selection = selectedURLs.compactMap { FileItemLoader.load($0) }
        h.quickLook(nil)
    }
    @objc private func cutItems() {
        let urls = selectedURLs
        FileOps.shared.cut(urls, window: view.window)
        if Preferences.shared.removeShelfItemsAfterUse { ShelfStore.remove(urls) }
    }
    @objc private func copyItems() { FileOps.shared.copy(selectedURLs) }
    @objc private func copyPaths() { FileOps.shared.copyPaths(selectedURLs) }
}

final class ShelfTable: NSTableView {
    weak var owner: ShelfController?
    override func menu(for event: NSEvent) -> NSMenu? { owner?.menu(forRow: row(at: convert(event.locationInWindow, from: nil))) }
}

/// Invisible drop zone that accepts file URLs.
final class DropTarget: NSView {
    let onDrop: ([URL]) -> Void
    init(onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .link }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop(DropIn.urls(sender)); return true }
}
