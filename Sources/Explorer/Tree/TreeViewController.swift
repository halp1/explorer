import AppKit
import Combine
import ExplorerKit

/// The Folder Tree (sidebar). NSOutlineView with lazily-loaded folders, auto-expand/scroll to the
/// current folder, drag & drop, favorites reordering, and a context menu.
final class TreeViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var host: BrowserWindowController?
    let outline = TreeOutlineView()
    private let scroll = NSScrollView()
    private(set) var roots: [TreeNode] = []
    private var suppressSelection = false
    /// Expanded node identities (per tab unless shared per window).
    var expanded: Set<String> = []
    private var volumeObservers: [NSObjectProtocol] = []
    private var monitor: FolderMonitor?
    let network = MountableBrowser()
    private var cancellables: Set<AnyCancellable> = []

    override func loadView() {
        let col = NSTableColumn(identifier: .init("tree"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        // Single column that always fills the sidebar (unless "Do not truncate" wants horizontal scrolling).
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.registerForDraggedTypes(DropIn.types + [.treeFavorite])
        outline.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        outline.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        outline.owner = self
        outline.target = self
        outline.action = #selector(clicked)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll

        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.rebuild() })
        }
        volumeObservers.append(NotificationCenter.default.addObserver(forName: .treeNeedsRebuild, object: nil, queue: .main) { [weak self] _ in self?.rebuild() })
        monitor = FolderMonitor(paths: [Favorites.folder.path, SavedSearchFile.folder.path]) { [weak self] _ in self?.rebuild() }
        monitor?.start()
        if Preferences.shared.sidebarSections.contains(where: { $0.id == "remote" && !$0.disabled }) {
            network.start()
            network.$services.debounce(for: .seconds(1), scheduler: RunLoop.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        }
        IDeviceRegistry.shared.$devices.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        rebuild(initial: true)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The sidebar only gets its real width after layout; keep the single column filling it.
        if Preferences.shared.truncateFolders != .none, let col = outline.tableColumns.first {
            let w = scroll.contentView.bounds.width
            if w > 0, abs(col.width - w) > 1 { col.width = w }
        }
    }

    deinit { volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) } }

    // MARK: Build

    func rebuild(initial: Bool = false) {
        TreeNode.subfolderCache.removeAll()
        roots = TreeBuilder.sections(network: network)
        let prefs = Preferences.shared
        if initial && expanded.isEmpty {
            for s in prefs.sidebarSections where s.expandedByDefault ?? true { expanded.insert("s:" + s.id) }
        }
        let p = Preferences.shared
        outline.rowSizeStyle = .custom
        outline.rowHeight = 20 + CGFloat(p.treeSpacing) + CGFloat(p.fontSizeDelta)
        outline.indentGuides = p.showIndentGuides
        scroll.hasHorizontalScroller = p.truncateFolders == .none
        outline.columnAutoresizingStyle = p.truncateFolders == .none ? .noColumnAutoresizing : .uniformColumnAutoresizingStyle
        outline.reloadData()
        if p.truncateFolders != .none { outline.sizeLastColumnToFit() }
        restoreExpansion(roots)
        revealCurrent()
    }

    private func restoreExpansion(_ nodes: [TreeNode]) {
        for n in nodes where expanded.contains(n.identity) {
            outline.expandItem(n)
            if let c = n.children { restoreExpansion(c) }
        }
    }

    // MARK: Current folder sync

    func revealCurrent() {
        guard let state = host?.state else { return }
        let target = state.location
        guard let node = find(target) else {
            suppressSelection = true
            outline.deselectAll(nil)
            suppressSelection = false
            return
        }
        let row = outline.row(forItem: node)
        if row >= 0 {
            suppressSelection = true
            outline.selectRowIndexes([row], byExtendingSelection: false)
            suppressSelection = false
            if Preferences.shared.autoScrollTree { outline.scrollRowToVisible(row) }
        }
    }

    /// Finds (expanding as needed) the node for a location.
    private func find(_ loc: Location) -> TreeNode? {
        switch loc {
        case .smart, .trash:
            return allLoaded().first { $0.location == loc }
        case .directory(let u):
            let path = u.standardizedFileURL.resolvingSymlinksInPath().path
            // Best root: the deepest folder node that is an ancestor of path (prefer Favorites/Home order of sections)
            var best: TreeNode?
            var bestLen = -1
            for section in roots {
                for c in section.children ?? [] {
                    guard let cu = c.url else { continue }
                    let cp = cu.standardizedFileURL.resolvingSymlinksInPath().path
                    if path == cp || path.hasPrefix(cp == "/" ? "/" : cp + "/"), cp.count > bestLen {
                        best = c; bestLen = cp.count
                    }
                }
            }
            guard var node = best else { return nil }
            let autoExpand = Preferences.shared.autoExpandTree
            if !outline.isItemExpanded(node.parent) && !autoExpand { return nil }
            if let p = node.parent, !outline.isItemExpanded(p) { outline.expandItem(p); expanded.insert(p.identity) }
            while true {
                let np = node.url!.standardizedFileURL.resolvingSymlinksInPath().path
                if np == path { return node }
                guard autoExpand else { return node }
                if node.children == nil { TreeBuilder.loadChildren(node) }
                outline.expandItem(node)
                expanded.insert(node.identity)
                guard let next = node.children?.first(where: { c in
                    guard let cu = c.url else { return false }
                    let cp = cu.standardizedFileURL.resolvingSymlinksInPath().path
                    return path == cp || path.hasPrefix(cp + "/")
                }) else { return node }
                node = next
            }
        case .archive(let u, let inner):
            return allLoaded().first { $0.kind == .archiveDir(u, inner) } ?? find(.directory(u.deletingLastPathComponent()))
        case .search(let s):
            return find(.directory(s.scope))
        case .device(let udid, let path):
            return allLoaded().first { $0.url == IDeviceRegistry.virtualURL(udid, path) }
        }
    }

    private func allLoaded() -> [TreeNode] {
        var out: [TreeNode] = []
        func walk(_ n: [TreeNode]) { for x in n { out.append(x); if let c = x.children { walk(c) } } }
        walk(roots)
        return out
    }

    // MARK: Data source

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? TreeNode else { return roots.count }
        if n.children == nil { TreeBuilder.loadChildren(n) }
        return n.children?.count ?? 0
    }

    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? TreeNode else { return roots[index] }
        return n.children![index]
    }

    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as! TreeNode).isExpandable }

    func outlineView(_ ov: NSOutlineView, isGroupItem item: Any) -> Bool { false }

    func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as! TreeNode).isNodeSelectable }

    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let n = item as! TreeNode
        let cell = (ov.makeView(withIdentifier: TreeCell.id, owner: self) as? TreeCell) ?? TreeCell()
        cell.configure(n)
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? TreeNode { expanded.insert(n.identity); host?.treeExpansionChanged() }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? TreeNode { expanded.remove(n.identity); host?.treeExpansionChanged() }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        selectRow(outline.selectedRow)
    }

    @objc private func clicked() {
        // Clicking a section toggles it
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? TreeNode else { return }
        if case .section = n.kind {
            if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
        }
    }

    private func selectRow(_ row: Int) {
        guard row >= 0, let n = outline.item(atRow: row) as? TreeNode else { return }
        switch n.kind {
        case .share(let s):
            if let u = URL(string: s.url) { host?.mountShare(u) }
        case .remoteHost(_, let u):
            host?.showMountShare(prefill: u)
        default:
            if let loc = n.location { host?.state.go(loc) }
        }
    }

    // MARK: Keyboard: ⌥↑/⌥↓ jump between top-level nodes, ⌥1-4 toggle sections

    func jumpTopLevel(_ dir: Int) {
        let rows = roots.map { outline.row(forItem: $0) }
        let cur = outline.selectedRow
        let target = dir > 0 ? rows.first { $0 > cur } : rows.last { $0 < cur }
        if let t = target {
            let n = outline.item(atRow: t) as! TreeNode
            if let first = n.children?.first, outline.isItemExpanded(n) {
                outline.selectRowIndexes([outline.row(forItem: first)], byExtendingSelection: false)
            }
            outline.scrollRowToVisible(t)
        }
    }

    func toggleSection(_ index: Int) {
        guard roots.indices.contains(index) else { return }
        let n = roots[index]
        if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
    }

    // MARK: Drag & drop

    func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        let n = item as! TreeNode
        if n.isFavorite && Preferences.shared.reorderFavorites {
            let pb = NSPasteboardItem()
            if let u = n.url { pb.setString(u.absoluteString, forType: .fileURL) }
            pb.setString(n.title, forType: .treeFavorite)
            return pb
        }
        return n.url.map { $0 as NSURL }
    }

    func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if info.draggingPasteboard.string(forType: .treeFavorite) != nil, let n = item as? TreeNode, case .section("favorites") = n.kind, index >= 0 {
            return .move
        }
        guard let n = item as? TreeNode else { return [] }
        // Dropping on the Favorites section adds favorites
        if case .section("favorites") = n.kind {
            let urls = DropIn.urls(info)
            if !urls.isEmpty && urls.allSatisfy({ $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) {
                ov.setDropItem(n, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .link
            }
            return []
        }
        guard index == NSOutlineViewDropOnItemIndex else {
            ov.setDropItem(n, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return validateOn(n, info)
        }
        return validateOn(n, info)
    }

    private func validateOn(_ n: TreeNode, _ info: NSDraggingInfo) -> NSDragOperation {
        if case .archiveDir = n.kind { return .copy }
        if case .trash = n.kind { return .delete }
        guard case .folder(let u) = n.kind else { return [] }
        return DropIn.validate(info, dest: u, state: nil)
    }

    func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let n = item as? TreeNode else { return false }
        if let name = info.draggingPasteboard.string(forType: .treeFavorite), case .section("favorites") = n.kind {
            Favorites.move(names: [name], to: index)
            rebuild()
            return true
        }
        if case .section("favorites") = n.kind {
            for u in DropIn.urls(info) { try? Favorites.add(u) }
            rebuild()
            return true
        }
        switch n.kind {
        case .folder(let u):
            return DropIn.perform(info, dest: u, state: nil, window: view.window)
        case .archiveDir(let u, let inner):
            guard let a = try? Archive(url: u) else { return false }
            try? a.load()
            ArchiveOps.add(DropIn.urls(info), to: a, inner: inner, state: host?.state, window: view.window)
            return true
        case .trash:
            FileOps.shared.moveToTrash(DropIn.urls(info), window: view.window)
            return true
        default: return false
        }
    }

    // MARK: Context menu

    func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0, let n = outline.item(atRow: row) as? TreeNode else { return nil }
        return host?.treeContextMenu(for: n)
    }
}

extension NSPasteboard.PasteboardType {
    static let treeFavorite = NSPasteboard.PasteboardType("com.halp.explorer.favorite")
}

extension Notification.Name {
    static let treeNeedsRebuild = Notification.Name("ExplorerTreeNeedsRebuild")
    static let viewSettingsChanged = Notification.Name("ExplorerViewSettingsChanged")
}

final class TreeOutlineView: NSOutlineView {
    weak var owner: TreeViewController?
    var indentGuides = false { didSet { needsDisplay = true } }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .option || mods == [.option, .numericPad, .function] || mods.contains(.option) && !mods.contains(.command) {
            switch event.keyCode {
            case 126: owner?.jumpTopLevel(-1); return
            case 125: owner?.jumpTopLevel(1); return
            default:
                if let c = event.charactersIgnoringModifiers, let d = Int(c), (1...4).contains(d) { owner?.toggleSection(d - 1); return }
            }
        }
        if let host = owner?.host, host.handleKey(event, fromTree: true) { return }
        super.keyDown(with: event)
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        guard indentGuides else { return }
        NSColor.separatorColor.setStroke()
        let rows = self.rows(in: clipRect)
        for r in rows.lowerBound..<rows.upperBound {
            let lvl = level(forRow: r)
            guard lvl > 1 else { continue }
            let rect = rect(ofRow: r)
            for l in 1..<lvl {
                let x = CGFloat(l) * indentationPerLevel + 14
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x, y: rect.minY)); p.line(to: NSPoint(x: x, y: rect.maxY))
                p.lineWidth = 0.5
                p.stroke()
            }
        }
    }
}

final class TreeCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("TreeCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let eject = NSButton()
    private var node: TreeNode?

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        [icon, label, eject].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        eject.isBordered = false
        eject.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
        eject.target = self
        eject.action = #selector(ejectTapped)
        label.cell?.usesSingleLineMode = true
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17), icon.heightAnchor.constraint(equalToConstant: 17),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: eject.leadingAnchor, constant: -4),
            eject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            eject.centerYAnchor.constraint(equalTo: centerYAnchor),
            eject.widthAnchor.constraint(equalToConstant: 14),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ n: TreeNode) {
        node = n
        let p = Preferences.shared
        label.stringValue = n.title
        label.lineBreakMode = ItemStyle.truncation(p.truncateFolders)
        let bold = n.isTopLevel && p.boldTopLevel
        label.font = n.isTopLevel ? .systemFont(ofSize: 11 + CGFloat(p.fontSizeDelta), weight: bold ? .bold : .semibold)
                                  : .systemFont(ofSize: 13 + CGFloat(p.fontSizeDelta))
        label.textColor = n.isTopLevel ? .secondaryLabelColor : .labelColor
        var tint = n.labelColor ?? (p.foldersInheritColor ? n.color : nil) ?? n.color ?? ThemeColors.theme
        if case .folder = n.kind, !n.isTopLevel, n.symbol == nil, !p.foldersInheritColor { tint = n.labelColor ?? ThemeColors.theme }
        var img: NSImage?
        if case .folder(let u) = n.kind, n.symbol == nil, p.showCustomFolderIcons, CustomIcon.has(u) {
            img = NSWorkspace.shared.icon(forFile: u.path)
            icon.contentTintColor = nil
        } else {
            let sym = n.symbol ?? (n.isFavorite ? "folder" : "folder")
            img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            icon.contentTintColor = tint
        }
        if case .placeholder = n.kind { label.textColor = .tertiaryLabelColor }
        if case .share = n.kind { label.textColor = .secondaryLabelColor }
        icon.image = img
        eject.isHidden = !n.ejectable
    }

    @objc private func ejectTapped() {
        guard let u = node?.url else { return }
        VolumeOps.eject(u, window: window)
    }
}

enum CustomIcon {
    static func has(_ u: URL) -> Bool {
        // Folders with a custom icon contain "Icon\r" and have the kHasCustomIcon Finder flag.
        FileManager.default.fileExists(atPath: u.appendingPathComponent("Icon\r").path)
    }
}

enum VolumeOps {
    static func eject(_ u: URL, window: NSWindow?) {
        DispatchQueue.global().async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: u)
            } catch {
                DispatchQueue.main.async { Alerts.error("Eject", error.localizedDescription, window: window) }
            }
        }
    }
}
