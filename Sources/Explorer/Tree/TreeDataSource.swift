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
        func top(_ n: TreeNode, _ s: SidebarSection) -> TreeNode {
            n.isTopLevel = true; n.parent = nil; n.sectionID = s.id
            if n.color == nil { n.color = color(s.colorIndex) }
            return n
        }
        for s in prefs.sidebarSections where !s.disabled {
            switch s.id {
            case "home":
                // The home folder itself is the top-level row; children load lazily.
                let n = TreeNode(.folder(prefs.homeURL), title: "Home", symbol: "house")
                out.append(top(n, s))
            case "hd", "ed", "nd", "idevice", "mtp":
                // Every drive / share / device is its own top-level row (eject buttons where applicable).
                for d in children(ofSection: s.id, network: network) { out.append(top(d, s)) }
            case "icloud":
                guard let u = Volumes.iCloudDrive else { continue }
                let n = TreeBuilder.folderNode(u, title: "iCloud Drive"); n.symbol = "icloud"; n.alwaysExpandable = true
                out.append(top(n, s))
            case "cs":
                let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
                guard FileManager.default.fileExists(atPath: u.path) else { continue }
                let n = TreeBuilder.folderNode(u, title: "Cloud Storage"); n.symbol = "globe.americas"; n.children = []
                out.append(top(n, s))
            case "recent":
                let n = TreeNode(.smart(.recent(days: prefs.recentDays)), title: "Recent Files", symbol: "clock")
                n.children = []
                out.append(top(n, s))
            case "trash":
                let n = TreeNode(.folder(Volumes.userTrash), title: "Trash", symbol: "trash")
                out.append(top(n, s))
            default:
                // Groups with their own children: Favorites, Remote connections, Tags, Star ratings, Saved searches.
                let n = TreeNode(.section(s.id), title: displayTitle(s), symbol: s.icon)
                n.children = children(ofSection: s.id, network: network)
                for c in n.children ?? [] { c.parent = n; c.sectionID = s.id; c.color = c.color ?? color(s.colorIndex) }
                // Empty groups are hidden, as in the original (no remote hosts / ratings / saved searches yet).
                if ["remote", "ratings", "searches"].contains(s.id), n.children?.isEmpty ?? true { continue }
                if s.id == "favorites" { n.color = .systemYellow; n.symbol = "star.fill" }
                out.append(top(n, s))
            }
        }
        return out
    }

    /// Row titles as the original shows them (the Settings labels are more descriptive).
    static func displayTitle(_ s: SidebarSection) -> String {
        switch s.id {
        case "tags": return "Tags"
        case "ratings": return "Star Ratings"
        case "searches": return "Saved Searches"
        case "remote": return "Remote Connections"
        default: return s.label
        }
    }

    static func children(ofSection id: String, network: MountableBrowser?) -> [TreeNode] {
        let prefs = Preferences.shared
        switch id {
        case "favorites":
            // Favorites whose folder was trashed or moved stay in the store (a restore revives them) but are hidden.
            return Favorites.all().compactMap { link in
                let target = Favorites.target(of: link)
                var dir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: target.path, isDirectory: &dir), dir.boolValue else { return nil }
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
        case "mtp":
            return MTPService.shared.devices.map { device in
                let node = TreeNode(.mtp(device.address), title: device.name, symbol: "externaldrive.connected.to.line.below")
                node.loadError = device.errorMessage
                return node
            }
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
            guard RatingsProbe.anyRated else { return [] }
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
        case .accent: return NSColor(named: "AccentColor") ?? .controlAccentColor
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


/// Whether any file has a star rating (Spotlight), refreshed at most once a minute.
enum RatingsProbe {
    nonisolated(unsafe) static var cached: (Date, Bool)?
    static var anyRated: Bool {
        if let c = cached, Date().timeIntervalSince(c.0) < 60 { return c.1 }
        let q = MDQueryCreate(nil, "kMDItemStarRating >= 1" as CFString, nil, nil)
        var found = false
        if let q, MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) { found = MDQueryGetResultCount(q) > 0 }
        cached = (Date(), found)
        return found
    }
}
