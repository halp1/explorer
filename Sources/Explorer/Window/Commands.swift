import AppKit
import Quartz
import UniformTypeIdentifiers
import ExplorerKit

/// All window-level commands (menu bar, toolbar, context menus, shortcuts).
extension BrowserWindowController {
    var sel: [FileItem] { state.selection }
    var selURLs: [URL] { state.selectedURLs }
    var ops: FileOps { .shared }
    /// Targets for commands that work on "selection, or current folder when nothing is selected".
    var selOrCurrent: [URL] { selURLs.isEmpty ? (state.currentDirectory.map { [$0] } ?? []) : selURLs }
    var realSelection: [URL] { sel.filter { $0.archivePath == nil && IDeviceRegistry.parseVirtual($0.url) == nil }.map(\.url) }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasSel = !sel.isEmpty
        let fs = state.location.isFileSystem
        let writable = state.canWrite
        switch item.action {
        case #selector(goBack(_:)): return state.canGoBack
        case #selector(goForward(_:)): return state.canGoForward
        case #selector(goUp(_:)): return state.canGoUp
        case #selector(newFolder(_:)), #selector(newEmptyFile(_:)), #selector(newFileFromClipboard(_:)), #selector(newDocument(_:)):
            return writable && (fs || state.deviceLocation != nil)
        case #selector(newFolderWithSelection(_:)): return writable && fs && hasSel
        case #selector(openSelected(_:)), #selector(quickLook(_:)), #selector(copy(_:)), #selector(copyAsPath(_:)), #selector(addToShelf(_:)):
            return hasSel
        case #selector(openInNewWindow(_:)), #selector(openInNewTab(_:)): return sel.contains { $0.isDirectory || $0.isArchive }
        case #selector(moveToTrash(_:)), #selector(deletePermanently(_:)), #selector(cut(_:)), #selector(cutInternal(_:)):
            return hasSel && (fs || state.isArchive || state.isSearch || state.isSmart || state.deviceLocation != nil || state.isTrash)
        case #selector(duplicate(_:)), #selector(touch(_:)), #selector(compress(_:)): return !realSelection.isEmpty
        case #selector(renameSelected(_:)): return hasSel || fs
        case #selector(batchRename(_:)): return fs || !realSelection.isEmpty
        case #selector(paste(_:)), #selector(moveItemHere(_:)), #selector(pasteAsSymlinks(_:)), #selector(pasteAsAliases(_:)):
            return (writable || state.deviceLocation != nil) && !ops.clipboardURLs.isEmpty && (item.action == #selector(paste(_:)) || fs)
        case #selector(pasteIntoFolder(_:)): return sel.count == 1 && sel[0].isDirectory && !ops.clipboardURLs.isEmpty
        case #selector(extract(_:)): return state.isArchive || sel.contains { $0.isArchive }
        case #selector(extractAll(_:)): return state.isArchive || sel.contains { $0.isArchive }
        case #selector(eject(_:)): return (sel.first?.isVolume ?? false) || state.location.url.map { Volumes.volume(containing: $0).map { !$0.isRoot && ($0.isEjectable || $0.isNetwork) } ?? false } ?? false
        case #selector(toggleRemember(_:)):
            item.state = state.isRemembered ? .on : .off
            return fs
        case #selector(setViewKind(_:)):
            item.state = (item.representedObject as? String) == state.options.view.rawValue ? .on : .off
            return true
        case #selector(setSortKey(_:)):
            item.state = (item.representedObject as? String) == state.options.sortKey.rawValue ? .on : .off
            return true
        case #selector(setSortOrder(_:)):
            item.state = (item.tag == 0) == (state.options.sortOrder == .ascending) ? .on : .off
            item.title = item.tag == 0 ? state.options.sortKey.orderTitles.asc : state.options.sortKey.orderTitles.desc
            return true
        case #selector(setGrouping(_:)):
            item.state = (item.representedObject as? String) == state.options.grouping.rawValue ? .on : .off
            return true
        case #selector(foldersFirst(_:)):
            item.state = state.options.folders == .first ? .on : .off; return true
        case #selector(foldersLast(_:)):
            item.state = state.options.folders == .last ? .on : .off; return true
        case #selector(toggleHidden(_:)):
            item.title = state.options.showHidden ? "Hide Hidden Files" : "Show Hidden Files"; return true
        case #selector(toggleThumbnails(_:)):
            item.title = state.options.showThumbnails ? "Hide Thumbnails in This View" : "Show Thumbnails in This View"; return true
        case #selector(toggleInfo(_:)):
            item.title = state.options.showInfo ? "Hide File Info" : "Show File Info"; return true
        case #selector(toggleTraits(_:)):
            item.title = state.options.showTraits ? "Hide Item Traits" : "Show Item Traits"
            return state.options.view == .icons || state.options.view == .gallery
        case #selector(toggleSidebar(_:)):
            item.title = treeItemCollapsed ? "Show Sidebar" : "Hide Sidebar"; return true
        case #selector(togglePathBar(_:)):
            item.title = state.prefs.showPathBar ? "Hide Path Bar" : "Show Path Bar"; return true
        case #selector(toggleStatusBar(_:)):
            item.title = state.prefs.showStatusBar ? "Hide Status Bar" : "Show Status Bar"; return true
        case #selector(toggleActionBar(_:)):
            item.title = state.prefs.showActionToolbar ? "Hide Action Toolbar" : "Show Action Toolbar"; return true
        case #selector(toggleTimeInDates(_:)):
            item.title = state.prefs.showTimeInDates ? "Hide Time in Dates" : "Show Time in Dates"; return true
        case #selector(toggleArchivesInTree(_:)):
            item.title = state.prefs.showArchivesInTree ? "Hide Archives in Tree View" : "Show Archives in Tree View"; return true
        case #selector(togglePackagesInTree(_:)):
            item.title = state.prefs.showPackagesInTree ? "Hide Packages in Tree View" : "Show Packages in Tree View"; return true
        case #selector(toggleHiddenInTree(_:)):
            item.title = state.prefs.showHiddenInTree ? "Hide Hidden Folders in Tree View" : "Show Hidden Folders in Tree View"; return true
        case #selector(toggleShelf(_:)):
            item.title = state.prefs.showShelf ? "Hide Shelf" : "Show Shelf"; return true
        case #selector(toggleFavorite(_:)):
            let t = sel.count == 1 ? sel[0].url : state.currentDirectory
            item.title = t.map(Favorites.contains) == true ? "Remove from Favorites" : "Add to Favorites"
            return sel.isEmpty ? fs : sel.allSatisfy { $0.isDirectory && $0.archivePath == nil }
        case #selector(setRating(_:)), #selector(addTextTag(_:)), #selector(toggleColorTag(_:)), #selector(toggleTextTag(_:)):
            return !realSelection.isEmpty
        case #selector(undo(_:)):
            item.title = ops.history.undoTitle.map { "Undo \($0)" } ?? "Undo"; return ops.history.undoTitle != nil
        case #selector(redo(_:)):
            item.title = ops.history.redoTitle.map { "Redo \($0)" } ?? "Redo"; return ops.history.redoTitle != nil
        case #selector(gitCommit(_:)), #selector(gitStageAll(_:)), #selector(gitUnstageAll(_:)), #selector(gitPull(_:)), #selector(gitPush(_:)):
            return state.git != nil
        case #selector(gitStage(_:)), #selector(gitUnstage(_:)), #selector(gitDiscard(_:)):
            return state.git != nil && hasSel
        case #selector(revealOriginal(_:)): return sel.count == 1 && (sel[0].isSymlink || sel[0].isAlias)
        case #selector(showPackageContents(_:)): return sel.count == 1 && sel[0].isPackage
        case #selector(goToContainingFolder(_:)), #selector(containingFolderNewWindow(_:)), #selector(containingFolderNewTab(_:)):
            return hasSel && (state.isSearch || state.isSmart)
        case #selector(downloadNow(_:)): return sel.contains { $0.cloud == .notDownloaded }
        case #selector(removeDownload(_:)): return sel.contains { $0.cloud == .current }
        case #selector(emptyTrash(_:)): return true
        case #selector(calculateFolderSize(_:)): return true
        default: return true
        }
    }

    private var treeItemCollapsed: Bool { (contentViewController as? NSSplitViewController)?.splitViewItems.first?.isCollapsed ?? false }

    // MARK: Navigation

    @objc func goBack(_ sender: Any?) { state.goBack() }
    @objc func goForward(_ sender: Any?) { state.goForward() }
    @objc func goUp(_ sender: Any?) { state.goUp() }
    @objc func goHome(_ sender: Any?) { state.go(.directory(state.prefs.homeURL)) }
    @objc func goToFolder(_ sender: Any?) {
        if !state.prefs.showPathBar { pathBar.isHidden = false }
        pathBar.beginEditing()
    }
    @objc func goRecent(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        state.go(.directory(URL(fileURLWithPath: p, isDirectory: true)))
    }
    @objc func refresh(_ sender: Any?) {
        TreeNode.subfolderCache.removeAll()
        state.reload()
        tree.rebuild()
    }

    @objc func openSelected(_ sender: Any?) { open(sel, newWindow: false) }
    @objc func openInNewWindow(_ sender: Any?) { open(sel, newWindow: true) }
    @objc func openInNewTab(_ sender: Any?) { open(sel, newWindow: false, newTab: true) }
    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        openFiles(sel, with: app)
        OpenWithMenu.recordUse(app: app, items: sel, window: window)
    }
    @objc func openWithOther(_ sender: Any?) {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.message = "Choose an application to open the selected items"
        guard p.runModal() == .OK, let app = p.url else { return }
        openFiles(sel, with: app)
        OpenWithMenu.offerToAdd(app: app, items: sel, window: window)
    }

    @objc func revealOriginal(_ sender: Any?) {
        guard let it = sel.first else { return }
        let target: URL?
        if it.isSymlink, let d = try? FileManager.default.destinationOfSymbolicLink(atPath: it.url.path) {
            target = URL(fileURLWithPath: d, relativeTo: it.url.deletingLastPathComponent()).standardizedFileURL
        } else { target = try? URL(resolvingAliasFileAt: it.url) }
        guard let t = target else { return }
        state.go(.directory(t.deletingLastPathComponent()), select: [t])
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let it = sel.first else { return }
        state.go(.directory(it.url))
    }

    @objc func goToContainingFolder(_ sender: Any?) {
        guard let u = sel.first?.url else { return }
        state.go(.directory(u.deletingLastPathComponent()), select: [u])
    }
    @objc func containingFolderNewWindow(_ sender: Any?) {
        for u in Set(selURLs.map { $0.deletingLastPathComponent() }) { AppDelegate.shared.openWindow(.directory(u)) }
    }
    @objc func containingFolderNewTab(_ sender: Any?) {
        for u in Set(selURLs.map { $0.deletingLastPathComponent() }) { AppDelegate.shared.openTab(.directory(u), from: self) }
    }

    // MARK: Windows & tabs

    @objc func duplicateWindow(_ sender: Any?) { AppDelegate.shared.openWindow(state.location) }
    @objc func duplicateTab(_ sender: Any?) { AppDelegate.shared.openTab(state.location, from: self) }
    @objc func newTab(_ sender: Any?) { AppDelegate.shared.openTab(.directory(state.prefs.defaultURL), from: self) }
    @objc func customizeTab(_ sender: Any?) { TabSetsUI.customizeTab(self) }
    @objc func saveTabSet(_ sender: Any?) { TabSetsUI.save(self) }
    @objc func manageTabSets(_ sender: Any?) { TabSetsUI.manage(window: window) }

    // MARK: Create

    @objc func newFolder(_ sender: Any?) { createFolder(withSelection: false) }
    @objc func newFolderWithSelection(_ sender: Any?) { createFolder(withSelection: true) }

    func createFolder(withSelection: Bool, inside: URL? = nil) {
        if let (udid, path) = state.deviceLocation {
            guard let name = Alerts.prompt("New Folder", message: "A new folder will be created.", defaultValue: "untitled folder", ok: "Create", selectStem: false) else { return }
            do { try IDeviceRegistry.shared.makeDirectory(udid: udid, path: (path as NSString).appendingPathComponent(name)); state.reload() }
            catch { Alerts.error("Error while creating a folder", error.localizedDescription, window: window) }
            return
        }
        guard let dir = inside ?? state.currentDirectory else { return }
        let suggested = FileNaming.uniqueURL(in: dir, name: withSelection ? "New Folder With Items" : "untitled folder", isDirectory: true).lastPathComponent
        let msg = String(format: "A new folder will be created inside “%@”", FileNaming.displayName(of: dir)) + (withSelection ? "\n\nThe selected items will be moved to the newly created folder." : "")
        guard let name = Alerts.prompt(withSelection ? "New Folder with Selection" : "New Folder", message: msg, defaultValue: suggested, ok: "Create", selectStem: false) else { return }
        if let u = ops.newFolder(in: dir, name: name, moving: withSelection ? realSelection : [], window: window) {
            state.pendingSelection = [u]
            state.softReload()
        }
    }

    @objc func newEmptyFile(_ sender: Any?) { createFile(.text) }
    @objc func newDocument(_ sender: NSMenuItem) {
        if let t = (sender.representedObject as? String).flatMap(DocumentTemplate.init(rawValue:)) { createFile(t) }
        else if let app = sender.representedObject as? URL { NewDocumentViaApp.create(app: app, in: state.currentDirectory, window: window) { [weak self] u in
            self?.state.pendingSelection = [u]; self?.state.softReload()
        } }
    }

    func createFile(_ t: DocumentTemplate) {
        guard let dir = state.currentDirectory else { return }
        let suggested = FileNaming.uniqueURL(in: dir, name: t.defaultName).lastPathComponent
        let msg = String(format: t == .text ? "A new empty file will be created inside “%@”" : "A new empty document will be created inside “%@”", FileNaming.displayName(of: dir))
        guard let name = Alerts.prompt(t == .text ? "New Empty File" : "New Empty Document", message: msg, defaultValue: suggested, ok: "Create") else { return }
        if let u = ops.newFile(in: dir, name: name, template: t, window: window) {
            state.pendingSelection = [u]; state.softReload()
        }
    }

    @objc func newFileFromClipboard(_ sender: Any?) {
        guard let dir = state.currentDirectory else { return }
        guard let kind = FileOps.clipboardKind() else {
            Alerts.error("Error saving file", "The clipboard is empty or holds content that cannot be saved to a file.", window: window); return
        }
        var imagePopup: NSPopUpButton?
        if kind.isImage {
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.addItems(withTitles: ["PNG", "JPEG", "TIFF"])
            imagePopup = p
        }
        let suggested = FileNaming.uniqueURL(in: dir, name: "Untitled." + kind.ext).lastPathComponent
        guard var name = Alerts.prompt("New File from Clipboard", message: String(format: "A new file with clipboard contents will be created inside “%@”", FileNaming.displayName(of: dir)), defaultValue: suggested, ok: "Create", accessory: imagePopup) else { return }
        var type: UTType?
        if let p = imagePopup {
            type = [UTType.png, .jpeg, .tiff][p.indexOfSelectedItem]
            let ext = type!.preferredFilenameExtension ?? "png"
            name = (name as NSString).deletingPathExtension + "." + ext
        }
        if let u = ops.newFileFromClipboard(in: dir, name: name, imageType: type, window: window) {
            state.pendingSelection = [u]; state.softReload()
        }
    }

    // MARK: Edit

    @objc func undo(_ sender: Any?) { ops.undo(window: window); state.softReload() }
    @objc func redo(_ sender: Any?) { ops.redo(window: window); state.softReload() }

    @objc func copy(_ sender: Any?) {
        if state.isArchive, let a = state.archive {
            // Extract to temp so the copy can be pasted anywhere.
            let paths = sel.compactMap(\.archivePath)
            guard let tmp = try? a.extractToTemp(paths) else { return }
            ops.copy(paths.map { tmp.appendingPathComponent($0) })
            return
        }
        if let (udid, _) = state.deviceLocation {
            let paths = sel.compactMap { IDeviceRegistry.parseVirtual($0.url)?.1 }
            if let out = try? IDeviceRegistry.shared.download(udid: udid, paths: paths, to: AppPaths.temp.appendingPathComponent(UUID().uuidString, isDirectory: true).creatingDirectory()) {
                ops.copy(out)
            }
            return
        }
        ops.copy(selURLs)
    }
    @objc func copyAsPath(_ sender: Any?) { ops.copyPaths(selURLs.isEmpty ? selOrCurrent : selURLs) }
    @objc func cut(_ sender: Any?) {
        if state.isArchive { archiveRemove(); return }
        ops.cut(realSelection, window: window)
        state.softReload()
    }
    @objc func cutInternal(_ sender: Any?) { ops.cut(realSelection, window: window, forceInternal: true) }

    @objc func paste(_ sender: Any?) {
        if state.isArchive, let a = state.archive { ArchiveOps.add(ops.clipboardURLs, to: a, inner: state.archiveInner, state: state, window: window); return }
        if let (udid, path) = state.deviceLocation {
            let files = ops.clipboardURLs
            DeviceOps.upload(files, udid: udid, path: path, state: state, window: window)
            return
        }
        guard let dir = state.currentDirectory else { return }
        ops.paste(into: dir, window: window) { [weak self] urls in self?.state.select(urls: urls); self?.state.softReload() }
    }
    @objc func moveItemHere(_ sender: Any?) {
        guard let dir = state.currentDirectory else { return }
        ops.paste(into: dir, mode: .move, window: window) { [weak self] u in self?.state.select(urls: u) }
    }
    @objc func pasteIntoFolder(_ sender: Any?) {
        guard let f = sel.first, f.isDirectory else { return }
        if state.isArchive, let a = state.archive { ArchiveOps.add(ops.clipboardURLs, to: a, inner: f.archivePath ?? "", state: state, window: window); return }
        ops.paste(into: f.url, window: window)
    }
    @objc func pasteAsSymlinks(_ sender: Any?) {
        guard let dir = state.currentDirectory else { return }
        ops.paste(into: dir, mode: .symlinks, window: window) { [weak self] u in self?.state.select(urls: u) }
    }
    @objc func pasteAsAliases(_ sender: Any?) {
        guard let dir = state.currentDirectory else { return }
        ops.paste(into: dir, mode: .aliases, window: window) { [weak self] u in self?.state.select(urls: u) }
    }

    @objc override func selectAll(_ sender: Any?) { state.selection = state.items }
    @objc func deselectAll(_ sender: Any?) { state.selection = [] }

    // MARK: Destructive

    @objc func moveToTrash(_ sender: Any?) {
        guard !sel.isEmpty else { return }
        if state.isArchive { archiveRemove(); return }
        if let (udid, _) = state.deviceLocation {
            let paths = sel.compactMap { IDeviceRegistry.parseVirtual($0.url)?.1 }
            guard Alerts.confirm(paths.count == 1 ? String(format: "Permanently Delete “%@”?", sel[0].name) : "Are you sure you want to delete the selected items permanently?", "This action is immediate and cannot be undone.", ok: "Delete", destructive: true) else { return }
            do { try IDeviceRegistry.shared.remove(udid: udid, paths: paths) } catch { Alerts.error("Error while deleting", error.localizedDescription, window: window) }
            state.reload(); return
        }
        if state.isTrash { deletePermanently(sender); return }
        let next = neighbourAfterRemoval()
        ops.moveToTrash(realSelection, window: window)
        if let n = next { state.pendingSelection = [n] }
    }

    @objc func deletePermanently(_ sender: Any?) {
        if state.isArchive { archiveRemove(); return }
        ops.deletePermanently(realSelection, window: window)
    }

    @objc func emptyTrash(_ sender: Any?) { ops.emptyTrash(window: window) }

    @objc func emptyPrivateTrash(_ sender: Any?) {
        guard Alerts.confirm("Empty Private Trash", "This action is immediate and cannot be undone.", ok: "Empty", destructive: true) else { return }
        Trasher.emptyPrivateTrash()
    }

    private func neighbourAfterRemoval() -> URL? {
        let ids = Set(sel.map(\.id))
        guard let last = state.items.lastIndex(where: { ids.contains($0.id) }) else { return nil }
        return state.items[(last + 1)...].first { !ids.contains($0.id) }?.url ?? state.items[..<last].last { !ids.contains($0.id) }?.url
    }

    @objc func eject(_ sender: Any?) {
        if let v = sel.first, v.isVolume { VolumeOps.eject(v.url, window: window); return }
        if let u = state.location.url, let v = Volumes.volume(containing: u) {
            state.go(.directory(state.prefs.homeURL))
            VolumeOps.eject(v.url, window: window)
        }
    }

    // MARK: Rename / duplicate / touch

    @objc func renameSelected(_ sender: Any?) {
        if sel.count == 1 { fileView.beginRename(sel[0].url) } else { batchRename(sender) }
    }

    @objc func batchRename(_ sender: Any?) {
        let targets = realSelection.isEmpty ? state.items.filter { $0.archivePath == nil }.map(\.url) : realSelection
        guard !targets.isEmpty else { return }
        BatchRenameWindow.show(urls: targets, host: self)
    }

    @objc func duplicate(_ sender: Any?) {
        ops.start(.duplicate, realSelection, to: nil, window: window) { [weak self] op in self?.state.select(urls: op.results) }
    }

    @objc func touch(_ sender: Any?) { ops.touch(realSelection); state.softReload() }

    // MARK: Archives

    @objc func compress(_ sender: Any?) {
        let fmt = ArchiveFormat(rawValue: state.prefs.lastCompressFormat) ?? .zip
        ArchiveOps.compress(realSelection, format: fmt, protected: false, state: state, window: window)
    }
    @objc func compressTo(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let fmt = ArchiveFormat(rawValue: raw) else { return }
        state.prefs.lastCompressFormat = fmt.rawValue
        ArchiveOps.compress(realSelection, format: fmt, protected: sender.tag == 1, state: state, window: window)
    }
    @objc func extract(_ sender: Any?) {
        if state.isArchive { ArchiveOps.extractEntries(sel.compactMap(\.archivePath), state: state, window: window) }
        else { ArchiveOps.extractHere(sel.filter(\.isArchive).map(\.url), state: state, window: window) }
    }
    @objc func extractAll(_ sender: Any?) {
        if state.isArchive { ArchiveOps.extractEntries([], state: state, window: window) }
        else { ArchiveOps.extractHere(sel.filter(\.isArchive).map(\.url), state: state, window: window) }
    }
    @objc func extractHere(_ sender: Any?) { ArchiveOps.extractHere(sel.filter(\.isArchive).map(\.url), state: state, window: window) }
    @objc func setArchiveEncoding(_ sender: NSMenuItem) {
        state.archive?.filenameEncoding = sender.representedObject as? String
        try? state.archive?.load()
        state.reload()
    }

    private func archiveRemove() {
        guard let a = state.archive else { return }
        ArchiveOps.remove(sel.compactMap(\.archivePath), from: a, state: state, window: window)
    }

    // MARK: Quick Look & info

    @objc func quickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { updateQuickLook(); panel.makeKeyAndOrderFront(nil) }
    }

    @objc func showInfoInFinder(_ sender: Any?) {
        for u in selOrCurrent {
            _ = ActionRunner.runAppleScript("tell application \"Finder\"\nactivate\nopen information window of (POSIX file \(ActionRunner.appleScriptQuote(u.path)) as alias)\nend tell")
        }
    }

    @objc func calculateFolderSize(_ sender: Any?) {
        let folders = sel.filter(\.isFolder).map(\.url)
        state.calculateSizes(folders.isEmpty ? state.items.filter(\.isFolder).map(\.url) : folders)
    }

    @objc func calculateAllOnVolume(_ sender: Any?) { calculateFolderSize(sender) }

    // MARK: Cloud

    @objc func downloadNow(_ sender: Any?) {
        for it in sel where it.cloud == .notDownloaded { try? FileManager.default.startDownloadingUbiquitousItem(at: it.url) }
    }
    @objc func removeDownload(_ sender: Any?) {
        for it in sel where it.cloud == .current { try? FileManager.default.evictUbiquitousItem(at: it.url) }
        state.softReload()
    }

    // MARK: Tags & ratings

    @objc func toggleColorTag(_ sender: NSMenuItem) {
        guard let c = FinderColor(rawValue: sender.tag) else { return }
        let urls = realSelection
        ops.recordMetadataChange("Change Color Tag", urls: urls) { try Metadata.toggleColor(c, on: urls) }
        state.softReload(); info.refresh()
    }
    @objc func toggleTextTag(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? String else { return }
        let urls = realSelection
        ops.recordMetadataChange("Change Text Tag", urls: urls) { try Metadata.toggleTextTag(t, on: urls) }
        state.softReload(); info.refresh()
    }
    @objc func addTextTag(_ sender: Any?) {
        guard let t = Alerts.prompt("Add a New Text Tag", message: "Enter a new tag: ", ok: "Add", selectStem: false), !t.isEmpty else { return }
        let urls = realSelection
        ops.recordMetadataChange("Change Text Tag", urls: urls) {
            for u in urls { var tags = Metadata.tags(u); if !tags.contains(t) { tags.append(t) }; try Metadata.setTags(u, tags) }
        }
        state.softReload(); info.refresh()
    }
    @objc func setRating(_ sender: NSMenuItem) {
        let r = sender.tag
        let urls = realSelection
        ops.recordMetadataChange("Change Star Rating", urls: urls) { for u in urls { try Metadata.setStarRating(u, r) } }
        state.softReload(); info.refresh()
    }

    // MARK: Favorites, default & home folders

    @objc func toggleFavorite(_ sender: Any?) {
        let targets = sel.isEmpty ? (state.currentDirectory.map { [$0] } ?? []) : selURLs
        let allFav = targets.allSatisfy(Favorites.contains)
        for u in targets { if allFav { try? Favorites.remove(u) } else { try? Favorites.add(u) } }
        tree.rebuild()
    }

    func makeDefaultFolder(_ u: URL) { state.prefs.defaultPath = u.path }
    func makeHomeFolder(_ u: URL) {
        state.prefs.homePath = u.path
        if Alerts.confirm("Changing Home folder requires Explorer to be relaunched to take effect.", "Do you want to relaunch now?", ok: "Relaunch Now") {
            AppDelegate.shared.relaunch()
        }
    }

    // MARK: Finder & Terminal

    @objc func revealInFinder(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting(realSelection.isEmpty ? selOrCurrent : realSelection) }
    @objc func openInFinder(_ sender: Any?) {
        if let d = state.currentDirectory { NSWorkspace.shared.open(d) }
    }
    @objc func openTerminalHere(_ sender: Any?) { if let d = state.currentDirectory { Terminal.open(d) } }
    @objc func openTerminalAtSelection(_ sender: Any?) {
        let dirs = sel.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() }
        for d in Set(dirs) { Terminal.open(d) }
    }

    // MARK: View options

    @objc func setViewKind(_ sender: NSMenuItem) {
        if let k = (sender.representedObject as? String).flatMap(ViewKind.init(rawValue:)) { state.options.view = k }
    }
    @objc func viewIcons(_ sender: Any?) { state.options.view = .icons }
    @objc func viewList(_ sender: Any?) { state.options.view = .list }
    @objc func viewTable(_ sender: Any?) { state.options.view = .table }
    @objc func viewGallery(_ sender: Any?) { state.options.view = .gallery }
    @objc func setSortKey(_ sender: NSMenuItem) {
        if let k = (sender.representedObject as? String).flatMap(SortKey.init(rawValue:)) { state.options.sortKey = k }
    }
    @objc func setSortOrder(_ sender: NSMenuItem) { state.options.sortOrder = sender.tag == 0 ? .ascending : .descending }
    @objc func setGrouping(_ sender: NSMenuItem) {
        if let k = (sender.representedObject as? String).flatMap(GroupKey.init(rawValue:)) { state.options.grouping = k }
    }
    @objc func foldersFirst(_ sender: Any?) { state.options.folders = state.options.folders == .first ? .mixed : .first }
    @objc func foldersLast(_ sender: Any?) { state.options.folders = state.options.folders == .last ? .mixed : .last }
    @objc func toggleHidden(_ sender: Any?) { state.options.showHidden.toggle() }
    @objc func toggleThumbnails(_ sender: Any?) { state.options.showThumbnails.toggle() }
    @objc func toggleInfo(_ sender: Any?) { state.options.showInfo.toggle() }
    @objc func toggleTraits(_ sender: Any?) { state.options.showTraits.toggle() }
    @objc func toggleLiveText(_ sender: Any?) { state.options.liveText.toggle() }
    @objc func toggleRemember(_ sender: Any?) { state.toggleRemember(); window?.toolbar?.validateVisibleItems() }
    @objc func setIconSize(_ sender: NSMenuItem) { state.options.iconSize = sender.tag }
    @objc func zoomIn(_ sender: Any?) { fileView.setZoom(1) }
    @objc func zoomOut(_ sender: Any?) { fileView.setZoom(-1) }

    @objc func toggleSidebar(_ sender: Any?) {
        guard let s = contentViewController as? NSSplitViewController else { return }
        let item = s.splitViewItems[0]
        item.animator().isCollapsed.toggle()
        state.prefs.showSidebar = !item.isCollapsed
    }
    @objc func togglePathBar(_ sender: Any?) { state.prefs.showPathBar.toggle(); broadcastChrome() }
    @objc func toggleStatusBar(_ sender: Any?) { state.prefs.showStatusBar.toggle(); broadcastChrome() }
    @objc func toggleActionBar(_ sender: Any?) { state.prefs.showActionToolbar.toggle(); broadcastChrome() }
    @objc func toggleShelf(_ sender: Any?) { state.prefs.showShelf.toggle(); broadcastChrome() }
    @objc func toggleTimeInDates(_ sender: Any?) { state.prefs.showTimeInDates.toggle(); broadcastChrome() }
    @objc func toggleArchivesInTree(_ sender: Any?) { state.prefs.showArchivesInTree.toggle(); broadcastChrome() }
    @objc func togglePackagesInTree(_ sender: Any?) { state.prefs.showPackagesInTree.toggle(); broadcastChrome() }
    @objc func toggleHiddenInTree(_ sender: Any?) { state.prefs.showHiddenInTree.toggle(); broadcastChrome() }

    func broadcastChrome() { NotificationCenter.default.post(name: .viewSettingsChanged, object: nil) }

    // MARK: Shelf

    @objc func addToShelf(_ sender: Any?) {
        ShelfStore.add(realSelection)
        if !state.prefs.showShelf { state.prefs.showShelf = true; broadcastChrome() }
        shelf.open()
    }

    // MARK: Network

    @objc func mountNetworkShare(_ sender: Any?) { showMountShare() }
    @objc func remountPinned(_ sender: Any?) {
        NetworkMounter.remountPinned { [weak self] failures in
            NotificationCenter.default.post(name: .treeNeedsRebuild, object: nil)
            if let (u, e) = failures.first { Alerts.error(String(format: "Could not connect to “%@”.", u), e.localizedDescription, window: self?.window) }
        }
    }

    // MARK: Find

    @objc func performFind(_ sender: Any?) {
        guard let tb = window?.toolbar, let item = tb.items.first(where: { $0 is NSSearchToolbarItem }) as? NSSearchToolbarItem else { return }
        item.beginSearchInteraction()
    }

    // MARK: Source Control

    private func gitRun(_ title: String, _ body: @escaping (Git) throws -> String?) {
        guard let g = state.git else { return }
        guard Git.isAvailable else {
            Alerts.error("The git command failed.", "Source Control requires the Xcode Command Line Tools. Install them with “xcode-select --install”.", window: window); return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let out = try body(g)
                DispatchQueue.main.async {
                    self?.state.softReload()
                    if let out, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { LogSheet.show(title: title, text: out, window: self?.window) }
                }
            } catch {
                DispatchQueue.main.async { LogSheet.show(title: "The git command failed.", text: error.localizedDescription, window: self?.window) }
            }
        }
    }
    @objc func gitStage(_ sender: Any?) { let u = realSelection; gitRun("Stage") { try $0.stage(u); return nil } }
    @objc func gitUnstage(_ sender: Any?) { let u = realSelection; gitRun("Unstage") { try $0.unstage(u); return nil } }
    @objc func gitStageAll(_ sender: Any?) { gitRun("Stage All") { try $0.stageAll(); return nil } }
    @objc func gitUnstageAll(_ sender: Any?) { gitRun("Unstage All") { try $0.unstageAll(); return nil } }
    @objc func gitDiscard(_ sender: Any?) {
        guard Alerts.confirm("Discard Selected Changes", "The changes made to the selected items will be reverted to the latest commit. This cannot be undone.", ok: "Discard Changes", destructive: true) else { return }
        let u = realSelection
        gitRun("Discard") { try $0.discard(u); return nil }
    }
    @objc func gitCommit(_ sender: Any?) {
        guard let g = state.git else { return }
        guard g.hasStagedChanges() else { Alerts.info("Commit Changes", "There are no staged changes to commit.", window: window); return }
        guard let msg = CommitSheet.ask(branch: g.currentBranch(), window: window), !msg.isEmpty else { return }
        gitRun("Commit") { try $0.commit(message: msg) }
    }
    @objc func gitPull(_ sender: Any?) { gitRun("Pull") { try $0.pull() } }
    @objc func gitPush(_ sender: Any?) { gitRun("Push") { try $0.push() } }

    // MARK: Actions (scripting)

    @objc func runAction(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? ScriptAction, let dir = state.currentDirectory else { return }
        let items = realSelection
        let scripts = ActionRunner.scripts(for: a, items: items, dir: dir)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var log = ""
            var failed = false
            for s in scripts {
                let out = a.kind == .shell ? ActionRunner.runShell(s, in: dir) : ActionRunner.runAppleScript(s)
                log += out.log
                if out.status != 0 { failed = true; log += String(format: "\nExited with status %lld.\n", Int64(out.status)) }
            }
            DispatchQueue.main.async {
                self?.state.softReload()
                if failed { LogSheet.show(title: String(format: "“%@” failed", a.name), text: log, window: self?.window) }
            }
        }
    }
}

extension URL {
    func creatingDirectory() -> URL {
        try? FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}

enum Terminal {
    static func open(_ dir: URL) {
        let app = URL(fileURLWithPath: Preferences.shared.terminalAppPath)
        let cfg = NSWorkspace.OpenConfiguration()
        if FileManager.default.fileExists(atPath: app.path) {
            NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: cfg)
        } else {
            NSWorkspace.shared.open([dir], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: cfg)
        }
    }
}
