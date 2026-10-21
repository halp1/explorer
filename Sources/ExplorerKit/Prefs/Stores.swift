import Foundation

/// Generic JSON-file-backed list store (tab sets, shelf, recent shares, actions...).
public final class JSONStore<T: Codable>: ObservableObject {
    @Published public var items: [T] { didSet { save() } }
    private let file: URL

    public init(file: URL, defaults: [T] = []) {
        self.file = file
        if let d = try? Data(contentsOf: file), let v = try? JSONDecoder().decode([T].self, from: d) {
            items = v
        } else {
            items = defaults
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(items) { try? d.write(to: file, options: .atomic) }
    }
}

// MARK: - Tab sets

public struct SavedTab: Codable, Hashable, Sendable {
    public var path: String
    public var title: String?
    public var colorIndex: Int?
    public init(path: String, title: String? = nil, colorIndex: Int? = nil) { self.path = path; self.title = title; self.colorIndex = colorIndex }
}

public struct TabSet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var tabs: [SavedTab]
    public init(id: UUID = UUID(), name: String, tabs: [SavedTab]) { self.id = id; self.name = name; self.tabs = tabs }
}

public enum TabSetStore {
    public static let shared = JSONStore<TabSet>(file: AppPaths.support.appendingPathComponent("TabSets.json"))
}

// MARK: - Shelf

public struct ShelfEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var bookmark: Data
    public var path: String   // last known path (display + fallback)
    public init(url: URL) {
        id = UUID()
        bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        path = url.path
    }
    /// Resolves the bookmark so items that moved are still found.
    public var url: URL? {
        var stale = false
        if let u = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) { return u }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}

public enum ShelfStore {
    public static let shared = JSONStore<ShelfEntry>(file: AppPaths.support.appendingPathComponent("Shelf.json"))

    public static func add(_ urls: [URL]) {
        let existing = Set(shared.items.compactMap { $0.url?.standardizedFileURL.path })
        let new = urls.filter { !existing.contains($0.standardizedFileURL.path) }.map(ShelfEntry.init)
        shared.items.append(contentsOf: new)
    }

    public static func remove(_ urls: [URL]) {
        let p = Set(urls.map { $0.standardizedFileURL.path })
        shared.items.removeAll { e in e.url.map { p.contains($0.standardizedFileURL.path) } ?? true }
    }
}

// MARK: - Network shares

public struct RecentShare: Codable, Hashable, Identifiable, Sendable {
    public var id: String { url }
    public var url: String       // smb://server/share
    public var pinned: Bool
    public var hidden: Bool
    public var lastMountPath: String?
    public init(url: String, pinned: Bool = false, hidden: Bool = false, lastMountPath: String? = nil) {
        self.url = url; self.pinned = pinned; self.hidden = hidden; self.lastMountPath = lastMountPath
    }
    public var displayName: String {
        guard let u = URL(string: url) else { return url }
        let share = u.lastPathComponent.isEmpty || u.lastPathComponent == "/" ? (u.host ?? url) : u.lastPathComponent
        return share.removingPercentEncoding ?? share
    }
}

public enum RecentSharesStore {
    public static let shared = JSONStore<RecentShare>(file: AppPaths.support.appendingPathComponent("RecentShares.json"))

    public static func remember(_ url: String, mountPath: String?) {
        if let i = shared.items.firstIndex(where: { $0.url == url }) {
            shared.items[i].lastMountPath = mountPath
            shared.items[i].hidden = false
        } else {
            shared.items.insert(RecentShare(url: url, lastMountPath: mountPath), at: 0)
        }
    }
}

// MARK: - Actions

public enum ActionsStore {
    public static let shared = JSONStore<ScriptAction>(file: AppPaths.support.appendingPathComponent("Actions.json"), defaults: ScriptAction.samples)
}

// MARK: - Open With additions

public struct OpenWithAddition: Codable, Hashable, Sendable {
    public var appPath: String
    public var typeIdentifier: String?   // nil = all types
    public init(appPath: String, typeIdentifier: String?) { self.appPath = appPath; self.typeIdentifier = typeIdentifier }
}

public enum OpenWithStore {
    public static let shared = JSONStore<OpenWithAddition>(file: AppPaths.support.appendingPathComponent("OpenWith.json"))
}

// MARK: - Favorites (symlinks in Application Support, like the original)

public enum Favorites {
    public static var folder: URL { AppPaths.favorites }

    public static func all(prefs: Preferences = .shared) -> [URL] {
        let fm = FileManager.default
        let links = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }
        if prefs.reorderFavorites {
            let order = prefs.favoritesOrder
            return links.sorted { a, b in
                let ia = order.firstIndex(of: a.lastPathComponent) ?? Int.max
                let ib = order.firstIndex(of: b.lastPathComponent) ?? Int.max
                if ia != ib { return ia < ib }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        }
        return links.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func target(of link: URL) -> URL {
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            return URL(fileURLWithPath: dest, isDirectory: true)
        }
        return link
    }

    public static func contains(_ url: URL) -> Bool { link(for: url) != nil }

    public static func link(for url: URL) -> URL? {
        let p = url.standardizedFileURL.path
        return all().first { target(of: $0).standardizedFileURL.path == p }
    }

    @discardableResult
    public static func add(_ url: URL, prefs: Preferences = .shared) throws -> URL {
        if let l = link(for: url) { return l }
        let name = url.path == "/" ? "Macintosh HD" : url.lastPathComponent
        let l = FileNaming.uniqueURL(in: folder, name: name)
        try FileManager.default.createSymbolicLink(at: l, withDestinationURL: url)
        var o = prefs.favoritesOrder
        o.append(l.lastPathComponent)
        prefs.favoritesOrder = o
        return l
    }

    public static func remove(_ url: URL, prefs: Preferences = .shared) throws {
        let l = link(for: url) ?? (url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path ? url : nil)
        guard let l else { return }
        try FileManager.default.removeItem(at: l)
        prefs.favoritesOrder = prefs.favoritesOrder.filter { $0 != l.lastPathComponent }
    }

    public static func move(names: [String], to index: Int, prefs: Preferences = .shared) {
        var o = all(prefs: prefs).map(\.lastPathComponent)
        let moving = o.filter { names.contains($0) }
        let before = o.prefix(index).filter { !names.contains($0) }.count
        o.removeAll { names.contains($0) }
        o.insert(contentsOf: moving, at: min(before, o.count))
        prefs.favoritesOrder = o
    }
}
