import AppKit
import ExplorerKit

/// Tree shortcuts use the selected node, never the file view's previous selection or archive context.
extension BrowserWindowController {
    var hasTreeFocus: Bool { window?.firstResponder === tree.outline }
    var isEditingText: Bool { window?.firstResponder is NSTextView }

    private var keyboardTreeNode: TreeNode? {
        guard hasTreeFocus, tree.outline.selectedRow >= 0 else { return nil }
        return tree.outline.item(atRow: tree.outline.selectedRow) as? TreeNode
    }

    private func treeAction(for action: Selector?) -> Selector? {
        switch action {
        case #selector(openSelected(_:)): return #selector(treeOpen(_:))
        case #selector(openInNewWindow(_:)): return #selector(treeOpenWindow(_:))
        case #selector(openInNewTab(_:)): return #selector(treeOpenTab(_:))
        case #selector(renameSelected(_:)): return #selector(treeRename(_:))
        case #selector(copy(_:)): return #selector(treeCopy(_:))
        case #selector(copyAsPath(_:)): return #selector(treeCopyPath(_:))
        case #selector(paste(_:)), #selector(pasteIntoFolder(_:)): return #selector(treePaste(_:))
        case #selector(moveToTrash(_:)): return #selector(treeTrash(_:))
        case #selector(deletePermanently(_:)): return #selector(treeDeletePermanently(_:))
        case #selector(eject(_:)): return #selector(treeEject(_:))
        case #selector(toggleFavorite(_:)): return #selector(treeFavorite(_:))
        case #selector(addToShelf(_:)): return #selector(treeAddToShelf(_:))
        default: return nil
        }
    }

    private func canMutateTreeNode(_ node: TreeNode) -> Bool {
        if case .mtp(let address) = node.kind { return MTPOps.canMutate(address) }
        guard case .folder(let url) = node.kind, !node.isVolume, node.targetExists,
              url.standardizedFileURL.path != "/", LocalFileBoundary.accepts(url),
              IDeviceRegistry.parseVirtual(url) == nil else { return false }
        return true
    }

    private func treeKeyboardItem(for action: Selector?) -> NSMenuItem? {
        guard let node = keyboardTreeNode, let mapped = treeAction(for: action) else { return nil }
        if [#selector(treeOpen(_:)), #selector(treeOpenWindow(_:)), #selector(treeOpenTab(_:))].contains(mapped),
           let location = node.location {
            let mode = mapped == #selector(treeOpenWindow(_:)) ? 1 : (mapped == #selector(treeOpenTab(_:)) ? 2 : 0)
            return Menus.item("", #selector(treeNavigateFromKeyboard(_:)), target: self, represented: location, tag: mode)
        }
        guard let url = node.url else { return nil }
        if [#selector(treeRename(_:)), #selector(treeTrash(_:)), #selector(treeDeletePermanently(_:))].contains(mapped),
           !canMutateTreeNode(node) { return nil }
        if mapped == #selector(treeRename(_:)) || mapped == #selector(treeDeletePermanently(_:)) {
            return Menus.item("", mapped, target: self, represented: url)
        }
        if mapped == #selector(treeAddToShelf(_:)) {
            guard case .folder = node.kind, LocalFileBoundary.accepts(url), IDeviceRegistry.parseVirtual(url) == nil else { return nil }
            return Menus.item("", mapped, target: self, represented: url)
        }
        return treeContextMenu(for: node)?.items.first { $0.action == mapped && $0.isEnabled }
    }

    /// nil means a window-wide command, which keeps normal browser validation.
    func validateTreeKeyboardCommand(_ action: Selector?) -> Bool? {
        guard hasTreeFocus else { return nil }
        if treeAction(for: action) != nil { return treeKeyboardItem(for: action) != nil }
        if action == #selector(cut(_:)) || KeyboardShortcuts.usesFileSelection(action) { return false }
        return nil
    }

    /// Returns true even when unavailable, so a tree command never falls back to file selection.
    @discardableResult
    func routeTreeKeyboardCommand(_ action: Selector, sender: Any?) -> Bool {
        guard hasTreeFocus, (sender as? NSMenuItem)?.isFileContextCommand != true else { return false }
        if let item = treeKeyboardItem(for: action), let mapped = item.action {
            _ = NSApp.sendAction(mapped, to: self, from: item)
        }
        return true
    }

    @objc func treeNavigateFromKeyboard(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? Location, keyboardTreeNode?.location == location else { return }
        switch sender.tag {
        case 1: AppDelegate.shared.openWindow(location)
        case 2: AppDelegate.shared.openTab(location, from: self)
        default: state.go(location)
        }
    }

    @objc func treeDeletePermanently(_ sender: NSMenuItem) {
        guard let node = keyboardTreeNode, canMutateTreeNode(node), let url = sender.representedObject as? URL,
              url == node.url else { return }
        if let address = MTPAddress(url: url) { MTPOps.remove([address], state: state, window: window) }
        else { ops.deletePermanently([url], window: window) }
    }

    @objc func treeAddToShelf(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, LocalFileBoundary.accepts(url) else { return }
        ShelfStore.add([url])
        if !state.prefs.showShelf {
            state.prefs.showShelf = true
            broadcastChrome()
        }
        shelf.open()
    }
}
