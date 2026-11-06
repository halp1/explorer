import AppKit
import ExplorerKit

/// Resolves view input only. Menu equivalents stay in AppKit's responder chain.
enum KeyboardShortcuts {
    enum Context { case files, table, tree, editor }
    enum Command: Equatable {
        case open, rename, quickLook, refresh, trash, deletePermanently
        case back, up, shelf, calculateSizes

        var action: Selector {
            switch self {
            case .open: return #selector(BrowserWindowController.openSelected(_:))
            case .rename: return #selector(BrowserWindowController.renameSelected(_:))
            case .quickLook: return #selector(BrowserWindowController.quickLook(_:))
            case .refresh: return #selector(BrowserWindowController.refresh(_:))
            case .trash: return #selector(BrowserWindowController.moveToTrash(_:))
            case .deletePermanently: return #selector(BrowserWindowController.deletePermanently(_:))
            case .back: return #selector(BrowserWindowController.goBack(_:))
            case .up: return #selector(BrowserWindowController.goUp(_:))
            case .shelf: return #selector(BrowserWindowController.addToShelf(_:))
            case .calculateSizes: return #selector(BrowserWindowController.calculateFolderSize(_:))
            }
        }
    }

    /// Explicit file actions must not capture text-editing equivalents such as Command-arrow or Delete.
    static func usesFileSelection(_ action: Selector?) -> Bool {
        switch action {
        case #selector(BrowserWindowController.openSelected(_:)), #selector(BrowserWindowController.openInNewWindow(_:)),
             #selector(BrowserWindowController.openInNewTab(_:)), #selector(BrowserWindowController.openWithApp(_:)), #selector(BrowserWindowController.openWithOther(_:)),
             #selector(BrowserWindowController.renameSelected(_:)), #selector(BrowserWindowController.batchRename(_:)),
             #selector(BrowserWindowController.moveToTrash(_:)), #selector(BrowserWindowController.deletePermanently(_:)),
             #selector(BrowserWindowController.eject(_:)),
             #selector(BrowserWindowController.duplicate(_:)), #selector(BrowserWindowController.touch(_:)),
             #selector(BrowserWindowController.compress(_:)), #selector(BrowserWindowController.compressTo(_:)),
             #selector(BrowserWindowController.extract(_:)), #selector(BrowserWindowController.extractAll(_:)), #selector(BrowserWindowController.extractHere(_:)),
             #selector(BrowserWindowController.quickLook(_:)), #selector(BrowserWindowController.addToShelf(_:)),
             #selector(BrowserWindowController.copyAsPath(_:)), #selector(BrowserWindowController.cutInternal(_:)),
             #selector(BrowserWindowController.moveItemHere(_:)), #selector(BrowserWindowController.pasteIntoFolder(_:)),
             #selector(BrowserWindowController.pasteAsSymlinks(_:)), #selector(BrowserWindowController.pasteAsAliases(_:)),
             #selector(BrowserWindowController.toggleFavorite(_:)), #selector(BrowserWindowController.setRating(_:)),
             #selector(BrowserWindowController.toggleTextTag(_:)), #selector(BrowserWindowController.toggleColorTag(_:)), #selector(BrowserWindowController.addTextTag(_:)),
             #selector(BrowserWindowController.calculateFolderSize(_:)), #selector(BrowserWindowController.calculateAllOnVolume(_:)),
             #selector(BrowserWindowController.newFolderWithSelection(_:)), #selector(BrowserWindowController.downloadNow(_:)), #selector(BrowserWindowController.removeDownload(_:)),
             #selector(BrowserWindowController.revealOriginal(_:)), #selector(BrowserWindowController.showPackageContents(_:)),
             #selector(BrowserWindowController.goToContainingFolder(_:)), #selector(BrowserWindowController.containingFolderNewWindow(_:)), #selector(BrowserWindowController.containingFolderNewTab(_:)),
             #selector(BrowserWindowController.revealInFinder(_:)), #selector(BrowserWindowController.showInfoInFinder(_:)), #selector(BrowserWindowController.openTerminalAtSelection(_:)),
             #selector(BrowserWindowController.gitStage(_:)), #selector(BrowserWindowController.gitUnstage(_:)), #selector(BrowserWindowController.gitDiscard(_:)), #selector(BrowserWindowController.runAction(_:)):
            return true
        default: return false
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .option, .control, .shift])
    }

    static func resolve(keyCode: UInt16, characters: String?, modifiers flags: NSEvent.ModifierFlags,
                        context: Context, returnAction: ReturnAction, trashWithDelete: Bool,
                        backWithDelete: Bool, rightToLeft: Bool) -> Command? {
        guard context != .editor else { return nil }
        let mods = modifiers(flags)
        switch keyCode {
        case 36, 76:
            if mods.isEmpty { return returnAction == .rename ? .rename : .open }
            if mods == .command || mods == .shift { return .rename }
        case 49 where mods.isEmpty: return .quickLook
        case 120 where mods.isEmpty: return .rename
        case 96 where mods.isEmpty: return .refresh
        case 51 where mods.isEmpty:
            if trashWithDelete { return .trash }
            if backWithDelete { return .back }
        case 117:
            if mods.isEmpty { return .trash }
            if mods == .option { return .deletePermanently }
        case 125 where mods == .command: return .open
        case 126 where mods == .command: return .up
        case 124 where mods == .command && !rightToLeft: return .shelf
        case 123 where mods == .command && rightToLeft: return .shelf
        default: break
        }
        if context == .table, characters == "=", mods.isEmpty { return .calculateSizes }
        return nil
    }
}
