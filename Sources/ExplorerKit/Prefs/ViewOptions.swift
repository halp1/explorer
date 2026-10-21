import Foundation

/// Per-tab (and optionally per-folder remembered) presentation options.
public struct ViewOptions: Codable, Hashable, Sendable {
    public var view: ViewKind = .table
    public var sortKey: SortKey = .name
    public var sortOrder: SortOrder = .ascending
    public var folders: FolderPlacement = .last
    public var grouping: GroupKey = .none
    public var showHidden: Bool = false
    public var showThumbnails: Bool = true
    public var showInfo: Bool = false
    public var showTraits: Bool = false
    public var iconSize: Int = IconSizePreset.regular.rawValue
    public var liveText: Bool = false

    public init(view: ViewKind = .table, sortKey: SortKey = .name, sortOrder: SortOrder = .ascending,
                folders: FolderPlacement = .last, grouping: GroupKey = .none, showHidden: Bool = false,
                showThumbnails: Bool = true, showInfo: Bool = false) {
        self.view = view; self.sortKey = sortKey; self.sortOrder = sortOrder; self.folders = folders
        self.grouping = grouping; self.showHidden = showHidden; self.showThumbnails = showThumbnails; self.showInfo = showInfo
    }

    enum CodingKeys: String, CodingKey { case view, sortKey, sortOrder, folders, grouping, showHidden, showThumbnails, showInfo, showTraits, iconSize, liveText }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        view = (try? c.decode(ViewKind.self, forKey: .view)) ?? .table
        sortKey = (try? c.decode(SortKey.self, forKey: .sortKey)) ?? .name
        sortOrder = (try? c.decode(SortOrder.self, forKey: .sortOrder)) ?? .ascending
        folders = (try? c.decode(FolderPlacement.self, forKey: .folders)) ?? .last
        grouping = (try? c.decode(GroupKey.self, forKey: .grouping)) ?? .none
        showHidden = (try? c.decode(Bool.self, forKey: .showHidden)) ?? false
        showThumbnails = (try? c.decode(Bool.self, forKey: .showThumbnails)) ?? true
        showInfo = (try? c.decode(Bool.self, forKey: .showInfo)) ?? false
        showTraits = (try? c.decode(Bool.self, forKey: .showTraits)) ?? false
        iconSize = (try? c.decode(Int.self, forKey: .iconSize)) ?? 64
        liveText = (try? c.decode(Bool.self, forKey: .liveText)) ?? false
    }
}

/// Remembered view options per folder path, stored as JSON in Application Support.
public final class ViewOptionsStore {
    public static let shared = ViewOptionsStore(file: AppPaths.support.appendingPathComponent("ViewOptions.json"))

    private let file: URL
    private var map: [String: ViewOptions]
    private let queue = DispatchQueue(label: "ViewOptionsStore")

    public init(file: URL) {
        self.file = file
        if let d = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([String: ViewOptions].self, from: d) {
            map = m
        } else { map = [:] }
    }

    public func isRemembered(_ path: String) -> Bool { map[normalize(path)] != nil }

    /// Remembered options for `path`; with `inherit`, the nearest remembered ancestor applies too.
    public func options(for path: String, inherit: Bool) -> ViewOptions? {
        var p = normalize(path)
        if let o = map[p] { return o }
        guard inherit else { return nil }
        for _ in 0..<4096 where p != "/" && !p.isEmpty {
            p = (p as NSString).deletingLastPathComponent
            if let o = map[p] { return o }
        }
        return nil
    }

    /// The folder whose remembered options apply to `path` (itself or an ancestor).
    public func rememberingFolder(for path: String, inherit: Bool) -> String? {
        var p = normalize(path)
        if map[p] != nil { return p }
        guard inherit else { return nil }
        for _ in 0..<4096 where p != "/" && !p.isEmpty {
            p = (p as NSString).deletingLastPathComponent
            if map[p] != nil { return p }
        }
        return nil
    }

    public func remember(_ o: ViewOptions, for path: String) { map[normalize(path)] = o; save() }
    public func forget(_ path: String) { map.removeValue(forKey: normalize(path)); save() }
    public func forgetAll() { map.removeAll(); save() }
    public var count: Int { map.count }

    private func normalize(_ p: String) -> String {
        var s = (p as NSString).standardizingPath
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func save() {
        let snapshot = map
        let file = file
        queue.async {
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: file, options: .atomic) }
        }
    }
}
