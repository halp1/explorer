import AppKit
import UniformTypeIdentifiers
import ExplorerKit

enum Menus {
    static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil,
                     symbol: String? = nil, represented: Any? = nil, tag: Int = 0, alternate: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.target = target
        i.representedObject = represented
        i.tag = tag
        if alternate { i.isAlternate = true }
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    // MARK: Sort / group

    static func sortMenu(target: AnyObject?) -> NSMenu {
        let m = NSMenu(title: "Sort")
        m.addItem(withTitle: "Sort by", action: nil, keyEquivalent: "").isEnabled = false
        for k in SortKey.allCases { m.addItem(item(k.title, #selector(BrowserWindowController.setSortKey(_:)), target: target, represented: k.rawValue)) }
        m.addItem(.separator())
        m.addItem(withTitle: "Sort order", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(item("Ascending", #selector(BrowserWindowController.setSortOrder(_:)), target: target, tag: 0))
        m.addItem(item("Descending", #selector(BrowserWindowController.setSortOrder(_:)), target: target, tag: 1))
        m.addItem(.separator())
        m.addItem(item("Group Folders First", #selector(BrowserWindowController.foldersFirst(_:)), "0", target: target))
        m.addItem(item("Group Folders Last", #selector(BrowserWindowController.foldersLast(_:)), "0", [.command, .option], target: target))
        return m
    }

    static func viewKindMenu(target: AnyObject?) -> NSMenu {
        let m = NSMenu(title: "View")
        for (n, k) in ViewKind.allCases.enumerated() {
            let i = item("as \(k.title)", #selector(BrowserWindowController.setViewKind(_:)), String(n + 1), target: target, represented: k.rawValue)
            i.image = NSImage(systemSymbolName: ViewKind.toolbarSymbol(k), accessibilityDescription: nil)
            m.addItem(i)
        }
        return m
    }

    static func groupMenu(target: AnyObject?) -> NSMenu {
        let m = NSMenu(title: "Grouping")
        for k in GroupKey.allCases {
            m.addItem(item(k.title, #selector(BrowserWindowController.setGrouping(_:)), target: target, represented: k.rawValue))
            if k == .none { m.addItem(.separator()) }
        }
        return m
    }

    // MARK: New File submenu

    static func newFileMenu() -> NSMenu {
        let m = NSMenu(title: "New File")
        m.addItem(item("New Empty File...", #selector(BrowserWindowController.newEmptyFile(_:)), "n", [.command, .option]))
        m.addItem(item("New File from Clipboard...", #selector(BrowserWindowController.newFileFromClipboard(_:)), "n", [.command, .control]))
        m.addItem(.separator())
        for t in [DocumentTemplate.word, .excel, .powerpoint, .rtf] {
            m.addItem(item(t.menuTitle, #selector(BrowserWindowController.newDocument(_:)), represented: t.rawValue))
        }
        let apps = NewDocumentViaApp.scriptableApps()
        if !apps.isEmpty {
            m.addItem(.separator())
            for a in apps {
                let i = item(String(format: "New %@ Document...", a.name), #selector(BrowserWindowController.newDocument(_:)), represented: a.url)
                let icon = NSWorkspace.shared.icon(forFile: a.url.path); icon.size = NSSize(width: 16, height: 16)
                i.image = icon
                m.addItem(i)
            }
        }
        return m
    }

    // MARK: Compress submenu

    static func compressMenu() -> NSMenu {
        let m = NSMenu(title: "Compress to")
        for f in ArchiveFormat.creatable {
            m.addItem(item(f.title, #selector(BrowserWindowController.compressTo(_:)), represented: f.rawValue))
        }
        m.addItem(.separator())
        for f in ArchiveFormat.protectable {
            m.addItem(item(String(format: "Protected %@", f.title), #selector(BrowserWindowController.compressTo(_:)), represented: f.rawValue, tag: 1))
        }
        return m
    }

    // MARK: Tags

    static func colorTagsItem(selection: [FileItem]) -> NSMenuItem {
        let i = NSMenuItem()
        let v = TagDotsView(selection: selection)
        v.frame = NSRect(x: 0, y: 0, width: 230, height: 26)
        i.view = v
        return i
    }

    static func textTagsMenu(selection: [FileItem]) -> NSMenu {
        let m = NSMenu(title: "Text Tags & Ratings")
        let tags = Set(Metadata.knownTextTags()).union(selection.flatMap(\.tags)).sorted()
        for t in tags {
            let i = item(t, #selector(BrowserWindowController.toggleTextTag(_:)), represented: t)
            let have = selection.filter { $0.tags.contains(t) }.count
            i.state = have == 0 ? .off : (have == selection.count ? .on : .mixed)
            m.addItem(i)
        }
        m.addItem(item("Add Text Tag...", #selector(BrowserWindowController.addTextTag(_:))))
        m.addItem(.separator())
        for r in 1...5 {
            let stars = String(repeating: "☆", count: 5 - r) + String(repeating: "★", count: r)
            let i = item(stars, #selector(BrowserWindowController.setRating(_:)), String(r), [.command, .control], tag: r)
            i.state = !selection.isEmpty && selection.allSatisfy({ $0.rating == r }) ? .on : .off
            m.addItem(i)
        }
        m.addItem(item("No Rating", #selector(BrowserWindowController.setRating(_:)), "0", [.command, .control], tag: 0))
        return m
    }

    static func iconSizeMenu() -> NSMenu {
        let m = NSMenu(title: "Icons Size")
        for p in IconSizePreset.allCases {
            m.addItem(item("\(p.title) (\(p.rawValue)×\(p.rawValue))", #selector(BrowserWindowController.setIconSize(_:)), tag: p.rawValue))
        }
        return m
    }

    static func sourceControlMenu() -> NSMenu {
        let m = NSMenu(title: "Source Control")
        m.addItem(item("Commit Changes...", #selector(BrowserWindowController.gitCommit(_:))))
        m.addItem(.separator())
        m.addItem(item("Stage Selected", #selector(BrowserWindowController.gitStage(_:))))
        m.addItem(item("Unstage Selected", #selector(BrowserWindowController.gitUnstage(_:))))
        m.addItem(item("Discard Selected Changes", #selector(BrowserWindowController.gitDiscard(_:))))
        m.addItem(.separator())
        m.addItem(item("Stage All", #selector(BrowserWindowController.gitStageAll(_:))))
        m.addItem(item("Unstage All", #selector(BrowserWindowController.gitUnstageAll(_:))))
        m.addItem(.separator())
        m.addItem(item("Pull", #selector(BrowserWindowController.gitPull(_:))))
        m.addItem(item("Push", #selector(BrowserWindowController.gitPush(_:))))
        return m
    }

    static func actionsMenu(selection: [FileItem]) -> NSMenu {
        let m = NSMenu(title: "Actions")
        for a in ActionsStore.shared.items where a.enabled && (selection.isEmpty ? !a.needsSelection : true) {
            m.addItem(item(a.name, #selector(BrowserWindowController.runAction(_:)), represented: a))
        }
        if m.items.isEmpty {
            m.addItem(withTitle: "No actions yet", action: nil, keyEquivalent: "").isEnabled = false
        }
        m.addItem(.separator())
        m.addItem(item("Add / Edit Action", #selector(AppDelegate.showScriptingSettings(_:))))
        return m
    }

    static func shareMenu(_ urls: [URL]) -> NSMenu {
        let m = NSMenu(title: "Share")
        guard urls.allSatisfy(LocalFileBoundary.accepts) else { return m }
        for s in NSSharingService.sharingServices(forItems: urls) {
            let i = NSMenuItem(title: s.menuItemTitle, action: #selector(ShareTarget.share(_:)), keyEquivalent: "")
            i.image = s.image
            i.target = ShareTarget.shared
            i.representedObject = (s, urls)
            m.addItem(i)
        }
        return m
    }
}

final class ShareTarget: NSObject {
    static let shared = ShareTarget()
    @objc func share(_ sender: NSMenuItem) {
        guard let (s, urls) = sender.representedObject as? (NSSharingService, [URL]), urls.allSatisfy(LocalFileBoundary.accepts) else { return }
        s.perform(withItems: urls)
    }
}

/// Seven color dots for the context menu (click toggles the tag for the selection).
final class TagDotsView: NSView {
    let selection: [FileItem]
    init(selection: [FileItem]) { self.selection = selection; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    private func rects() -> [(FinderColor, NSRect)] {
        FinderColor.menuOrder.enumerated().map { i, c in (c, NSRect(x: 20 + CGFloat(i) * 26, y: 5, width: 16, height: 16)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (c, r) in rects() {
            let p = NSBezierPath(ovalIn: r)
            ItemStyle.labelColor(c.rawValue)?.setFill()
            p.fill()
            let have = !selection.isEmpty && selection.allSatisfy { $0.labelNumber == c.rawValue || $0.tags.contains(c.name) || ($0.isLocalFile && Metadata.tags($0.url).contains(c.name)) }
            if have {
                NSColor.white.setStroke()
                let check = NSBezierPath()
                check.lineWidth = 2
                check.move(to: NSPoint(x: r.minX + 4, y: r.midY)); check.line(to: NSPoint(x: r.midX - 1, y: r.minY + 4)); check.line(to: NSPoint(x: r.maxX - 3, y: r.maxY - 4))
                check.stroke()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (c, _) = rects().first(where: { $0.1.insetBy(dx: -4, dy: -4).contains(p) }) else { return }
        let mi = NSMenuItem(); mi.tag = c.rawValue
        if let w = AppDelegate.lastActive { w.toggleColorTag(mi) }
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

// MARK: - Context menus

extension ViewKind {
    static func toolbarSymbol(_ k: ViewKind) -> String {
        switch k { case .icons: return "square.grid.2x2"; case .list: return "list.bullet"; case .table: return "tablecells"; case .gallery: return "rectangle.on.rectangle" }
    }
}

extension BrowserWindowController {
    /// Builds the file-view context menu according to the user's layout (Settings › Context Menu).
    func contextMenu(for selection: [FileItem], inTree: Bool) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = true
        let hasSel = !selection.isEmpty
        let one = selection.count == 1 ? selection[0] : nil
        let isArchive = state.isArchive
        let isResults = state.isSearch || state.isSmart
        let fs = state.location.isFileSystem
        let hasFolderSel = selection.contains { $0.isDirectory }
        let clip = !FileOps.shared.clipboardURLs.isEmpty
        let remote = state.isDevice || selection.contains { !$0.isLocalFile && $0.archivePath == nil }
        let addresses = selection.compactMap(\.mtpAddress)
        let mtp = state.mtpLocation != nil || !addresses.isEmpty
        let mutable = !selection.isEmpty && addresses.count == selection.count && addresses.allSatisfy(MTPOps.canMutate)

        func applicable(_ c: MenuCommand) -> Bool {
            if remote {
                switch c {
                case .open, .quickLook, .copy, .copyAsPath: return hasSel
                case .openInNewWindow, .openInNewTab: return hasFolderSel
                case .newFolder: return !hasSel && state.canWrite
                case .paste: return clip && !hasSel && state.canWrite
                case .pasteIntoFolder:
                    return clip && one?.isDirectory == true && one?.mtpAddress.map(MTPOps.canWrite) == true
                case .rename: return one != nil && (mtp ? mutable : state.deviceLocation != nil)
                case .moveToTrash, .deletePermanently: return mtp ? mutable : hasSel && state.deviceLocation != nil
                case .iconSize: return state.options.view == .icons && !hasSel
                default: return false
                }
            }
            switch c {
            case .newFolder, .newFile: return !hasSel && fs
            case .newFolderWithSelection: return hasSel && fs
            case .goToContainingFolder, .containingFolderNewWindow, .containingFolderNewTab: return hasSel && isResults
            case .connectShare, .pinShare, .unpinShare, .hideShare: return false
            case .open, .quickLook, .copy: return hasSel
            case .openWith: return hasSel && selection.contains { !$0.isFolder } && !isArchive
            case .openInNewWindow, .openInNewTab: return hasFolderSel || selection.contains(where: \.isArchive)
            case .revealOriginal: return one.map { $0.isSymlink || $0.isAlias } ?? false
            case .showPackageContents: return one?.isPackage ?? false
            case .downloadNow: return selection.contains { $0.cloud == .notDownloaded }
            case .removeDownload: return selection.contains { $0.cloud == .current }
            case .moveToTrash, .deletePermanently: return hasSel && !state.isTrash
            case .emptyTrash: return state.isTrash
            case .eject: return selection.contains(where: \.isVolume)
            case .rename: return one != nil && !isArchive
            case .batchRename: return !isArchive && (fs || hasSel)
            case .duplicate, .touch: return hasSel && !isArchive && state.deviceLocation == nil
            case .compress, .compressTo: return hasSel && !isArchive && state.deviceLocation == nil
            case .extract, .extractAll: return isArchive
            case .extractHere: return !isArchive && selection.contains(where: \.isArchive)
            case .cut, .cutViaTrash: return hasSel && !isArchive
            case .copyAsPath: return hasSel || fs
            case .paste: return clip && (fs || isArchive || state.deviceLocation != nil) && !hasSel
            case .moveItemHere, .pasteAsSymlinks, .pasteAsAliases: return clip && fs && !hasSel
            case .pasteIntoFolder: return clip && one?.isDirectory == true
            case .share: return hasSel && !isArchive
            case .addToFavorites: return (one?.isFolder ?? fs) && !Favorites.contains(one?.url ?? state.currentDirectory ?? URL(fileURLWithPath: "/"))
            case .removeFromFavorites: return Favorites.contains(one?.url ?? state.currentDirectory ?? URL(fileURLWithPath: "/"))
            case .makeDefaultFolder, .makeHomeFolder: return inTree
            case .colorTags, .textTagsRatings: return hasSel && !isArchive && state.deviceLocation == nil
            case .revealInFinder: return hasSel && !isArchive
            case .openInFinder: return !hasSel && fs
            case .openTerminalAtFolder: return hasFolderSel && !isArchive
            case .openTerminal: return !hasSel && fs
            case .sourceControl: return state.git != nil
            case .actions: return fs
            case .iconSize: return state.options.view == .icons && !hasSel
            case .calculateSize: return hasFolderSel && fs
            case .services: return hasSel
            }
        }

        var entries = ContextMenuLayout.load().filter { $0.isSeparator || ($0.visible && applicable($0.command!)) }
        entries = ContextMenuLayout.collapseSeparators(entries)
        let showIcons = { (e: ContextMenuEntry) -> Bool in
            if #available(macOS 26.0, *) { return e.iconVisible }
            return false
        }

        let urls = selection.map(\.url)
        for e in entries {
            guard let c = e.command else { m.addItem(.separator()); continue }
            var mi: NSMenuItem
            switch c {
            case .newFolder: mi = Menus.item(c.title, #selector(newFolder(_:)))
            case .newFolderWithSelection: mi = Menus.item(c.title, #selector(newFolderWithSelection(_:)))
            case .newFile: mi = NSMenuItem(title: "New File", action: nil, keyEquivalent: ""); mi.submenu = Menus.newFileMenu()
            case .goToContainingFolder: mi = Menus.item(c.title, #selector(goToContainingFolder(_:)))
            case .containingFolderNewWindow: mi = Menus.item(c.title, #selector(containingFolderNewWindow(_:)))
            case .containingFolderNewTab: mi = Menus.item(c.title, #selector(containingFolderNewTab(_:)))
            case .open: mi = Menus.item(c.title, #selector(openSelected(_:)))
            case .openWith: mi = NSMenuItem(title: "Open With", action: nil, keyEquivalent: ""); mi.submenu = OpenWithMenu.build(for: selection)
            case .openInNewWindow: mi = Menus.item(c.title, #selector(openInNewWindow(_:)))
            case .openInNewTab: mi = Menus.item(c.title, #selector(openInNewTab(_:)))
            case .revealOriginal: mi = Menus.item(c.title, #selector(revealOriginal(_:)))
            case .showPackageContents: mi = Menus.item(c.title, #selector(showPackageContents(_:)))
            case .downloadNow: mi = Menus.item(c.title, #selector(downloadNow(_:)))
            case .removeDownload: mi = Menus.item(c.title, #selector(removeDownload(_:)))
            case .moveToTrash: mi = Menus.item(isArchive ? "Move from Archive to Trash" : (state.isDevice ? "Delete" : c.title), #selector(moveToTrash(_:)))
            case .deletePermanently: mi = Menus.item(c.title, #selector(deletePermanently(_:)))
            case .emptyTrash: mi = Menus.item(c.title, #selector(emptyTrash(_:)))
            case .eject: mi = Menus.item(c.title, #selector(eject(_:)))
            case .rename: mi = Menus.item(c.title, #selector(renameSelected(_:)))
            case .batchRename: mi = Menus.item(c.title, #selector(batchRename(_:)))
            case .duplicate: mi = Menus.item(c.title, #selector(duplicate(_:)))
            case .touch: mi = Menus.item(c.title, #selector(touch(_:)))
            case .compress:
                let f = ArchiveFormat(rawValue: state.prefs.lastCompressFormat) ?? .zip
                mi = Menus.item(String(format: "Compress to %@", f.title), #selector(compress(_:)))
            case .compressTo: mi = NSMenuItem(title: "Compress to", action: nil, keyEquivalent: ""); mi.submenu = Menus.compressMenu()
            case .extract: mi = Menus.item(c.title, #selector(extract(_:)))
            case .extractAll: mi = Menus.item(c.title, #selector(extractAll(_:)))
            case .extractHere: mi = Menus.item(c.title, #selector(extractHere(_:)))
            case .quickLook: mi = Menus.item(c.title, #selector(quickLook(_:)))
            case .cut: mi = Menus.item("Cut", #selector(cutInternal(_:)))
            case .cutViaTrash: mi = Menus.item(state.prefs.cutViaTrash ? "Cut via Trash" : "Cut", #selector(cut(_:)))
            case .copy: mi = Menus.item(c.title, #selector(copy(_:)))
            case .copyAsPath: mi = Menus.item(c.title, #selector(copyAsPath(_:)))
            case .paste: mi = Menus.item(c.title, #selector(paste(_:)))
            case .moveItemHere: mi = Menus.item(FileOps.shared.clipboardURLs.count == 1 ? "Move Item Here" : "Move Items Here", #selector(moveItemHere(_:)))
            case .pasteIntoFolder: mi = Menus.item(c.title, #selector(pasteIntoFolder(_:)))
            case .pasteAsSymlinks: mi = Menus.item(FileOps.shared.clipboardURLs.count == 1 ? "Paste as Symlink" : "Paste as Symlinks", #selector(pasteAsSymlinks(_:)))
            case .pasteAsAliases: mi = Menus.item(FileOps.shared.clipboardURLs.count == 1 ? "Paste as Alias" : "Paste as Aliases", #selector(pasteAsAliases(_:)))
            case .share: mi = NSMenuItem(title: "Share", action: nil, keyEquivalent: ""); mi.submenu = Menus.shareMenu(urls)
            case .addToFavorites, .removeFromFavorites: mi = Menus.item(c.title, #selector(toggleFavorite(_:)))
            case .makeDefaultFolder, .makeHomeFolder: continue  // tree only
            case .colorTags: mi = Menus.colorTagsItem(selection: selection)
            case .textTagsRatings: mi = NSMenuItem(title: c.title, action: nil, keyEquivalent: ""); mi.submenu = Menus.textTagsMenu(selection: selection)
            case .revealInFinder: mi = Menus.item(c.title, #selector(revealInFinder(_:)))
            case .openInFinder: mi = Menus.item("Open This Folder in Finder", #selector(openInFinder(_:)))
            case .openTerminalAtFolder: mi = Menus.item(c.title, #selector(openTerminalAtSelection(_:)))
            case .openTerminal: mi = Menus.item(c.title, #selector(openTerminalHere(_:)))
            case .calculateSize: mi = Menus.item("Calculate Folder Size", #selector(calculateFolderSize(_:)))
            case .sourceControl: mi = NSMenuItem(title: c.title, action: nil, keyEquivalent: ""); mi.submenu = Menus.sourceControlMenu()
            case .actions: mi = NSMenuItem(title: c.title, action: nil, keyEquivalent: ""); mi.submenu = Menus.actionsMenu(selection: realSelectionItems(selection))
            case .iconSize: mi = NSMenuItem(title: c.title, action: nil, keyEquivalent: ""); mi.submenu = Menus.iconSizeMenu()
            case .services:
                mi = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
                let sm = NSMenu(title: "Services")
                mi.submenu = sm
                NSApp.servicesMenu.map { _ in () }
            case .connectShare, .pinShare, .unpinShare, .hideShare: continue
            }
            if mi.target == nil && mi.action != nil { mi.target = self }
            if e.alternate && c.canBeAlternate, let prev = m.items.last, !prev.isSeparatorItem {
                mi.isAlternate = true
                mi.keyEquivalentModifierMask = .option
                mi.keyEquivalent = prev.keyEquivalent
                if prev.keyEquivalent.isEmpty { prev.keyEquivalent = ""; mi.keyEquivalent = "" }
            }
            if showIcons(e), mi.image == nil { mi.image = NSImage(systemSymbolName: c.symbol, accessibilityDescription: nil) }
            m.addItem(mi)
        }
        if !hasSel && !inTree {
            m.addItem(.separator())
            let hint = NSMenuItem(title: "Hold ⌥ option for advanced commands", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            if !state.prefs.hiddenTipIDs.contains("optionHint") { m.addItem(hint) }
        }
        return m
    }

    private func realSelectionItems(_ s: [FileItem]) -> [FileItem] { s.filter(\.isLocalFile) }

    func treeContextMenu(for n: TreeNode) -> NSMenu? {
        let m = NSMenu()
        if let url = n.url, let address = MTPAddress(url: url) {
            // Tree capabilities belong to this node, never the current tab or file selection.
            m.autoenablesItems = false
            m.addItem(Menus.item("Open", #selector(treeOpen(_:)), target: self, represented: url))
            m.addItem(Menus.item("Open in New Window", #selector(treeOpenWindow(_:)), target: self, represented: url))
            m.addItem(Menus.item("Open in New Tab", #selector(treeOpenTab(_:)), target: self, represented: url))
            m.addItem(.separator())
            if MTPOps.canWrite(address) {
                m.addItem(Menus.item("New Folder Inside...", #selector(treeNewFolder(_:)), target: self, represented: url))
                if !FileOps.shared.clipboardURLs.isEmpty { m.addItem(Menus.item("Paste into Folder", #selector(treePaste(_:)), target: self, represented: url)) }
            }
            if address.storageID != nil {
                m.addItem(Menus.item("Copy", #selector(treeCopy(_:)), target: self, represented: url))
            }
            m.addItem(Menus.item("Copy as Path", #selector(treeCopyPath(_:)), target: self, represented: url))
            if MTPOps.canMutate(address) {
                m.addItem(Menus.item("Rename...", #selector(treeRename(_:)), target: self, represented: url))
                m.addItem(Menus.item("Delete Permanently...", #selector(treeTrash(_:)), target: self, represented: url))
            }
            return m
        }
        switch n.kind {
        case .share(let s):
            m.addItem(Menus.item("Connect...", #selector(treeConnect(_:)), target: self, represented: s.url))
            m.addItem(Menus.item("Unpin", #selector(treePin(_:)), target: self, represented: s.url, tag: 0))
            m.addItem(Menus.item("Hide", #selector(treeHideShare(_:)), target: self, represented: s.url))
            return m
        case .folder(let u):
            m.addItem(Menus.item("Open", #selector(treeOpen(_:)), target: self, represented: u))
            m.addItem(Menus.item("Open in New Window", #selector(treeOpenWindow(_:)), target: self, represented: u))
            m.addItem(Menus.item("Open in New Tab", #selector(treeOpenTab(_:)), target: self, represented: u))
            m.addItem(.separator())
            m.addItem(Menus.item("New Folder Inside...", #selector(treeNewFolder(_:)), target: self, represented: u))
            if n.isVolume, n.sectionID == "nd" {
                let share = RecentSharesStore.shared.items.first { NetworkMounter.mountPoint(for: $0.url)?.path == u.path }
                if let share {
                    m.addItem(Menus.item(share.pinned ? "Unpin" : "Pin", #selector(treePin(_:)), target: self, represented: share.url, tag: share.pinned ? 0 : 1))
                    m.addItem(Menus.item("Hide", #selector(treeHideShare(_:)), target: self, represented: share.url))
                }
            }
            if n.ejectable { m.addItem(Menus.item("Eject", #selector(treeEject(_:)), target: self, represented: u)) }
            m.addItem(.separator())
            m.addItem(Menus.item("Copy", #selector(treeCopy(_:)), target: self, represented: u))
            m.addItem(Menus.item("Copy as Path", #selector(treeCopyPath(_:)), target: self, represented: u, alternate: false))
            if FileOps.shared.canPaste { m.addItem(Menus.item("Paste into Folder", #selector(treePaste(_:)), target: self, represented: u)) }
            m.addItem(Menus.item("Move to Trash", #selector(treeTrash(_:)), target: self, represented: u))
            m.addItem(.separator())
            if Favorites.contains(u) || n.isFavorite {
                m.addItem(Menus.item("Remove from Favorites", #selector(treeFavorite(_:)), target: self, represented: u))
            } else {
                m.addItem(Menus.item("Add to Favorites", #selector(treeFavorite(_:)), target: self, represented: u))
            }
            m.addItem(Menus.item("Make Default Folder", #selector(treeMakeDefault(_:)), target: self, represented: u))
            m.addItem(Menus.item("Make Home Folder", #selector(treeMakeHome(_:)), target: self, represented: u, alternate: false))
            m.items.last?.isAlternate = true
            m.items.last?.keyEquivalentModifierMask = .option
            m.addItem(.separator())
            m.addItem(Menus.item("Open in Finder", #selector(treeFinder(_:)), target: self, represented: u))
            m.addItem(Menus.item("Open Terminal at Folder", #selector(treeTerminal(_:)), target: self, represented: u))
            m.addItem(.separator())
            m.addItem(Menus.item("Open Tree Settings...", #selector(AppDelegate.showTreeSettings(_:))))
            return m
        case .section:
            m.addItem(Menus.item("Open Tree Settings...", #selector(AppDelegate.showSidebarSettings(_:))))
            if case .section("nd") = n.kind { m.addItem(Menus.item("Mount Network Share...", #selector(mountNetworkShare(_:)), target: self)) }
            if case .section("trash") = n.kind { m.addItem(Menus.item("Empty Trash", #selector(emptyTrash(_:)), target: self)) }
            return m
        case .trash:
            m.addItem(Menus.item("Empty Trash", #selector(emptyTrash(_:)), target: self))
            return m
        default: return nil
        }
    }

    private func treeLocation(_ url: URL) -> Location? {
        if let address = MTPAddress(url: url) { return .mtp(address) }
        guard LocalFileBoundary.accepts(url) else { return nil }
        return TreeNode(.folder(url), title: "").location
    }

    @objc func treeOpen(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let location = treeLocation(url) else { return }
        state.go(location)
    }
    @objc func treeOpenWindow(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let location = treeLocation(url) else { return }
        AppDelegate.shared.openWindow(location)
    }
    @objc func treeOpenTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let location = treeLocation(url) else { return }
        AppDelegate.shared.openTab(location, from: self)
    }
    @objc func treeRename(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        renameViaPrompt(url)
    }
    @objc func treeNewFolder(_ s: NSMenuItem) { if let u = s.representedObject as? URL { createFolder(withSelection: false, inside: u); tree.rebuild() } }
    @objc func treeEject(_ s: NSMenuItem) { if let u = s.representedObject as? URL { VolumeOps.eject(u, window: window) } }
    @objc func treeCopy(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let address = MTPAddress(url: url) { MTPOps.copy([address], window: window) }
        else { FileOps.shared.copy([url]) }
    }
    @objc func treeCopyPath(_ s: NSMenuItem) { if let u = s.representedObject as? URL { FileOps.shared.copyPaths([u]) } }
    @objc func treePaste(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let address = MTPAddress(url: url) {
            MTPOps.upload(FileOps.shared.clipboardURLs, to: address, state: state, window: window)
        } else { FileOps.shared.paste(into: url, window: window) }
    }
    @objc func treeTrash(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let address = MTPAddress(url: url) { MTPOps.remove([address], state: state, window: window) }
        else { FileOps.shared.moveToTrash([url], window: window) }
    }
    @objc func treeFavorite(_ s: NSMenuItem) {
        guard let u = s.representedObject as? URL, LocalFileBoundary.accepts(u) else { return }
        if Favorites.contains(u) { try? Favorites.remove(u) } else { try? Favorites.add(u) }
        tree.rebuild()
    }
    @objc func treeMakeDefault(_ s: NSMenuItem) { if let u = s.representedObject as? URL { makeDefaultFolder(u) } }
    @objc func treeMakeHome(_ s: NSMenuItem) { if let u = s.representedObject as? URL { makeHomeFolder(u) } }
    @objc func treeFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, LocalFileBoundary.accepts(url) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc func treeTerminal(_ s: NSMenuItem) { if let u = s.representedObject as? URL { Terminal.open(u) } }
    @objc func treeConnect(_ s: NSMenuItem) { if let str = s.representedObject as? String, let u = URL(string: str) { mountShare(u) } }
    @objc func treePin(_ s: NSMenuItem) {
        guard let str = s.representedObject as? String, let i = RecentSharesStore.shared.items.firstIndex(where: { $0.url == str }) else { return }
        RecentSharesStore.shared.items[i].pinned = s.tag == 1
        tree.rebuild()
    }
    @objc func treeHideShare(_ s: NSMenuItem) {
        guard let str = s.representedObject as? String, let i = RecentSharesStore.shared.items.firstIndex(where: { $0.url == str }) else { return }
        RecentSharesStore.shared.items[i].hidden = true
        tree.rebuild()
    }
}

// MARK: - Open With

enum OpenWithMenu {
    static func build(for items: [FileItem]) -> NSMenu {
        let m = NSMenu(title: "Open With")
        let urls = items.map(\.url)
        guard let first = urls.first else { return m }
        let def = NSWorkspace.shared.urlForApplication(toOpen: first)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        for u in urls.dropFirst() {
            let set = Set(NSWorkspace.shared.urlsForApplications(toOpen: u))
            apps = apps.filter(set.contains)
        }
        let type = items.first?.typeIdentifier
        for a in OpenWithStore.shared.items where (a.typeIdentifier == nil || a.typeIdentifier == type) {
            let u = URL(fileURLWithPath: a.appPath)
            if !apps.contains(u) && FileManager.default.fileExists(atPath: a.appPath) { apps.append(u) }
        }
        func add(_ app: URL, isDefault: Bool) {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            let i = Menus.item(isDefault ? "\(name) (default)" : name, #selector(BrowserWindowController.openWithApp(_:)), represented: app)
            let icon = NSWorkspace.shared.icon(forFile: app.path); icon.size = NSSize(width: 16, height: 16)
            i.image = icon
            m.addItem(i)
        }
        if let def { add(def, isDefault: true); m.addItem(.separator()) }
        for a in apps.filter({ $0 != def }).sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            add(a, isDefault: false)
        }
        m.addItem(.separator())
        m.addItem(Menus.item("Other...", #selector(BrowserWindowController.openWithOther(_:))))
        return m
    }

    static func offerToAdd(app: URL, items: [FileItem], window: NSWindow?) {
        let name = app.deletingPathExtension().lastPathComponent
        guard !OpenWithStore.shared.items.contains(where: { $0.appPath == app.path }) else { return }
        let a = NSAlert()
        a.messageText = String(format: "Add “%@” to the Open With menu?", name)
        a.informativeText = "The app will be listed for this file type. Add it only if the document actually opened."
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Add for All Types")
        a.addButton(withTitle: "Don’t Add")
        switch a.runModal() {
        case .alertFirstButtonReturn: OpenWithStore.shared.items.append(OpenWithAddition(appPath: app.path, typeIdentifier: items.first?.typeIdentifier))
        case .alertSecondButtonReturn: OpenWithStore.shared.items.append(OpenWithAddition(appPath: app.path, typeIdentifier: nil))
        default: break
        }
    }

    static func recordUse(app: URL, items: [FileItem], window: NSWindow?) {}
}

// MARK: - New document via scriptable apps (Pages/Numbers/Keynote/TextEdit…)

enum NewDocumentViaApp {
    struct App { var name: String; var url: URL; var ext: String }

    static func scriptableApps() -> [App] {
        let known: [(String, String, String)] = [
            ("com.apple.iWork.Pages", "Pages", "pages"), ("com.apple.iWork.Numbers", "Numbers", "numbers"),
            ("com.apple.iWork.Keynote", "Keynote", "key"), ("com.apple.TextEdit", "TextEdit", "rtf"),
        ]
        return known.compactMap { id, name, ext in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { App(name: name, url: $0, ext: ext) }
        }
    }

    static func create(app: URL, in dir: URL?, window: NSWindow?, done: @escaping (URL) -> Void) {
        guard let dir, LocalFileBoundary.accepts(dir), let a = scriptableApps().first(where: { $0.url == app }) else { return }
        let suggested = FileNaming.uniqueURL(in: dir, name: "Untitled." + a.ext).lastPathComponent
        guard let name = Alerts.prompt(String(format: "New %@ Document", a.name), message: String(format: "A new empty document will be created inside “%@”", FileNaming.displayName(of: dir)), defaultValue: suggested, ok: "Create") else { return }
        let dest = dir.appendingPathComponent(name)
        guard let bid = Bundle(url: app)?.bundleIdentifier else { return }
        let script = """
        tell application id "\(bid)"
            activate
            set d to make new document
            save d in POSIX file \(ActionRunner.appleScriptQuote(dest.path))
        end tell
        """
        DispatchQueue.global().async {
            let out = ActionRunner.runAppleScript(script)
            DispatchQueue.main.async {
                if out.status == 0 { FileOps.shared.history.record("Create File", .created([dest])); done(dest) }
                else { Alerts.error("The AppleScript could not be completed.", out.log, window: window) }
            }
        }
    }
}
