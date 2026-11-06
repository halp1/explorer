import AppKit
import ExplorerKit

/// The menu bar: Explorer, File, Edit, View, Go, Source Control, Window, Help.
enum MainMenu {
    typealias B = BrowserWindowController
    typealias A = AppDelegate

    static func i(_ t: String, _ a: Selector?, _ k: String = "", _ m: NSEvent.ModifierFlags = [.command], alt: Bool = false, tag: Int = 0, rep: Any? = nil) -> NSMenuItem {
        Menus.item(t, a, k, m, represented: rep, tag: tag, alternate: alt)
    }

    static func key(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }

    static func build() -> NSMenu {
        let main = KeyboardMenu()
        main.addItem(sub(appMenu()))
        main.addItem(sub(fileMenu()))
        main.addItem(sub(editMenu()))
        main.addItem(sub(viewMenu()))
        main.addItem(sub(goMenu()))
        main.addItem(sub(scmMenu()))
        let window = windowMenu()
        main.addItem(sub(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(sub(help))
        NSApp.helpMenu = help
        return main
    }

    static func sub(_ m: NSMenu) -> NSMenuItem { let it = NSMenuItem(title: m.title, action: nil, keyEquivalent: ""); it.submenu = m; return it }

    static func appMenu() -> NSMenu {
        let m = NSMenu(title: "Explorer")
        m.addItem(i("About Explorer", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        m.addItem(.separator())
        m.addItem(i("Settings…", #selector(A.showSettings(_:)), ","))
        m.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let si = NSMenuItem(title: "Services", action: nil, keyEquivalent: ""); si.submenu = services
        m.addItem(si)
        m.addItem(.separator())
        m.addItem(i("Hide Explorer", #selector(NSApplication.hide(_:)), "h"))
        m.addItem(i("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(i("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(i("Quit Explorer", #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    static func fileMenu() -> NSMenu {
        let m = NSMenu(title: "File")
        m.addItem(i("New Window", #selector(A.newWindow(_:)), "n"))
        m.addItem(i("New Tab", #selector(A.newTabGlobal(_:)), "t"))
        m.addItem(i("New Folder...", #selector(B.newFolder(_:)), "n", [.command, .shift]))
        m.addItem(i("New Folder with Selection...", #selector(B.newFolderWithSelection(_:)), "n", [.command, .control, .shift]))
        let nf = NSMenuItem(title: "New File", action: nil, keyEquivalent: ""); nf.submenu = Menus.newFileMenu(); m.addItem(nf)
        m.addItem(.separator())
        m.addItem(i("Open", #selector(B.openSelected(_:)), "o"))
        m.addItem(i("Open in New Window", #selector(B.openInNewWindow(_:)), "o", [.command, .option]))
        m.addItem(i("Open in New Tab", #selector(B.openInNewTab(_:)), "o", [.command, .control]))
        let ow = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        ow.submenu = DynamicMenu(title: "Open With") {
            guard let controller = AppDelegate.lastActive, !controller.hasTreeFocus else { return [] }
            return OpenWithMenu.build(for: controller.state.selection).items
        }
        m.addItem(ow)
        m.addItem(.separator())
        m.addItem(i("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        m.addItem(i("Close All Windows", #selector(A.closeAllWindows(_:)), "w", [.command, .option], alt: true))
        m.addItem(.separator())
        let trash = i("Move to Trash", #selector(B.moveToTrash(_:)), key(NSBackspaceCharacter), [.command])
        m.addItem(trash)
        m.addItem(i("Delete Permanently", #selector(B.deletePermanently(_:)), key(NSBackspaceCharacter), [.command, .option], alt: true))
        m.addItem(i("Eject", #selector(B.eject(_:)), "e"))
        m.addItem(i("Rename", #selector(B.renameSelected(_:))))
        m.addItem(i("Batch Rename...", #selector(B.batchRename(_:))))
        m.addItem(i("Duplicate", #selector(B.duplicate(_:)), "d"))
        m.addItem(i("Touch", #selector(B.touch(_:))))
        m.addItem(i("Compress to ZIP", #selector(B.compress(_:))))
        let ct = NSMenuItem(title: "Compress to", action: nil, keyEquivalent: ""); ct.submenu = Menus.compressMenu(); m.addItem(ct)
        m.addItem(i("Extract", #selector(B.extract(_:)), "r"))
        m.addItem(i("Extract Here", #selector(B.extractHere(_:))))
        m.addItem(.separator())
        m.addItem(i("Quick Look", #selector(B.quickLook(_:)), "y"))
        let share = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        share.submenu = DynamicMenu(title: "Share") {
            guard let controller = AppDelegate.lastActive, !controller.hasTreeFocus else { return [] }
            return Menus.shareMenu(controller.state.selectedURLs).items
        }
        m.addItem(share)
        m.addItem(.separator())
        m.addItem(i("Add to Favorites", #selector(B.toggleFavorite(_:)), "t", [.command, .control]))
        let tags = NSMenuItem(title: "Text Tags & Ratings", action: nil, keyEquivalent: "")
        tags.submenu = DynamicMenu(title: "Text Tags & Ratings") { Menus.textTagsMenu(selection: AppDelegate.lastActive?.state.selection ?? []).items }
        m.addItem(tags)
        for r in 0...5 { // hidden items so ⌃⌘0–5 work even when the submenu was never opened
            let it = i(r == 0 ? "No Rating" : String(repeating: "★", count: r), #selector(B.setRating(_:)), String(r), [.command, .control], tag: r)
            it.isHidden = true
            it.allowsKeyEquivalentWhenHidden = true
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(i("Open Terminal", #selector(B.openTerminalHere(_:))))
        m.addItem(i("Find", #selector(B.performFind(_:)), "f"))
        m.addItem(.separator())
        m.addItem(i("Empty Trash", #selector(B.emptyTrash(_:)), key(NSBackspaceCharacter), [.command, .shift]))
        m.addItem(i("Empty Private Trash", #selector(A.emptyPrivateTrashGlobal(_:))))
        return m
    }

    static func editMenu(undoTarget: UndoMenuTarget = .shared) -> NSMenu {
        let m = NSMenu(title: "Edit")
        m.addItem(Menus.item("Undo", #selector(UndoMenuTarget.undo(_:)), "z", target: undoTarget))
        m.addItem(Menus.item("Redo", #selector(UndoMenuTarget.redo(_:)), "z", [.command, .shift], target: undoTarget))
        m.addItem(.separator())
        m.addItem(i("Cut via Trash", #selector(B.cut(_:)), "x"))
        m.addItem(i("Cut", #selector(B.cutInternal(_:)), "x", [.command, .option], alt: true))
        m.addItem(i("Copy", #selector(B.copy(_:)), "c"))
        m.addItem(i("Copy as Path", #selector(B.copyAsPath(_:)), "c", [.command, .option], alt: true))
        m.addItem(i("Paste", #selector(B.paste(_:)), "v"))
        m.addItem(i("Move Item Here", #selector(B.moveItemHere(_:)), "v", [.command, .option], alt: true))
        m.addItem(i("Paste as Symlinks", #selector(B.pasteAsSymlinks(_:)), "v", [.command, .shift], alt: true))
        m.addItem(i("Paste as Aliases", #selector(B.pasteAsAliases(_:)), "v", [.command, .control], alt: true))
        m.addItem(i("Paste into Folder", #selector(B.pasteIntoFolder(_:))))
        m.addItem(i("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        m.addItem(i("Deselect All", #selector(B.deselectAll(_:)), "a", [.command, .option]))
        m.addItem(.separator())
        let shelfArrow = NSApp.userInterfaceLayoutDirection == .rightToLeft ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey
        m.addItem(i("Add to Shelf", #selector(B.addToShelf(_:)), key(shelfArrow), [.command]))
        return m
    }

    static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "View")
        for (n, k) in ViewKind.allCases.enumerated() {
            m.addItem(i("as \(k.title)", #selector(B.setViewKind(_:)), String(n + 1), rep: k.rawValue))
        }
        m.addItem(.separator())
        let sort = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: ""); sort.submenu = Menus.sortMenu(target: nil); m.addItem(sort)
        let grp = NSMenuItem(title: "Group by", action: nil, keyEquivalent: ""); grp.submenu = Menus.groupMenu(target: nil); m.addItem(grp)
        m.addItem(i("Group Folders First", #selector(B.foldersFirst(_:)), "0"))
        m.addItem(i("Group Folders Last", #selector(B.foldersLast(_:)), "0", [.command, .option]))
        m.addItem(.separator())
        m.addItem(i("Show Sidebar", #selector(B.toggleSidebar(_:)), "s", [.command, .option]))
        m.addItem(i("Show Path Bar", #selector(B.togglePathBar(_:)), "p", [.command, .option]))
        m.addItem(i("Show Status Bar", #selector(B.toggleStatusBar(_:)), "/"))
        m.addItem(i("Show Action Bar", #selector(B.toggleActionBar(_:)), "/", [.command, .option]))
        m.addItem(i("Show Shelf", #selector(B.toggleShelf(_:))))
        m.addItem(.separator())
        m.addItem(i("Show Hidden Files", #selector(B.toggleHidden(_:)), "."))
        m.addItem(i("Show Thumbnails in This View", #selector(B.toggleThumbnails(_:))))
        m.addItem(i("Show Item Traits", #selector(B.toggleTraits(_:))))
        m.addItem(i("Show Time in Dates", #selector(B.toggleTimeInDates(_:))))
        m.addItem(i("Show File Info", #selector(B.toggleInfo(_:)), "i"))
        m.addItem(.separator())
        m.addItem(i("Show Hidden Folders in Tree View", #selector(B.toggleHiddenInTree(_:))))
        m.addItem(i("Show Packages in Tree View", #selector(B.togglePackagesInTree(_:))))
        m.addItem(i("Show Archives in Tree View", #selector(B.toggleArchivesInTree(_:))))
        m.addItem(.separator())
        m.addItem(i("Zoom In", #selector(B.zoomIn(_:)), "="))
        m.addItem(i("Zoom Out", #selector(B.zoomOut(_:)), "-"))
        m.addItem(i("Calculate All Folder Sizes", #selector(B.calculateFolderSize(_:))))
        m.addItem(i("Refresh", #selector(B.refresh(_:)), key(NSF5FunctionKey), []))
        m.addItem(.separator())
        m.addItem(i("Remember View Options for This Folder", #selector(B.toggleRemember(_:)), "j"))
        let enc = NSMenuItem(title: "Filename Encoding", action: nil, keyEquivalent: "")
        let em = NSMenu(title: "Filename Encoding")
        em.addItem(i("Automatic", #selector(B.setArchiveEncoding(_:))))
        for e in ["UTF-8", "CP437", "CP866", "CP1251", "CP1252", "Shift_JIS", "GBK", "Big5", "EUC-KR", "KOI8-R", "ISO-8859-1"] {
            em.addItem(i(e, #selector(B.setArchiveEncoding(_:)), rep: e))
        }
        enc.submenu = em
        m.addItem(enc)
        return m
    }

    static func goMenu() -> NSMenu {
        let m = NSMenu(title: "Go")
        m.addItem(i("Back", #selector(B.goBack(_:)), "["))
        m.addItem(i("Forward", #selector(B.goForward(_:)), "]"))
        m.addItem(i("Enclosing Folder", #selector(B.goUp(_:)), key(NSUpArrowFunctionKey)))
        m.addItem(i("Home", #selector(B.goHome(_:)), "h", [.command, .shift]))
        let recent = NSMenuItem(title: "Recent Folders", action: nil, keyEquivalent: "")
        recent.submenu = DynamicMenu(title: "Recent Folders") {
            let h = Preferences.shared.history
            if h.isEmpty { let x = NSMenuItem(title: "Nothing to show", action: nil, keyEquivalent: ""); x.isEnabled = false; return [x] }
            return h.map { p in
                let it = Menus.item(FileManager.default.displayName(atPath: p), #selector(B.goRecent(_:)), represented: p)
                let icon = NSWorkspace.shared.icon(forFile: p); icon.size = NSSize(width: 16, height: 16); it.image = icon
                it.toolTip = p
                return it
            }
        }
        m.addItem(recent)
        m.addItem(i("Go to Folder", #selector(B.goToFolder(_:)), "g", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(i("Mount Network Share...", #selector(B.mountNetworkShare(_:)), "k"))
        m.addItem(i("Remount All Pinned Shares...", #selector(B.remountPinned(_:))))
        return m
    }

    static func scmMenu() -> NSMenu { let m = Menus.sourceControlMenu(); m.title = "Source Control"; return m }

    static func windowMenu() -> NSMenu {
        let m = NSMenu(title: "Window")
        m.addItem(i("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(i("Zoom", #selector(NSWindow.performZoom(_:))))
        m.addItem(i("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(i("Duplicate Window", #selector(B.duplicateWindow(_:))))
        m.addItem(i("Duplicate Tab", #selector(B.duplicateTab(_:))))
        m.addItem(i("Customize This Tab...", #selector(B.customizeTab(_:))))
        m.addItem(.separator())
        m.addItem(i("Save Tab Set...", #selector(B.saveTabSet(_:))))
        let load = NSMenuItem(title: "Load Tab Set", action: nil, keyEquivalent: "")
        load.submenu = DynamicMenu(title: "Load Tab Set") {
            let sets = TabSetStore.shared.items
            if sets.isEmpty { let x = NSMenuItem(title: "No saved tab sets.", action: nil, keyEquivalent: ""); x.isEnabled = false; return [x] }
            return sets.map { Menus.item($0.name, #selector(A.loadTabSet(_:)), represented: $0) }
        }
        m.addItem(load)
        m.addItem(i("Manage Tab Sets...", #selector(B.manageTabSets(_:))))
        m.addItem(.separator())
        m.addItem(i("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return m
    }

    static func helpMenu() -> NSMenu {
        let m = NSMenu(title: "Help")
        m.addItem(i("User’s Guide", #selector(A.showUserGuide(_:))))
        m.addItem(i("Keyboard Shortcuts", #selector(A.showKeyboardShortcuts(_:))))
        m.addItem(.separator())
        m.addItem(i("Acknowledgments...", #selector(A.showAcknowledgments(_:))))
        return m
    }
}

/// A menu whose items are rebuilt each time it opens.
final class DynamicMenu: NSMenu, NSMenuDelegate {
    let builder: () -> [NSMenuItem]
    init(title: String, builder: @escaping () -> [NSMenuItem]) {
        self.builder = builder
        super.init(title: title)
        delegate = self
    }
    required init(coder: NSCoder) { fatalError() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        for it in builder() { addItem(it) }
    }
}
