import AppKit
import ExplorerKit

/// A node in the Folder Tree.
final class TreeNode: NSObject {
    enum Kind: Equatable {
        case section(String)                 // top-level unselectable group (id)
        case folder(URL)                     // navigable directory
        case archiveDir(URL, String)         // archive (or folder inside one) shown in tree
        case smart(SmartNode)
        case trash
        case share(RecentShare)              // pinned, unmounted network share
        case remoteHost(String, URL)         // discovered server
        case placeholder(String)             // e.g. "No recent network shares"
    }

    let kind: Kind
    var title: String
    var symbol: String?
    var image: NSImage?
    var color: NSColor?
    weak var parent: TreeNode?
    var children: [TreeNode]?   // nil = not loaded yet
    var isTopLevel = false
    var isFavorite = false
    var isVolume = false
    var ejectable = false
    var sectionID: String?
    var labelColor: NSColor?

    init(_ kind: Kind, title: String, symbol: String? = nil) {
        self.kind = kind; self.title = title; self.symbol = symbol
    }

    var url: URL? {
        switch kind {
        case .folder(let u): return u
        case .archiveDir(let u, _): return u
        case .trash: return Volumes.userTrash
        default: return nil
        }
    }

    var location: Location? {
        switch kind {
        case .folder(let u):
            if let (udid, path) = IDeviceRegistry.parseVirtual(u) { return .device(udid: udid, path: path) }
            return .directory(u)
        case .archiveDir(let u, let inner): return .archive(u, inner: inner)
        case .smart(let n): return .smart(n)
        case .trash: return .trash
        default: return nil
        }
    }

    var isNodeSelectable: Bool { location != nil || { if case .share = kind { return true }; if case .remoteHost = kind { return true }; return false }() }

    var isExpandable: Bool {
        switch kind {
        case .section: return true
        case .folder(let u):
            if let c = children { return !c.isEmpty }
            if IDeviceRegistry.parseVirtual(u) != nil { return true }
            return TreeNode.hasSubfolders(u)
        case .archiveDir: return children.map { !$0.isEmpty } ?? true
        default: return false
        }
    }

    /// Cheap check whether a directory has any visible subfolder (cached per path for a short time).
    static var subfolderCache: [String: (Bool, Date)] = [:]
    static func hasSubfolders(_ u: URL) -> Bool {
        if let c = subfolderCache[u.path], Date().timeIntervalSince(c.1) < 5 { return c.0 }
        let prefs = Preferences.shared
        var result = false
        if let e = try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: prefs.showHiddenInTree ? [] : [.skipsHiddenFiles]) {
            for c in e.prefix(4000) {
                let v = try? c.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if v?.isDirectory == true && (v?.isPackage != true || prefs.showPackagesInTree) { result = true; break }
                if prefs.showArchivesInTree, ArchiveFormat.detect(fileName: c.lastPathComponent) != nil { result = true; break }
            }
        }
        subfolderCache[u.path] = (result, Date())
        return result
    }

    var identity: String {
        switch kind {
        case .section(let id): return "s:" + id
        case .folder(let u): return (sectionID ?? "") + ":" + u.standardizedFileURL.path
        case .archiveDir(let u, let i): return "a:" + u.path + "#" + i
        case .smart(let n): return "m:\(n)"
        case .trash: return "trash"
        case .share(let s): return "share:" + s.url
        case .remoteHost(let n, _): return "host:" + n
        case .placeholder(let t): return "p:" + t
        }
    }
}
