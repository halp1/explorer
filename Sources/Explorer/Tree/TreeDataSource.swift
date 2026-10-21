import AppKit
import ExplorerKit

/// Builds Folder Tree sections and lazily loads folder children.
enum TreeBuilder {
    static let palette: [NSColor] = [.controlAccentColor, .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal,
                                     .systemBlue, .systemPurple, .systemPink, .systemBrown, .systemGray]

    static func color(_ index: Int) -> NSColor {
        if index == 0 { return ThemeColors.theme }
        return palette.indices.contains(index) ? palette[index] : ThemeColors.theme
    }

    static func sections(network: MountableBrowser?) -> [TreeNode] {
        let prefs = Preferences.shared
        var out: [TreeNode] = []
        for s in prefs.sidebarSections where !s.disabled {
            let n: TreeNode
            if s.id == "home" {
                n = TreeNode(.folder(prefs.homeURL), title: s.label, symbol: s.icon)
                n.children = nil
            } else {
                n = TreeNode(.section(s.id), title: s.label, symbol: s.icon)
            }
            n.isTopLevel = true
            n.color = color(s.colorIndex)
            n.sectionID = s.id
            if s.id != "home" { n.children = children(ofSection: s.id, network: network) }
            if s.id == "hd" || s.id == "ed" {
                // Flatten: each drive becomes a top-level node of its own.
                for d in n.children ?? [] {
                    d.isTopLevel = true; d.parent = nil; d.sectionID = s.id; d.color = color(s.colorIndex)
                    out.append(d)
                }
                continue
            }
            for c in n.children ?? [] { c.parent = n; c.sectionID = s.id; c.color = c.color ?? n.color }
            // Hide empty device-type sections like the original (no external drives → no node)
            if ["ed", "nd", "idevice", "cs", "remote"].contains(s.id), n.children?.isEmpty ?? true { continue }
            if s.id == "favorites" { n.color = .systemYellow; n.symbol = "star.fill" }
            out.append(n)
        }
        return out
    }

    static func children(ofSection id: String, network: MountableBrowser?) -> [TreeNode] {
        let prefs = Preferences.shared
        switch id {
        case "favorites":
            return Favorites.all().map { link in
                let target = Favorites.target(of: link)
                let n = folderNode(target, title: link.lastPathComponent)
                n.isFavorite = true
                return n
            }
        case "home":
            // The section node itself is the home folder (selectable); its children are loaded lazily.
            return []
        case "hd":
            return Volumes.internalDrives().map { volumeNode($0, symbol: "internaldrive") }
        case "ed":
            return Volumes.externalDrives().map { volumeNode($0, symbol: "externaldrive") }
        case "nd":
            var nodes = Volumes.networkVolumes().map { volumeNode($0, symbol: "externaldrive.connected.to.line.below") }
            let mountedPaths = Set(nodes.compactMap { $0.url?.path })
            for s in RecentSharesStore.shared.items where s.pinned && !s.hidden {
                if let mp = NetworkMounter.mountPoint(for: s.url), mountedPaths.contains(mp.path) { continue }
                let n = TreeNode(.share(s), title: s.displayName, symbol: "externaldrive.badge.xmark")
                nodes.append(n)
            }
            nodes.removeAll { n in
                guard let u = n.url else { return false }
                return RecentSharesStore.shared.items.contains { $0.hidden && NetworkMounter.mountPoint(for: $0.url)?.path == u.path }
            }
            return nodes
        case "remote":
            return (network?.services ?? []).compactMap { s in
                guard let u = MountableBrowser.url(for: s) else { return nil }
                return TreeNode(.remoteHost(s.name, u), title: s.name, symbol: s.scheme == .smb ? "pc" : "server.rack")
            }
        case "icloud":
            guard let u = Volumes.iCloudDrive else { return [] }
            let n = folderNode(u, title: "iCloud Drive")
            n.symbol = "icloud"
            return [n]
        case "cs":
            return Volumes.cloudStorage.map { u in
                let n = folderNode(u, title: FileNaming.displayName(of: u))
                n.symbol = "cloud"
                return n
            }
        case "idevice":
            return IDeviceRegistry.shared.treeNodes()
        case "recent":
            let n = TreeNode(.smart(.recent(days: prefs.recentDays)), title: "Recent Files", symbol: "clock")
            return [n]
        case "tags":
            var nodes = FinderColor.menuOrder.map { c -> TreeNode in
                let n = TreeNode(.smart(.colorTag(c.rawValue)), title: c.name, symbol: "circle.fill")
                n.color = ItemStyle.labelColor(c.rawValue)
                return n
            }
            if prefs.showTextTags {
                nodes += Metadata.knownTextTags().map { TreeNode(.smart(.textTag($0)), title: $0, symbol: "tag") }
            }
            return nodes
        case "ratings":
            return (1...5).reversed().map { r in
                TreeNode(.smart(.rating(r)), title: String(repeating: "★", count: r) + String(repeating: "☆", count: 5 - r), symbol: "star")
            }
        case "searches":
            return SavedSearchFile.all().map { TreeNode(.smart(.savedSearch($0)), title: $0.deletingPathExtension().lastPathComponent, symbol: "magnifyingglass") }
        case "trash":
            return [TreeNode(.trash, title: "Trash", symbol: "trash")]
        default:
            return []
        }
    }

    /// Symbols the original uses for well-known folders.
    static func specialSymbol(_ u: URL) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let p = u.standardizedFileURL.path
        switch p {
        case "/Applications", home + "/Applications": return "a.square"
        case home + "/Desktop": return "menubar.dock.rectangle"
        case home + "/Documents": return "doc.on.doc"
        case home + "/Downloads": return "arrow.down.circle"
        case home + "/Movies": return "film"
        case home + "/Music": return "music.note.list"
        case home + "/Pictures": return "photo"
        case home + "/Public": return "figure.walk.diamond"
        case home: return "house"
        default: return nil
        }
    }

    static func folderNode(_ u: URL, title: String? = nil) -> TreeNode {
        let n = TreeNode(.folder(u), title: title ?? FileNaming.displayName(of: u, preferPathNames: Preferences.shared.preferPathNames))
        n.symbol = specialSymbol(u)
        if Preferences.shared.showFolderLabelColor,
           let ln = try? u.resourceValues(forKeys: [.labelNumberKey]).labelNumber, ln > 0 {
            n.labelColor = ItemStyle.labelColor(ln)
        }
        return n
    }

    static func volumeNode(_ v: VolumeInfo, symbol: String) -> TreeNode {
        let n = folderNode(v.url, title: v.name)
        n.symbol = symbol
        n.isVolume = true
        n.ejectable = v.isEjectable || v.isRemovable || v.isNetwork
        return n
    }

    /// Loads subfolders (and optionally archives/packages) of a folder node.
    static func loadChildren(_ node: TreeNode) {
        let prefs = Preferences.shared
        switch node.kind {
        case .folder(let u) where IDeviceRegistry.parseVirtual(u) != nil:
            let (udid, path) = IDeviceRegistry.parseVirtual(u)!
            let items = (try? IDeviceRegistry.shared.list(udid: udid, path: path)) ?? []
            node.children = items.filter(\.isDirectory).map { it in
                let n = TreeNode(.folder(it.url), title: it.name)
                n.parent = node; n.sectionID = node.sectionID
                return n
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .folder(let u):
            let opts: FileManager.DirectoryEnumerationOptions = prefs.showHiddenInTree ? [] : [.skipsHiddenFiles]
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .localizedNameKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: keys, options: opts)) ?? []
            var kids: [TreeNode] = []
            for c in urls {
                let v = try? c.resourceValues(forKeys: Set(keys))
                var isDir = v?.isDirectory ?? false
                if v?.isSymbolicLink == true {
                    var d: ObjCBool = false
                    isDir = FileManager.default.fileExists(atPath: c.path, isDirectory: &d) && d.boolValue
                }
                if isDir {
                    if v?.isPackage == true && !prefs.showPackagesInTree { continue }
                    let n = folderNode(c)
                    n.parent = node; n.sectionID = node.sectionID; n.color = prefs.foldersInheritColor ? node.color : nil
                    kids.append(n)
                } else if prefs.showArchivesInTree, let f = ArchiveFormat.detect(fileName: c.lastPathComponent), !f.isSingleStream {
                    let n = TreeNode(.archiveDir(c, ""), title: c.lastPathComponent, symbol: "archivebox")
                    n.parent = node; n.sectionID = node.sectionID
                    kids.append(n)
                }
            }
            node.children = kids.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .archiveDir(let u, let inner):
            guard let a = try? Archive(url: u), (try? a.load()) != nil else { node.children = []; return }
            node.children = a.children(of: inner).filter(\.isDirectory).map { e in
                let n = TreeNode(.archiveDir(u, e.path), title: e.name, symbol: "folder")
                n.parent = node; n.sectionID = node.sectionID
                return n
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        default:
            break
        }
    }
}

enum ThemeColors {
    static var theme: NSColor {
        switch Preferences.shared.themeColor {
        case .accent: return .controlAccentColor
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .graphite: return .systemGray
        }
    }
}
