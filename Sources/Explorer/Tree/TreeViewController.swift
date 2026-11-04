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
        // Single column sized by fitColumn() to the visible width (unless "Do not truncate" wants horizontal scrolling).
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.registerForDraggedTypes(DropIn.types + [.treeFavorite])
        outline.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        outline.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        outline.owner = self
        outline.target = self
        outline.action = #selector(clicked)
        scroll.documentView = outline
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let root = TintedSidebarView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
        // The clip narrows when a legacy scroller appears without the sidebar itself relaying out.
        scroll.contentView.postsFrameChangedNotifications = true
        volumeObservers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.fitColumn() })

        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.rebuild() })
        }
        volumeObservers.append(NotificationCenter.default.addObserver(forName: .treeNeedsRebuild, object: nil, queue: .main) { [weak self] _ in self?.rebuild() })
        volumeObservers.append(NotificationCenter.default.addObserver(forName: .treeFilesChanged, object: nil, queue: .main) { [weak self] n in
            self?.refreshAfterFileChange(n.userInfo?["urls"] as? [URL] ?? [])
        })
        monitor = FolderMonitor(paths: [Favorites.folder.path, SavedSearchFile.folder.path]) { [weak self] _ in self?.rebuild() }
        monitor?.start()
        if Preferences.shared.sidebarSections.contains(where: { $0.id == "remote" && !$0.disabled }) {
            network.start()
            network.$services.debounce(for: .seconds(1), scheduler: RunLoop.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        }
        IDeviceRegistry.shared.$devices.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        MTPService.shared.$devices.receive(on: RunLoop.main).sink { [weak self] devices in
            guard let self else { return }
            self.rebuild()
            if let address = self.host?.state.mtpLocation,
               !devices.contains(where: { $0.address.sessionID == address.sessionID && $0.id == address.deviceID }) {
                self.host?.state.reload()
            }
        }.store(in: &cancellables)
        rebuild(initial: true)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitColumn()
    }

    /// Keeps the single column ending exactly at the visible edge (minus the source-list trailing
    /// padding). A wider column pushes eject buttons and the selection pill under the clip edge.
    private func fitColumn() {
        guard Preferences.shared.truncateFolders != .none, let col = outline.tableColumns.first, outline.numberOfColumns > 0 else { return }
        let target = scroll.contentView.bounds.width - Self.trailingPadding
        let delta = target - outline.rect(ofColumn: 0).maxX
        guard target > 0, abs(delta) > 0.5 else { return }
        col.width = max(col.minWidth, col.width + delta)
    }

    private static let trailingPadding: CGFloat = 10

    deinit { volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) } }

    // MARK: Build

    func rebuild(initial: Bool = false) {
        TreeNode.subfolderCache.removeAll()
        let scrollOrigin = scroll.contentView.bounds.origin
        // MTP listings are slow USB round trips: carry loaded device folders over to the new nodes so a
        // device republish does not collapse them to "Loading..." and shrink the tree under the scroller.
        var loadedMTP: [String: TreeNode] = [:]
        for n in allLoaded() {
            if case .mtp = n.kind, n.children != nil, !n.isLoading, n.loadError == nil { loadedMTP[n.identity] = n }
        }
        roots = TreeBuilder.sections(network: network)
        if let f = favoriteContext {
            favoriteContext = roots.first(where: \.isFavoritesSection)?.children?.first { $0.identity == f.identity }
        }
        for r in roots {
            if case .mtp = r.kind, r.loadError == nil, let old = loadedMTP[r.identity] {
                r.children = old.children
                r.children?.forEach { $0.parent = r }
            }
        }
        let prefs = Preferences.shared
        if initial && expanded.isEmpty {
            let defaults = Set(prefs.sidebarSections.filter { $0.expandedByDefault ?? true }.map(\.id))
            for r in roots where defaults.contains(r.sectionID ?? "") { expanded.insert(r.identity) }
        }
        let p = Preferences.shared
        outline.rowSizeStyle = .custom
        outline.rowHeight = 21 + CGFloat(p.treeSpacing) + CGFloat(p.fontSizeDelta)
        outline.indentGuides = p.showIndentGuides
        scroll.hasHorizontalScroller = p.truncateFolders == .none
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.reloadData()
        fitColumn()
        restoreExpansion(roots)
        if !initial { restoreScroll(scrollOrigin) }
        revealCurrent(scroll: initial)
        updateFolderMonitor()
    }

    private func restoreScroll(_ origin: NSPoint) {
        let clip = scroll.contentView
        var b = clip.bounds
        b.origin = origin
        clip.scroll(to: clip.constrainBoundsRect(b).origin)
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Disk changes

    /// Watches every expanded folder so rows for folders that were trashed, moved or created elsewhere
    /// update in place (FSEvents reports the parent directory of each change).
    private var treeMonitor: FolderMonitor?
    private var monitoredPaths: Set<String> = []

    /// Loaded local folder nodes by path. One folder can appear several times (a favorite and the
    /// same folder under Home), so every occurrence is kept.
    private func loadedFolders() -> [String: [TreeNode]] {
        var out: [String: [TreeNode]] = [:]
        for n in allLoaded() {
            guard case .folder(let u) = n.kind, n.children != nil, IDeviceRegistry.parseVirtual(u) == nil else { continue }
            out[u.standardizedFileURL.path, default: []].append(n)
        }
        return out
    }

    private func updateFolderMonitor() {
        var paths = Set(loadedFolders().keys)
        // Favorites point anywhere: watch each target's parent so a trashed favorite disappears.
        for f in roots.first(where: \.isFavoritesSection)?.children ?? [] {
            if let u = f.url { paths.insert(u.deletingLastPathComponent().standardizedFileURL.path) }
        }
        guard paths != monitoredPaths else { return }
        monitoredPaths = paths
        treeMonitor?.stop()
        treeMonitor = nil
        guard !paths.isEmpty else { return }
        let m = FolderMonitor(paths: Array(paths), latency: 0.4) { [weak self] changed in self?.foldersChanged(changed) }
        if m.start() { treeMonitor = m }
    }

    private func foldersChanged(_ changed: [String]) {
        let dirs = Set(changed.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        // A favorite whose folder disappeared lives in its own section, not under a watched parent.
        let favorites = roots.first(where: \.isFavoritesSection)?.children ?? []
        if favorites.contains(where: { f in
            guard let u = f.url, dirs.contains(u.deletingLastPathComponent().standardizedFileURL.path) else { return false }
            return !f.targetExists
        }) {
            rebuild()
            return
        }
        let loaded = loadedFolders()
        var touched = false
        for d in dirs { for n in loaded[d] ?? [] { touched = refreshChildren(of: n) || touched } }
        if touched { updateFolderMonitor(); revealCurrent(scroll: false) }
    }

    /// Re-reads one folder's subfolders, keeping the node objects (and their expansion) for survivors.
    @discardableResult
    func refreshChildren(of node: TreeNode) -> Bool {
        guard let old = node.children else { return false }
        let fresh = TreeNode(node.kind, title: node.title)
        fresh.sectionID = node.sectionID
        fresh.color = node.color
        TreeBuilder.loadChildren(fresh)
        let newKids = fresh.children ?? []
        guard newKids.map(\.identity) != old.map(\.identity) else { return false }
        let survivors = Dictionary(old.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        node.children = newKids.map { k in
            let kept = survivors[k.identity] ?? k
            kept.parent = node
            return kept
        }
        TreeNode.subfolderCache.removeAll()
        outline.reloadItem(node, reloadChildren: true)
        restoreExpansion(node.children ?? [])
        return true
    }

    /// Prunes the tree right after Explorer itself trashes, deletes or moves folders, without waiting
    /// for FSEvents. Only the parents of the affected items are re-read.
    func refreshAfterFileChange(_ urls: [URL]) {
        foldersChanged(urls.flatMap { [$0.path, $0.deletingLastPathComponent().path] })
    }

    private func restoreExpansion(_ nodes: [TreeNode]) {
        for n in nodes where expanded.contains(n.identity) {
            outline.expandItem(n)
            if let c = n.children { restoreExpansion(c) }
        }
    }

    // MARK: Current folder sync

    /// Selects the current location's row. `scroll` is for navigation only: lazy loads and rebuilds must
    /// not yank the sidebar away from where the user is expanding folders.
    func revealCurrent(scroll: Bool = true) {
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
            if scroll && Preferences.shared.autoScrollTree { scrollRowIntoComfortableView(row) }
        }
    }

    /// Finds (expanding as needed) the node for a location.
    private func find(_ loc: Location) -> TreeNode? {
        switch loc {
        case .smart, .trash:
            return allLoaded().first { $0.location == loc }
        case .directory(let u):
            let path = u.standardizedFileURL.resolvingSymlinksInPath().path
            func contains(_ c: TreeNode) -> Int? {
                guard let cu = c.url, c.location != nil else { return nil }
                let cp = cu.standardizedFileURL.resolvingSymlinksInPath().path
                return path == cp || path.hasPrefix(cp == "/" ? "/" : cp + "/") ? cp.count : nil
            }
            // Favorites only own the selection while browsing inside the favorite that was clicked in the tree.
            // Everything else resolves in the main tree (Home, drives, cloud folders).
            if let f = favoriteContext, contains(f) == nil { favoriteContext = nil }
            var best: TreeNode? = favoriteContext
            if best == nil {
                var bestLen = -1
                for section in roots where !section.isFavoritesSection {
                    for c in [section] + (section.children ?? []) {
                        if let len = contains(c), len > bestLen { best = c; bestLen = len }
                    }
                }
            }
            // Nothing in the main tree holds it (e.g. Home is hidden): fall back to a matching favorite.
            if best == nil {
                best = roots.first(where: \.isFavoritesSection)?.children?
                    .compactMap { c in contains(c).map { (c, $0) } }.max { $0.1 < $1.1 }?.0
            }
            guard var node = best else { return nil }
            let autoExpand = Preferences.shared.autoExpandTree
            if let p = node.parent, !outline.isItemExpanded(p) {
                if !autoExpand { return nil }
                outline.expandItem(p); expanded.insert(p.identity)
            }
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
        case .mtp(let address):
            if !Preferences.shared.autoExpandTree {
                return allLoaded().first(where: { $0.identity == address.id })
            }
            var ancestry: [MTPAddress] = []
            var current: MTPAddress? = address
            while let part = current {
                ancestry.insert(part, at: 0)
                current = part.parent
            }
            var deepest: TreeNode?
            for part in ancestry {
                guard let node = allLoaded().first(where: { $0.identity == part.id }) else { break }
                deepest = node
                if part.id != address.id {
                    if node.children == nil { loadChildren(node) }
                    outline.expandItem(node)
                    expanded.insert(node.identity)
                }
            }
            return deepest
        }
    }

    private func allLoaded() -> [TreeNode] {
        var out: [TreeNode] = []
        func walk(_ n: [TreeNode]) { for x in n { out.append(x); if let c = x.children { walk(c) } } }
        walk(roots)
        return out
    }

    private func loadChildren(_ node: TreeNode) {
        guard case .mtp(let address) = node.kind else {
            TreeBuilder.loadChildren(node)
            return
        }
        guard !node.isLoading else { return }
        node.isLoading = true
        node.loadError = nil
        let loading = TreeNode(.placeholder("Loading..."), title: "Loading...")
        loading.parent = node
        node.children = [loading]
        let hidden = Preferences.shared.showHiddenInTree
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak node] in
            let result = Result { try MTPService.shared.list(address) }
            DispatchQueue.main.async {
                guard let self, let node, self.allLoaded().contains(where: { $0 === node }) else { return }
                node.isLoading = false
                switch result {
                case .success(let items):
                    node.children = items.filter { $0.isDirectory && (hidden || !$0.isHidden) }.compactMap { item in
                        guard let childAddress = item.mtpAddress else { return nil }
                        let child = TreeNode(.mtp(childAddress), title: item.name, symbol: "folder")
                        child.parent = node
                        child.sectionID = node.sectionID
                        child.color = node.color
                        return child
                    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                case .failure(let error):
                    node.loadError = error.localizedDescription
                    let failed = TreeNode(.placeholder("Retry Loading Folder"), title: "Retry Loading Folder", symbol: "arrow.clockwise")
                    failed.loadError = error.localizedDescription
                    failed.parent = node
                    node.children = [failed]
                }
                let origin = self.scroll.contentView.bounds.origin
                self.outline.reloadItem(node, reloadChildren: true)
                self.restoreExpansion(node.children ?? [])
                self.restoreScroll(origin)
                if case .success = result { self.revealCurrent(scroll: false) }
            }
        }
    }

    // MARK: Data source

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? TreeNode else { return roots.count }
        if n.children == nil { loadChildren(n) }
        return n.children?.count ?? 0
    }

    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? TreeNode else { return roots[index] }
        return n.children![index]
    }

    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as! TreeNode).isExpandable }

    func outlineView(_ ov: NSOutlineView, isGroupItem item: Any) -> Bool { false }

    func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as! TreeNode).isNodeSelectable }

    func outlineView(_ ov: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let v = AccentRowView()
        v.pillHeight = ov.rowHeight
        return v
    }

    func outlineView(_ ov: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        let n = item as! TreeNode
        let base = ov.rowHeight
        // Breathing room above each top-level group, and below the toolbar for the first one.
        guard n.isTopLevel, let i = roots.firstIndex(of: n) else { return base }
        return base + (i == 0 ? 8 : 6)
    }

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
        if let n = notification.userInfo?["NSObject"] as? TreeNode {
            expanded.remove(n.identity)
            if n.loadError != nil { n.children = nil }
            host?.treeExpansionChanged()
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        selectRow(outline.selectedRow)
    }

    @objc private func clicked() {
        // Clicking a section toggles it
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? TreeNode else { return }
        if case .placeholder = n.kind, n.loadError != nil, let parent = n.parent {
            loadChildren(parent)
            outline.reloadItem(parent, reloadChildren: true)
            return
        }
        if case .section = n.kind {
            if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
        }
    }

    /// The Favorites entry the user last clicked into (or below). Cleared by navigating outside it.
    private var favoriteContext: TreeNode?

    private func selectRow(_ row: Int) {
        guard row >= 0, let n = outline.item(atRow: row) as? TreeNode else { return }
        var top = n
        while let p = top.parent, !p.isFavoritesSection { top = p }
        favoriteContext = top.parent?.isFavoritesSection == true ? top : nil
        switch n.kind {
        case .share(let s):
            if let u = URL(string: s.url) { host?.mountShare(u) }
        case .remoteHost(_, let u):
            host?.showMountShare(prefill: u)
        default:
            // A folder removed behind the tree's back: drop the row instead of opening a missing path.
            if !n.targetExists {
                if let p = n.parent, case .folder = p.kind { refreshChildren(of: p) } else { rebuild() }
                return
            }
            if let loc = n.location { host?.state.go(loc) }
        }
    }

    /// Scrolls only when the row is outside the visible (inset-aware) area, then centres it.
    private func scrollRowIntoComfortableView(_ row: Int) {
        let r = outline.rect(ofRow: row)
        let clip = scroll.contentView
        let insets = scroll.contentInsets
        let visible = NSRect(x: clip.bounds.minX, y: clip.bounds.minY + insets.top,
                             width: clip.bounds.width, height: clip.bounds.height - insets.top - insets.bottom)
        guard !visible.contains(r) else { return }
        let targetY = max(-insets.top, min(r.midY - insets.top - visible.height / 2, outline.bounds.height - clip.bounds.height + insets.bottom))
        clip.scroll(to: NSPoint(x: 0, y: targetY))
        scroll.reflectScrolledClipView(clip)
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
        if case .mtp(let address) = n.kind {
            guard address.objectID != nil else { return nil }
            return DragOut.mtpWriter(address: address, isDirectory: true, name: n.title, typeIdentifier: "public.folder")
        }
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
        if case .mtp(let address) = n.kind { return DropIn.validate(info, dest: address.url, state: nil) }
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
        case .mtp(let address):
            return DropIn.perform(info, dest: address.url, state: host?.state, window: view.window)
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
    /// userInfo["urls"]: items Explorer just trashed, deleted or moved.
    static let treeFilesChanged = Notification.Name("ExplorerTreeFilesChanged")
    static let viewSettingsChanged = Notification.Name("ExplorerViewSettingsChanged")
}

final class TreeOutlineView: NSOutlineView {
    weak var owner: TreeViewController?
    var indentGuides = false { didSet { needsLayout = true } }

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

    // Indent guides are drawn by an overlay so the outline keeps the system sidebar material
    // (overriding drawBackground makes AppKit treat the table as opaque).
    private lazy var guides: IndentGuidesView = {
        let v = IndentGuidesView(); v.outline = self; addSubview(v, positioned: .below, relativeTo: nil); return v
    }()

    override func layout() {
        super.layout()
        if indentGuides { guides.frame = bounds; guides.needsDisplay = true }
        guides.isHidden = !indentGuides
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
        eject.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        eject.contentTintColor = .secondaryLabelColor
        eject.target = self
        eject.action = #selector(ejectTapped)
        label.cell?.usesSingleLineMode = true
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 19), icon.heightAnchor.constraint(equalToConstant: 17),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.trailingAnchor.constraint(equalTo: eject.leadingAnchor, constant: -4),
            eject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            eject.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            eject.widthAnchor.constraint(equalToConstant: 16),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ n: TreeNode) {
        node = n
        toolTip = n.loadError
        let p = Preferences.shared
        label.stringValue = n.title
        label.lineBreakMode = ItemStyle.truncation(p.truncateFolders)
        let bold = n.isTopLevel && p.boldTopLevel
        // Top-level rows read like the original: same size as children, slightly bolder, secondary colour.
        // The original's tree: 12 pt semibold for every node.
        label.font = .systemFont(ofSize: 12 + CGFloat(p.fontSizeDelta), weight: .semibold)
        // Groups without a folder of their own (Tags, Star Ratings, …) read dimmer, as in the original.
        label.textColor = n.location == nil && n.isTopLevel && n.isFavoritesSection == false ? .secondaryLabelColor : .labelColor
        var tint = n.labelColor ?? (p.foldersInheritColor ? n.color : nil) ?? n.color ?? ThemeColors.theme
        if case .folder = n.kind, !n.isTopLevel, n.symbol == nil, !p.foldersInheritColor { tint = n.labelColor ?? ThemeColors.theme }
        var img: NSImage?
        if case .folder(let u) = n.kind, n.symbol == nil, p.showCustomFolderIcons, CustomIcon.has(u) {
            img = NSWorkspace.shared.icon(forFile: u.path)
            icon.contentTintColor = nil
        } else {
            let sym = n.symbol ?? (n.isFavorite ? "folder" : "folder")
            img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            icon.contentTintColor = tint
        }
        if case .placeholder = n.kind { label.textColor = .tertiaryLabelColor }
        selectedTint = tint
        if case .share = n.kind { label.textColor = .secondaryLabelColor }
        icon.image = img
        eject.isHidden = !n.ejectable
    }

    private var selectedTint: NSColor?
    // Vibrant text blends into the solid pill and reads pale. Selected rows draw plain white.
    override var allowsVibrancy: Bool { backgroundStyle != .emphasized }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            if oldValue != backgroundStyle { label.needsDisplay = true; icon.needsDisplay = true; needsDisplay = true }
            let sel = backgroundStyle == .emphasized
            label.textColor = sel ? .white : (node.map { $0.location == nil && $0.isTopLevel && !$0.isFavoritesSection ? NSColor.secondaryLabelColor : NSColor.labelColor } ?? .labelColor)
            // Original keeps the coloured symbol on the pill, lightened toward white.
            if icon.contentTintColor != nil || sel {
                icon.contentTintColor = sel ? (selectedTint ?? .white).blended(withFraction: 0.55, of: .white) : selectedTint
            }
            eject.contentTintColor = sel ? .white : .secondaryLabelColor
        }
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

final class IndentGuidesView: NSView {
    weak var outline: TreeOutlineView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let o = outline else { return }
        NSColor.separatorColor.setStroke()
        let rows = o.rows(in: dirtyRect)
        for r in rows.lowerBound..<rows.upperBound {
            let lvl = o.level(forRow: r)
            guard lvl > 1 else { continue }
            let rect = o.rect(ofRow: r)
            for l in 1..<lvl {
                let x = CGFloat(l) * o.indentationPerLevel + 14
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x, y: rect.minY)); p.line(to: NSPoint(x: x, y: rect.maxY))
                p.lineWidth = 0.5
                p.stroke()
            }
        }
    }
}

/// Solid accent-coloured selection pill (Folders Pro style) instead of the translucent source-list highlight.
final class AccentRowView: NSTableRowView {
    /// Height of the label line. Rows that carry extra space above them (section gaps) keep that
    /// space outside the pill.
    var pillHeight: CGFloat = 23

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isSelected else { return }
        let h = min(pillHeight, bounds.height)
        let r = NSRect(x: bounds.minX + 8, y: bounds.maxY - h, width: bounds.width - 16, height: h).insetBy(dx: 0, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        // Resolve the accent in the row's appearance (dynamic asset colour), then blend like the original (~80%).
        var base = ThemeColors.theme
        effectiveAppearance.performAsCurrentDrawingAppearance { base = ThemeColors.theme.usingColorSpace(.sRGB) ?? base }
        // Same strength whether or not the window is key.
        base.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.2).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isSelected: Bool { didSet { needsDisplay = true } }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
    override var isEmphasized: Bool { get { true } set { } }

    // Source lists add a full-row selection material (it also covers the gap above a top-level row and
    // reaches the clip edge). Keep it hidden so the pill is the only highlight.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview is NSVisualEffectView { subview.isHidden = true }
    }
    override func layout() {
        super.layout()
        for v in subviews where v is NSVisualEffectView { v.isHidden = true }
    }
}


/// Faint theme-colour wash over the sidebar glass (the original tints its window background with its accent).
final class TintedSidebarView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; updateTint() }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTint() }
    func updateTint() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = ThemeColors.theme.withAlphaComponent(dark ? 0.035 : 0.03).cgColor
    }
}
