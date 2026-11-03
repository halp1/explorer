import AppKit
import Combine
import Quartz
import UniformTypeIdentifiers
import ExplorerKit

/// One window (= one tab when tabbed natively). Hosts tree | file view | info panel, plus path bar,
/// status bar, shelf flap, and routes every command.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    let state: BrowserState
    let tree = TreeViewController()
    let info = InfoPanelController()
    let shelf = ShelfController()
    private(set) var fileView: FileViewing!
    private let split = NSSplitViewController()
    private let center = NSViewController()
    private let viewContainer = NSView()
    let pathBar = PathBarView()
    let statusBar = StatusBarView()
    let banner = BannerView()
    let actionBar = ActionToolbarView()
    let actionsRow = ActionsRowView()
    private var cancellables: Set<AnyCancellable> = []
    private var searchField: NSSearchField?
    private var viewPicker: NSSegmentedControl?
    private weak var viewMenuItem: NSMenuToolbarItem?
    private weak var viewPopup: NSPopUpButton?
    weak var searchItem: NSSearchToolbarItem?
    weak var viewOptionsControl: ViewOptionsControl?
    private var qlItems: [URL] = []
    private var qlRequest: [String] = []

    static var all: [BrowserWindowController] = []

    init(location: Location, select: [URL] = []) {
        state = BrowserState(location: location)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 652),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.minSize = NSSize(width: 560, height: 360)
        w.tabbingMode = .preferred
        w.tabbingIdentifier = "ExplorerBrowser"
        w.titlebarAppearsTransparent = false
        w.toolbarStyle = .unified
        w.setFrameAutosaveName("ExplorerBrowserWindow")
        super.init(window: w)
        w.delegate = self
        state.passwordProvider = { [weak self] url in ArchiveOps.askPassword(for: url, window: self?.window) }
        buildUI()
        bind()
        state.go(location, recordHistory: false, select: select)
        Self.all.append(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        guard let w = window else { return }
        tree.host = self
        info.host = self
        shelf.host = self

        let treeItem = NSSplitViewItem(sidebarWithViewController: tree)
        treeItem.minimumThickness = 160
        treeItem.maximumThickness = 500
        treeItem.canCollapse = true
        treeItem.isCollapsed = !state.prefs.showSidebar

        let centerRoot = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width   // every row spans the full width (default .centerX shrinks rows to fit)
        stack.translatesAutoresizingMaskIntoConstraints = false
        centerRoot.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: centerRoot.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: centerRoot.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: centerRoot.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: centerRoot.trailingAnchor),
        ])
        pathBar.host = self
        statusBar.host = self
        actionBar.host = self
        viewContainer.translatesAutoresizingMaskIntoConstraints = false
        let middle = NSView()
        middle.addSubview(viewContainer)
        shelf.view.translatesAutoresizingMaskIntoConstraints = false
        middle.addSubview(shelf.view)
        NSLayoutConstraint.activate([
            viewContainer.topAnchor.constraint(equalTo: middle.topAnchor), viewContainer.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            viewContainer.leadingAnchor.constraint(equalTo: middle.leadingAnchor), viewContainer.trailingAnchor.constraint(equalTo: middle.trailingAnchor),
            shelf.view.trailingAnchor.constraint(equalTo: middle.trailingAnchor), shelf.view.topAnchor.constraint(equalTo: middle.topAnchor),
            shelf.view.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
        ])
        actionsRow.host = self
        for v in [banner, pathBar, actionsRow, middle, statusBar] {
            stack.addArrangedSubview(v)
            v.setContentHuggingPriority(.defaultHigh, for: .vertical)
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        // The crumb row must not dictate the bar's width.
        pathBar.setContentHuggingPriority(.init(1), for: .horizontal)
        middle.setContentHuggingPriority(.defaultLow, for: .vertical)
        center.view = centerRoot
        layoutChrome()

        let centerItem = NSSplitViewItem(viewController: center)
        centerItem.minimumThickness = 300
        let infoItem = NSSplitViewItem(viewController: info)
        infoItem.minimumThickness = 220
        infoItem.maximumThickness = 520
        infoItem.canCollapse = true
        infoItem.isCollapsed = !state.options.showInfo
        split.splitViewItems = [treeItem, centerItem, infoItem]
        let hadSavedLayout = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames ExplorerMainSplit") != nil
        split.splitView.autosaveName = "ExplorerMainSplit"
        w.contentViewController = split
        w.setContentSize(NSSize(width: 1000, height: 652))
        w.titleVisibility = .hidden   // the toolbar's title item shows the folder name
        if !hadSavedLayout {
            // Same default sidebar width as the original (253 pt).
            split.splitView.layoutSubtreeIfNeeded()
            split.splitView.setPosition(253, ofDividerAt: 0)
        }

        let tb = NSToolbar(identifier: "MainToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = true
        tb.autosavesConfiguration = true
        w.toolbar = tb
        setFileView(for: state.options.view)
    }

    /// Path bar top/bottom, status/action bar visibility.
    func layoutChrome() {
        guard let stack = pathBar.superview as? NSStackView else { return }
        let p = state.prefs
        stack.removeView(pathBar)
        if p.pathBarPosition == .top { stack.insertArrangedSubview(pathBar, at: 1) } else { stack.insertArrangedSubview(pathBar, at: stack.arrangedSubviews.count - 1) }
        // removeView drops constraints to the stack; pin the bar to both edges again.
        pathBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        pathBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        pathBar.isHidden = !p.showPathBar
        statusBar.isHidden = !p.showStatusBar
        actionsRow.isHidden = !p.showActionToolbar
        statusBar.toggles = actionBar
        shelf.view.isHidden = !p.showShelf
        pathBar.refresh()
    }

    private var infoItem: NSSplitViewItem { split.splitViewItems[2] }
    private var treeItem: NSSplitViewItem { split.splitViewItems[0] }

    func setFileView(for kind: ViewKind) {
        let vc: FileViewing
        if state.isArchive && kind != .icons && kind != .gallery {
            vc = (fileView as? TableViewController).flatMap { $0.archiveMode ? $0 : nil } ?? TableViewController(archiveMode: true)
        } else {
            switch kind {
            case .icons: vc = (fileView as? CollectionViewController).flatMap { $0.mode == .icons ? $0 : nil } ?? CollectionViewController(mode: .icons)
            case .list: vc = (fileView as? CollectionViewController).flatMap { $0.mode == .list ? $0 : nil } ?? CollectionViewController(mode: .list)
            case .table: vc = (fileView as? TableViewController).flatMap { !$0.archiveMode ? $0 : nil } ?? TableViewController(archiveMode: false)
            case .gallery: vc = (fileView as? GalleryViewController) ?? GalleryViewController()
            }
        }
        if vc !== fileView {
            let hadFocus = window?.firstResponder is NSView && (window?.firstResponder as? NSView)?.isDescendant(of: viewContainer) == true
            fileView?.view.removeFromSuperview()
            vc.state = state
            vc.host = self
            vc.view.translatesAutoresizingMaskIntoConstraints = false
            viewContainer.addSubview(vc.view)
            NSLayoutConstraint.activate([
                vc.view.topAnchor.constraint(equalTo: viewContainer.topAnchor), vc.view.bottomAnchor.constraint(equalTo: viewContainer.bottomAnchor),
                vc.view.leadingAnchor.constraint(equalTo: viewContainer.leadingAnchor), vc.view.trailingAnchor.constraint(equalTo: viewContainer.trailingAnchor),
            ])
            fileView = vc
            vc.reloadItems()
            if hadFocus || window?.firstResponder === window { vc.focus() }
        }
        viewPicker?.selectedSegment = ViewKind.allCases.firstIndex(of: kind) ?? 0
        viewMenuItem?.image = NSImage(systemSymbolName: ViewKind.toolbarSymbol(kind), accessibilityDescription: "View")
        viewPopup?.menu?.items.first?.image = NSImage(systemSymbolName: ViewKind.toolbarSymbol(kind), accessibilityDescription: "View")?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        viewPopup?.synchronizeTitleAndSelectedItem()
        viewOptionsControl?.refresh()
        actionBar.refresh()
    }

    private func bind() {
        state.$items.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.fileView?.reloadItems(); self?.statusBar.refresh(); self?.info.refresh() }
        }.store(in: &cancellables)
        state.selectionDidChange.debounce(for: .milliseconds(30), scheduler: RunLoop.main).sink { [weak self] in
            self?.fileView?.syncSelection(); self?.statusBar.refresh(); self?.info.refresh(); self?.updateQuickLook(); self?.actionBar.refresh()
        }.store(in: &cancellables)
        state.$location.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.locationChanged() }
        }.store(in: &cancellables)
        state.$options.receive(on: RunLoop.main).sink { [weak self] o in
            DispatchQueue.main.async {
                guard let self else { return }
                self.setFileView(for: o.view)
                if self.infoItem.isCollapsed == o.showInfo { self.infoItem.animator().isCollapsed = !o.showInfo }
                self.fileView.reloadItems()
                self.window?.toolbar?.validateVisibleItems()
                self.actionBar.refresh()
            }
        }.store(in: &cancellables)
        Publishers.Merge3(state.$errorMessage.map { _ in () }, state.$warning.map { _ in () }, state.$searchGathering.map { _ in () })
            .receive(on: RunLoop.main).sink { [weak self] in DispatchQueue.main.async { self?.updateBanner() } }.store(in: &cancellables)
        FileOps.shared.$running.receive(on: RunLoop.main).sink { [weak self] _ in self?.statusBar.refresh() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .viewSettingsChanged).receive(on: RunLoop.main).sink { [weak self] _ in
            self?.layoutChrome(); self?.fileView.reloadItems(); self?.tree.rebuild()
        }.store(in: &cancellables)
    }

    private func locationChanged() {
        window?.title = state.title
        window?.subtitle = ""
        window?.tab.title = state.title
        if let c = state.tabColor { window?.tab.attributedTitle = NSAttributedString(string: state.title, attributes: [.foregroundColor: TreeBuilder.color(c)]) }
        if let u = state.location.url, state.location.isFileSystem { window?.representedURL = u } else { window?.representedURL = nil }
        if case .search(let s) = state.location { searchField?.stringValue = s.text } else if !(window?.firstResponder is NSText) { searchField?.stringValue = "" }
        setFileView(for: state.options.view)
        tree.revealCurrent()
        pathBar.refresh()
        statusBar.refresh()
        info.refresh()
        window?.toolbar?.validateVisibleItems()
        searchField?.isEnabled = state.mtpLocation == nil
        searchItem?.searchField.isEnabled = state.mtpLocation == nil
        searchField?.placeholderString = "Search " + (state.currentDirectory.map { FileNaming.displayName(of: $0) } ?? "")
    }

    private func updateBanner() {
        if let e = state.errorMessage {
            var actions: [(String, () -> Void)] = []
            if state.isTrash { actions.append(("Open System Settings", { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) })) }
            banner.show(e, style: .error, actions: actions)
        } else if let w = state.warning {
            banner.show(w, style: .warning)
        } else if state.isSearch, case .search(let s) = state.location {
            let text = s.useSpotlight ? "The search results are limited to Spotlight-indexed locations." : "The search results do not monitor live changes."
            let switchTitle = s.useSpotlight ? "Switch to Full Scan Search" : "Switch to Spotlight Search"
            var acts: [(String, () -> Void)] = [(switchTitle, { [weak self] in self?.state.setSearchMode(spotlight: !s.useSpotlight) })]
            if s.useSpotlight { acts.append(("Save Search", { [weak self] in self?.saveSearch() })) }
            banner.show((state.searchGathering ? "Searching… " : "") + text, style: .info, actions: acts)
        } else {
            banner.hide()
        }
    }

    // MARK: Window delegate

    func windowWillClose(_ notification: Notification) {
        Self.all.removeAll { $0 === self }
        QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared().orderOut(nil) : ()
        (NSApp.delegate as? AppDelegate)?.windowClosed()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        FileOps.shared.checkClipboardReplaced(window: window)
        AppDelegate.lastActive = self
    }

    // New tab via the "+" button in the tab bar
    @objc override func newWindowForTab(_ sender: Any?) { newTab(nil) }

    func treeExpansionChanged() {
        guard state.prefs.shareTreeExpansion, let tabs = window?.tabbedWindows else { return }
        for t in tabs { if let c = t.windowController as? BrowserWindowController, c !== self { c.tree.expanded = tree.expanded } }
    }

    // MARK: Toolbar

    private enum TB {
        static let sidebar = NSToolbarItem.Identifier("toggleSidebar")
        static let dupWindow = NSToolbarItem.Identifier("dupWindow")
        static let dupTab = NSToolbarItem.Identifier("dupTab")
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let up = NSToolbarItem.Identifier("up")
        static let title = NSToolbarItem.Identifier("title")
        static let newFolder = NSToolbarItem.Identifier("newFolder")
        static let view = NSToolbarItem.Identifier("view")
        static let sort = NSToolbarItem.Identifier("sort")
        static let group = NSToolbarItem.Identifier("group")
        static let remember = NSToolbarItem.Identifier("remember")
        static let search = NSToolbarItem.Identifier("search")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let terminal = NSToolbarItem.Identifier("terminal")
        static let mount = NSToolbarItem.Identifier("mount")
        static let finder = NSToolbarItem.Identifier("finder")
        static let nav = NSToolbarItem.Identifier("navGroup")
        static let viewOptions = NSToolbarItem.Identifier("viewOptionsGroup")
        static let searchButton = NSToolbarItem.Identifier("searchButton")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, TB.sidebar, TB.dupWindow, TB.dupTab, .sidebarTrackingSeparator, TB.nav, TB.title, .flexibleSpace,
         TB.newFolder, TB.viewOptions, TB.searchButton]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [TB.search, TB.remember, TB.back, TB.forward, TB.up, TB.view, TB.sort, TB.group, TB.refresh, TB.terminal, TB.mount, TB.finder, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector, tip: String) -> NSToolbarItem {
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = label
            i.paletteLabel = label
            i.toolTip = tip
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            i.action = action
            i.target = self
            i.isBordered = true
            return i
        }
        func plain(_ i: NSToolbarItem) -> NSToolbarItem { i.isBordered = false; return i }
        switch id {
        case TB.sidebar: return plain(button("Sidebar", "sidebar.leading", #selector(toggleSidebar(_:)), tip: "Toggle sidebar (⌥⌘S)"))
        case TB.dupWindow: return plain(button("Duplicate Window", "macwindow.on.rectangle", #selector(duplicateWindow(_:)), tip: "Open current directory in a new window"))
        case TB.dupTab: return plain(button("Duplicate Tab", "plus.rectangle.on.rectangle", #selector(duplicateTab(_:)), tip: "Open current directory in a new tab"))
        case TB.nav:
            let g = NSToolbarItemGroup(itemIdentifier: id)
            g.subitems = [
                button("Back", "chevron.backward", #selector(goBack(_:)), tip: "Go to the previous folder (⌘[)"),
                button("Forward", "chevron.forward", #selector(goForward(_:)), tip: "Go to the next folder (⌘])"),
                button("Enclosing Folder", "arrow.turn.left.up", #selector(goUp(_:)), tip: "Go to the enclosing folder (⌘↑)"),
            ]
            g.subitems[0].isNavigational = true
            g.label = "Navigate"
            g.paletteLabel = "Back / Forward / Up"
            g.controlRepresentation = .expanded
            return g
        case TB.viewOptions:
            // One capsule holding four momentary segments; the first three open menus, the last toggles Remember.
            let seg = ViewOptionsControl(host: self)
            viewOptionsControl = seg
            let i = NSToolbarItem(itemIdentifier: id)
            i.view = seg
            i.label = "View Options"
            i.toolTip = "View, sorting, grouping and remembered options"
            return i
        case TB.back: return button("Back", "chevron.backward", #selector(goBack(_:)), tip: "Go to the previous folder (⌘[)")
        case TB.forward: return button("Forward", "chevron.forward", #selector(goForward(_:)), tip: "Go to the next folder (⌘])")
        case TB.up: return button("Enclosing Folder", "arrow.turn.left.up", #selector(goUp(_:)), tip: "Go to the enclosing folder (⌘↑)")
        case TB.title:
            let i = NSToolbarItem(itemIdentifier: id)
            let t = TitleView(); t.host = self; t.showsIcon = false
            i.view = t
            i.isBordered = false
            i.label = "Current Folder"
            i.visibilityPriority = .high
            return i
        case TB.newFolder: return button("New Folder", "folder.badge.plus", #selector(newFolder(_:)), tip: "New folder (⇧⌘N)")
        case TB.view:
            let seg = NSSegmentedControl(images: ViewKind.allCases.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)! },
                                         trackingMode: .selectOne, target: self, action: #selector(viewPicked(_:)))
            for (i, k) in ViewKind.allCases.enumerated() { seg.setToolTip("View as \(k.title)", forSegment: i) }
            seg.selectedSegment = ViewKind.allCases.firstIndex(of: state.options.view) ?? 0
            viewPicker = seg
            let i = NSToolbarItem(itemIdentifier: id)
            i.view = seg
            i.label = "View"
            return i
        case TB.sort:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
            i.label = "Sort"
            i.toolTip = "Sorting"
            i.showsIndicator = true
            i.menu = Menus.sortMenu(target: self)
            return i
        case TB.group:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.image = NSImage(systemSymbolName: "square.grid.3x1.below.line.grid.1x2", accessibilityDescription: "Group")
            i.label = "Group"
            i.toolTip = "Grouping"
            i.showsIndicator = true
            i.menu = Menus.groupMenu(target: self)
            return i
        case TB.remember: return button("Remember", "bookmark", #selector(toggleRemember(_:)), tip: "Remember view options for this folder (⌘J)")
        case TB.searchButton:
            // Round magnifier; clicking swaps it for the live search field (like the original).
            return button("Search", "magnifyingglass", #selector(showSearchField(_:)), tip: "Search (⌘F)")
        case TB.search:
            let i = NSSearchToolbarItem(itemIdentifier: id)
            i.searchField.delegate = self
            i.searchField.isEnabled = state.mtpLocation == nil
            i.searchField.sendsWholeSearchString = true
            i.searchField.target = self
            i.searchField.action = #selector(searchSubmitted(_:))
            i.preferredWidthForSearchField = 200
            i.resignsFirstResponderWithCancel = true
            i.visibilityPriority = .low
            i.searchField.controlSize = .large
            searchField = i.searchField
            searchItem = i
            return i
        case TB.refresh: return button("Refresh", "arrow.clockwise", #selector(refresh(_:)), tip: "Refresh (F5)")
        case TB.terminal: return button("Terminal", "terminal", #selector(openTerminalHere(_:)), tip: "Open Terminal at This Folder")
        case TB.mount: return button("Mount Share", "externaldrive.connected.to.line.below", #selector(mountNetworkShare(_:)), tip: "Mount Network Share (⌘K)")
        case TB.finder: return button("Finder", "macwindow", #selector(openInFinder(_:)), tip: "Open This Folder in Finder")
        default: return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case TB.view:
            item.image = NSImage(systemSymbolName: ViewKind.toolbarSymbol(state.options.view), accessibilityDescription: "View")
            return true
        case TB.back: return state.canGoBack
        case TB.forward: return state.canGoForward
        case TB.up: return state.canGoUp
        case TB.newFolder: return state.canWrite && !state.isArchive
        case TB.searchButton, TB.search: return state.mtpLocation == nil
        case TB.terminal, TB.finder: return !state.isDevice && state.currentDirectory.map(LocalFileBoundary.accepts) == true
        case TB.remember:
            item.image = NSImage(systemSymbolName: state.isRemembered ? "bookmark.fill" : "bookmark", accessibilityDescription: nil)
            return state.location.isFileSystem
        default: return true
        }
    }

    @objc func viewPicked(_ sender: NSSegmentedControl) { state.options.view = ViewKind.allCases[sender.selectedSegment] }

    @objc private func searchSubmitted(_ sender: NSSearchField) {
        guard state.mtpLocation == nil else { return }
        state.search(sender.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSSearchField, f === searchField else { return }
        // Live results as you type (debounced) like the original.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(liveSearch), object: nil)
        perform(#selector(liveSearch), with: nil, afterDelay: 0.35)
    }

    @objc private func liveSearch() {
        guard state.mtpLocation == nil else { return }
        if let t = searchField?.stringValue { state.search(t) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSSearchField, f === searchField else { return }
        DispatchQueue.main.async { [weak self] in self?.collapseSearchFieldIfEmpty() }
    }

    // MARK: Opening

    /// Opens items: navigates into folders/archives (first one), opens files with their default apps.
    func open(_ items: [FileItem], newWindow: Bool, newTab: Bool = false) {
        guard !items.isEmpty else { return }
        var files: [FileItem] = []
        var folders: [FileItem] = []
        for it in items {
            if it.mtpAddress != nil || IDeviceRegistry.parseVirtual(it.url) != nil {
                if it.isDirectory { folders.append(it) } else { files.append(it) }
                continue
            }
            guard LocalFileBoundary.accepts(it.url) else { continue }
            if it.archivePath != nil && !it.isDirectory { files.append(it) }
            else if it.isFolder || (it.isSymlink && it.isDirectory) || it.isArchive && state.prefs.openArchives == .within || (it.archivePath != nil && it.isDirectory) || it.isAlias && aliasIsFolder(it.url) {
                folders.append(it)
            } else { files.append(it) }
        }
        if newWindow || newTab {
            for f in folders {
                let loc: Location
                if let address = f.mtpAddress { loc = .mtp(address) }
                else if let (udid, path) = IDeviceRegistry.parseVirtual(f.url) { loc = .device(udid: udid, path: path) }
                else { loc = f.isArchive ? .archive(f.url, inner: "") : .directory(f.url.resolvingSymlinksInPath()) }
                if newTab { AppDelegate.shared.openTab(loc, from: self) } else { AppDelegate.shared.openWindow(loc) }
            }
        } else if let f = folders.first {
            if let address = f.mtpAddress { state.go(.mtp(address)) }
            else { _ = state.navigateInto(f) }
        }
        openFiles(files)
    }

    private func aliasIsFolder(_ u: URL) -> Bool {
        (try? URL(resolvingAliasFileAt: u))?.hasDirectoryPath ?? false
    }

    func openFiles(_ files: [FileItem], with app: URL? = nil) {
        guard !files.isEmpty else { return }
        let remote = files.compactMap(\.mtpAddress)
        if !remote.isEmpty {
            MTPOps.stage(remote, window: window) { urls in
                let configuration = NSWorkspace.OpenConfiguration()
                if let app { NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) }
                else { urls.forEach { NSWorkspace.shared.open($0) } }
            }
        }
        var urls: [URL] = []
        for f in files {
            if f.mtpAddress != nil { continue }
            if let inner = f.archivePath, let a = state.archive {
                if let tmp = try? a.extractToTemp([inner]) { urls.append(tmp.appendingPathComponent(inner)) }
            } else if let (udid, path) = IDeviceRegistry.parseVirtual(f.url) {
                if let out = try? IDeviceRegistry.shared.download(udid: udid, paths: [path], to: AppPaths.temp) { urls += out }
            } else if f.isLocalFile { urls.append(f.url) }
        }
        let cfg = NSWorkspace.OpenConfiguration()
        if let app {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: cfg)
        } else {
            for u in urls { NSWorkspace.shared.open(u) }
        }
    }

    // MARK: Keyboard

    /// Handles keys common to all views. Returns true when consumed.
    func handleKey(_ e: NSEvent, fromTree: Bool = false) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let p = state.prefs
        switch e.keyCode {
        case 36, 76: // return / enter
            if fromTree { return false }
            if mods == [] { p.returnAction == .rename ? renameSelected(nil) : openSelected(nil); return true }
            if mods == .command || mods == .shift { renameSelected(nil); return true }
        case 49: // space
            if mods == [] { quickLook(nil); return true }
        case 120: // F2
            renameSelected(nil); return true
        case 96: // F5
            refresh(nil); return true
        case 51: // delete
            if mods == [] && !fromTree {
                if p.trashWithDelete { moveToTrash(nil); return true }
                if p.backWithDelete { goBack(nil); return true }
            }
        case 117: // forward delete
            if mods == [] { moveToTrash(nil); return true }
            if mods == .option { deletePermanently(nil); return true }
        case 125 where mods == .command: openSelected(nil); return true      // ⌘↓
        case 126 where mods == .command: goUp(nil); return true              // ⌘↑
        case 124 where mods == .command: addToShelf(nil); return true        // ⌘→
        case 123 where mods == .command && NSApp.userInterfaceLayoutDirection == .rightToLeft: addToShelf(nil); return true
        default: break
        }
        return false
    }

    // MARK: Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        updateQuickLook(stageRemote: true)
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }

    func updateQuickLook(stageRemote: Bool = false) {
        let addresses = state.selection.compactMap(\.mtpAddress)
        if !addresses.isEmpty {
            let request = addresses.map(\.id)
            guard request != qlRequest else { return }
            qlItems = []
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
            guard stageRemote || (QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible) else { return }
            qlRequest = request
            MTPOps.stage(addresses, window: window, onFailure: { [weak self] in
                if self?.qlRequest == request { self?.qlRequest = [] }
            }) { [weak self] urls in
                guard let self, self.qlRequest == request, self.state.selection.compactMap(\.mtpAddress).map(\.id) == request else { return }
                self.qlItems = urls
                if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
            }
            return
        }
        qlRequest = []
        qlItems = state.selection.compactMap { it in
            if let inner = it.archivePath, let a = state.archive {
                return (try? a.extractToTemp([inner]))?.appendingPathComponent(inner)
            }
            if let (udid, path) = IDeviceRegistry.parseVirtual(it.url) {
                return (try? IDeviceRegistry.shared.download(udid: udid, paths: [path], to: AppPaths.temp))?.first
            }
            return it.isLocalFile ? it.url : nil
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    // MARK: Rename

    func commitRename(_ url: URL, to name: String) {
        if let address = MTPAddress(url: url) {
            MTPOps.rename(address, to: name, state: state, window: window)
            return
        }
        if let inner = state.selection.first(where: { $0.url == url })?.archivePath {
            Alerts.error("Error while renaming", "Entries inside archives cannot be renamed.", window: window); _ = inner
            return
        }
        if let (udid, path) = IDeviceRegistry.parseVirtual(url) {
            let dest = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
            do { try IDeviceRegistry.shared.rename(udid: udid, from: path, to: dest); state.reload() }
            catch { Alerts.error("Error while renaming", error.localizedDescription, window: window) }
            return
        }
        if let new = FileOps.shared.rename(url, to: name, window: window) {
            state.pendingSelection = [new]
            state.softReload()
        } else {
            fileView.reloadItems()
        }
    }

    func renameViaPrompt(_ url: URL) {
        let address = MTPAddress(url: url)
        if let address, !MTPOps.canMutate(address) { return }
        let name = address?.title ?? url.lastPathComponent
        if let n = Alerts.prompt("Rename", message: "Enter a new name for “\(name)”:", defaultValue: name, ok: "Rename") {
            commitRename(url, to: n)
        }
    }

    // MARK: Network

    func mountShare(_ u: URL) {
        NetworkMounter.mount(u) { [weak self] r in
            switch r {
            case .success(let mps):
                NotificationCenter.default.post(name: .treeNeedsRebuild, object: nil)
                if let m = mps.first { self?.state.go(.directory(m)) }
            case .failure(.cancelled): break
            case .failure(let e): Alerts.error(String(format: "Could not connect to “%@”.", u.host ?? u.absoluteString), e.localizedDescription, window: self?.window)
            }
        }
    }

    func showMountShare(prefill: URL? = nil) {
        MountShareWindow.show(prefill: prefill, host: self)
    }

    func saveSearch() {
        guard case .search(let s) = state.location else { return }
        guard let name = Alerts.prompt("Save Search", message: "Name for the saved search:", defaultValue: s.text, ok: "Save", selectStem: false) else { return }
        let raw = s.rawQuery ?? "(kMDItemFSName = \"*\(s.text)*\"cd)"
        let file = SavedSearchFile.folder.appendingPathComponent(name + ".savedSearch")
        do {
            try SavedSearchFile(rawQuery: raw, scopes: [s.scope.path], displayName: name).write(to: file)
            if let i = state.prefs.sidebarSections.firstIndex(where: { $0.id == "searches" }), state.prefs.sidebarSections[i].disabled {
                var secs = state.prefs.sidebarSections; secs[i].disabled = false; state.prefs.sidebarSections = secs
            }
            NotificationCenter.default.post(name: .treeNeedsRebuild, object: nil)
        } catch { Alerts.error("Error saving file", error.localizedDescription, window: window) }
    }
}

extension BrowserWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { qlItems.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { qlItems[index] as NSURL }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) {
            fileView.view.window?.makeFirstResponder(fileView.view)
            (fileView as? TableViewController)?.table.keyDown(with: event)
            (fileView as? CollectionViewController)?.collection.keyDown(with: event)
            return true
        }
        return false
    }
}
