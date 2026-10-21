import Foundation

/// Identifiers for every command that can appear in the file context menu.
public enum MenuCommand: String, Codable, CaseIterable, Sendable {
    case newFolder, newFolderWithSelection, newFile
    case goToContainingFolder, containingFolderNewWindow, containingFolderNewTab
    case connectShare, pinShare, unpinShare, hideShare
    case open, openWith, openInNewWindow, openInNewTab, revealOriginal, showPackageContents
    case downloadNow, removeDownload
    case moveToTrash, deletePermanently, emptyTrash, eject
    case rename, batchRename, duplicate, touch
    case compress, compressTo, extract, extractAll, extractHere
    case quickLook
    case cut, cutViaTrash, copy, copyAsPath, paste, moveItemHere, pasteIntoFolder, pasteAsSymlinks, pasteAsAliases
    case share
    case addToFavorites, removeFromFavorites, makeDefaultFolder, makeHomeFolder
    case colorTags, textTagsRatings
    case revealInFinder, openInFinder
    case openTerminalAtFolder, openTerminal
    case sourceControl, actions
    case iconSize, calculateSize
    case services

    public var title: String {
        switch self {
        case .newFolder: return "New Folder..."
        case .newFolderWithSelection: return "New Folder with Selection..."
        case .newFile: return "New File"
        case .goToContainingFolder: return "Go to Containing Folder"
        case .containingFolderNewWindow: return "Containing Folder in New Window"
        case .containingFolderNewTab: return "Containing Folder in New Tab"
        case .connectShare: return "Connect..."
        case .pinShare: return "Pin"
        case .unpinShare: return "Unpin"
        case .hideShare: return "Hide"
        case .open: return "Open"
        case .openWith: return "Open With"
        case .openInNewWindow: return "Open in New Window"
        case .openInNewTab: return "Open in New Tab"
        case .revealOriginal: return "Reveal Original"
        case .showPackageContents: return "Show Package Contents"
        case .downloadNow: return "Download Now"
        case .removeDownload: return "Remove Download"
        case .moveToTrash: return "Move to Trash"
        case .deletePermanently: return "Delete Permanently"
        case .emptyTrash: return "Empty Trash"
        case .eject: return "Eject"
        case .rename: return "Rename"
        case .batchRename: return "Batch Rename..."
        case .duplicate: return "Duplicate"
        case .touch: return "Touch"
        case .compress: return "Compress to ZIP"
        case .compressTo: return "Compress to"
        case .extract: return "Extract"
        case .extractAll: return "Extract All"
        case .extractHere: return "Extract Here"
        case .quickLook: return "Quick Look"
        case .cut: return "Cut"
        case .cutViaTrash: return "Cut via Trash"
        case .copy: return "Copy"
        case .copyAsPath: return "Copy as Path"
        case .paste: return "Paste"
        case .moveItemHere: return "Move Item Here"
        case .pasteIntoFolder: return "Paste into Folder"
        case .pasteAsSymlinks: return "Paste as Symlinks"
        case .pasteAsAliases: return "Paste as Aliases"
        case .share: return "Share"
        case .addToFavorites: return "Add to Favorites"
        case .removeFromFavorites: return "Remove from Favorites"
        case .makeDefaultFolder: return "Make Default Folder"
        case .makeHomeFolder: return "Make Home Folder"
        case .colorTags: return "Color tags"
        case .textTagsRatings: return "Text Tags & Ratings"
        case .revealInFinder: return "Reveal in Finder"
        case .openInFinder: return "Open in Finder"
        case .openTerminalAtFolder: return "Open Terminal at Folder"
        case .openTerminal: return "Open Terminal at This Folder"
        case .sourceControl: return "Source Control"
        case .actions: return "Actions"
        case .iconSize: return "Icons Size"
        case .calculateSize: return "Calculate Size"
        case .services: return "Services"
        }
    }

    public var symbol: String {
        switch self {
        case .newFolder, .newFolderWithSelection: return "folder.badge.plus"
        case .newFile: return "doc.badge.plus"
        case .goToContainingFolder, .containingFolderNewWindow, .containingFolderNewTab: return "folder"
        case .connectShare: return "link"
        case .pinShare: return "pin"
        case .unpinShare: return "pin.slash"
        case .hideShare: return "eye.slash"
        case .open: return "arrow.up.forward.app"
        case .openWith: return "app.badge"
        case .openInNewWindow: return "macwindow.on.rectangle"
        case .openInNewTab: return "plus.rectangle.on.rectangle"
        case .revealOriginal: return "arrowshape.turn.up.backward"
        case .showPackageContents: return "shippingbox"
        case .downloadNow: return "icloud.and.arrow.down"
        case .removeDownload: return "icloud.slash"
        case .moveToTrash: return "trash"
        case .deletePermanently: return "trash.slash"
        case .emptyTrash: return "trash.circle"
        case .eject: return "eject"
        case .rename: return "pencil"
        case .batchRename: return "pencil.and.list.clipboard"
        case .duplicate: return "plus.square.on.square"
        case .touch: return "hand.tap"
        case .compress, .compressTo: return "archivebox"
        case .extract, .extractAll, .extractHere: return "arrow.up.bin"
        case .quickLook: return "eye"
        case .cut, .cutViaTrash: return "scissors"
        case .copy: return "doc.on.doc"
        case .copyAsPath: return "text.alignleft"
        case .paste, .pasteIntoFolder: return "doc.on.clipboard"
        case .moveItemHere: return "arrow.right.doc.on.clipboard"
        case .pasteAsSymlinks: return "link"
        case .pasteAsAliases: return "arrowshape.turn.up.right"
        case .share: return "square.and.arrow.up"
        case .addToFavorites: return "star"
        case .removeFromFavorites: return "star.slash"
        case .makeDefaultFolder: return "flag"
        case .makeHomeFolder: return "house"
        case .colorTags: return "circle.fill"
        case .textTagsRatings: return "tag"
        case .revealInFinder, .openInFinder: return "macwindow"
        case .openTerminalAtFolder, .openTerminal: return "terminal"
        case .sourceControl: return "arrow.triangle.branch"
        case .actions: return "bolt"
        case .iconSize: return "square.resize"
        case .calculateSize: return "sum"
        case .services: return "gearshape.2"
        }
    }

    /// Commands that may act as ⌥ alternates of the item above them.
    public var canBeAlternate: Bool {
        [.deletePermanently, .copyAsPath, .moveItemHere, .openInNewWindow, .openInNewTab, .makeHomeFolder,
         .pasteAsSymlinks, .pasteAsAliases, .cut, .openInFinder, .containingFolderNewWindow, .containingFolderNewTab].contains(self)
    }

    /// Submenu commands (indented in the editor, only movable within their parent).
    public var parent: MenuCommand? { nil }
}

public struct ContextMenuEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String           // command raw value, or "sep-<uuid>"
    public var command: MenuCommand?
    public var visible: Bool
    public var iconVisible: Bool
    public var alternate: Bool

    public var isSeparator: Bool { command == nil }

    public init(_ c: MenuCommand, visible: Bool = true, icon: Bool = false, alternate: Bool = false) {
        id = c.rawValue; command = c; self.visible = visible; iconVisible = icon; self.alternate = alternate
    }
    public static func separator() -> ContextMenuEntry {
        var e = ContextMenuEntry(.open); e.id = "sep-" + UUID().uuidString; e.command = nil; return e
    }
}

public enum ContextMenuLayout {
    public static var defaults: [ContextMenuEntry] {
        var s = 0
        func sep() -> ContextMenuEntry { s += 1; var e = ContextMenuEntry.separator(); e.id = "sep-\(s)"; return e }
        return [
            .init(.newFolder), .init(.newFolderWithSelection), .init(.newFile), sep(),
            .init(.goToContainingFolder), .init(.containingFolderNewWindow), .init(.containingFolderNewTab),
            .init(.connectShare), .init(.pinShare), .init(.unpinShare), .init(.hideShare), sep(),
            .init(.open), .init(.openWith), .init(.openInNewWindow), .init(.openInNewTab),
            .init(.revealOriginal), .init(.showPackageContents), .init(.downloadNow), sep(),
            .init(.moveToTrash, icon: true), .init(.deletePermanently, icon: true, alternate: true), .init(.emptyTrash, icon: true),
            .init(.removeDownload), .init(.eject), sep(),
            .init(.rename), .init(.batchRename), .init(.duplicate), .init(.touch),
            .init(.compress), .init(.compressTo), .init(.extract), .init(.extractAll), .init(.extractHere), sep(),
            .init(.quickLook), sep(),
            .init(.cutViaTrash), .init(.cut, alternate: true), .init(.copy), .init(.copyAsPath, alternate: true),
            .init(.paste), .init(.moveItemHere, alternate: true), .init(.pasteIntoFolder),
            .init(.pasteAsSymlinks), .init(.pasteAsAliases), sep(),
            .init(.share, icon: true), sep(),
            .init(.addToFavorites), .init(.removeFromFavorites), .init(.makeDefaultFolder), .init(.makeHomeFolder, alternate: true), sep(),
            .init(.colorTags), .init(.textTagsRatings), sep(),
            .init(.revealInFinder, visible: false), .init(.openInFinder, visible: false),
            .init(.openTerminalAtFolder), .init(.openTerminal), .init(.calculateSize), .init(.sourceControl), .init(.actions), .init(.iconSize), sep(),
            .init(.services),
        ]
    }

    public static func load(_ prefs: Preferences = .shared) -> [ContextMenuEntry] {
        var l = prefs.getJSON("contextMenuOrder", defaults)
        // Append commands added in later versions
        let have = Set(l.compactMap(\.command))
        for d in defaults where d.command != nil && !have.contains(d.command!) { l.append(d) }
        return l
    }

    public static func save(_ l: [ContextMenuEntry], _ prefs: Preferences = .shared) { prefs.setJSON("contextMenuOrder", l) }

    /// Removes leading/trailing/duplicate separators from a resolved list of visible entries.
    public static func collapseSeparators(_ l: [ContextMenuEntry]) -> [ContextMenuEntry] {
        var out: [ContextMenuEntry] = []
        for e in l {
            if e.isSeparator && (out.isEmpty || out.last!.isSeparator) { continue }
            out.append(e)
        }
        while out.last?.isSeparator == true { out.removeLast() }
        return out
    }
}
