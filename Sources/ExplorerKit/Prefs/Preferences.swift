import Foundation
import Combine

// MARK: - Enumerated settings

public enum Appearance: String, Codable, CaseIterable, Sendable { case system = "System", light = "Light", dark = "Dark" }
public enum SoundsMode: String, Codable, CaseIterable, Sendable { case inApp = "InApp", system = "System", off = "Off" }
public enum PathBarStyle: String, Codable, CaseIterable, Sendable { case interactive = "Interactive", string = "String" }
public enum PathBarPosition: Int, Codable, CaseIterable, Sendable { case bottom = 0, top = 1 }
public enum ReturnAction: String, Codable, CaseIterable, Sendable { case open = "Open", rename = "Rename" }
public enum DragBehavior: String, Codable, CaseIterable, Sendable { case alwaysMove = "AlwaysMove", finder = "Finder" }
public enum LinkKind: Int, Codable, CaseIterable, Sendable { case symlink = 2, alias = 1 }
public enum OpenArchives: String, Codable, CaseIterable, Sendable { case within = "Within", defaultApp = "DefaultApp" }
public enum ExtensionVisibility: String, Codable, CaseIterable, Sendable { case respectFinder = "Finder", show = "Show", hide = "Hide" }
public enum Truncation: String, Codable, CaseIterable, Sendable {
    case end = "End", middle = "Middle", beginning = "Beginning", none = "None"
    public var title: String {
        switch self { case .end: return "At the end"; case .middle: return "In the middle"; case .beginning: return "At the beginning"; case .none: return "Do not truncate" }
    }
}
public enum ListLayout: String, Codable, CaseIterable, Sendable { case adaptive = "Adaptive", fixed = "Fixed" }
public enum FolderThumbnails: String, Codable, CaseIterable, Sendable {
    case systemIcon = "System", contentGrid = "Grid", contentFan = "Fan"
    public var title: String { switch self { case .systemIcon: return "System icon"; case .contentGrid: return "Content grid"; case .contentFan: return "Content fan" } }
}
public enum ViewKind: String, Codable, CaseIterable, Sendable {
    case icons = "Icons", list = "List", table = "Table", gallery = "Gallery"
    public var title: String { rawValue }
    public var symbol: String {
        switch self { case .icons: return "square.grid.2x2"; case .list: return "list.bullet"; case .table: return "tablecells"; case .gallery: return "rectangle.on.rectangle" }
    }
}
public enum IconSizePreset: Int, Codable, CaseIterable, Sendable {
    case regular = 64, larger = 128, largest = 256
    public var title: String { switch self { case .regular: return "Regular"; case .larger: return "Large"; case .largest: return "Largest" } }
}
public enum ThemeColor: String, Codable, CaseIterable, Sendable {
    case accent = "Accent", blue = "Blue", purple = "Purple", pink = "Pink", red = "Red", orange = "Orange", yellow = "Yellow", green = "Green", graphite = "Graphite"
}

// MARK: - Sidebar sections

public struct SidebarSection: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var colorIndex: Int   // 0 = theme color, 1...N palette
    public var icon: String
    public var disabled: Bool
    public var expandedByDefault: Bool?

    public static let defaults: [SidebarSection] = [
        .init(id: "favorites", label: "Favorites", colorIndex: 7, icon: "star", disabled: false, expandedByDefault: true),
        .init(id: "home", label: "Home", colorIndex: 0, icon: "house", disabled: false, expandedByDefault: true),
        .init(id: "hd", label: "Hard drives", colorIndex: 0, icon: "internaldrive", disabled: false, expandedByDefault: false),
        .init(id: "ed", label: "External drives", colorIndex: 0, icon: "externaldrive", disabled: false, expandedByDefault: false),
        .init(id: "nd", label: "Network shares", colorIndex: 0, icon: "externaldrive.connected.to.line.below", disabled: false, expandedByDefault: false),
        .init(id: "remote", label: "Remote connections", colorIndex: 0, icon: "network", disabled: false, expandedByDefault: false),
        .init(id: "icloud", label: "iCloud Drive folder", colorIndex: 0, icon: "icloud", disabled: false, expandedByDefault: false),
        .init(id: "cs", label: "Cloud storage", colorIndex: 0, icon: "globe.americas", disabled: false, expandedByDefault: false),
        .init(id: "idevice", label: "iOS Devices", colorIndex: 0, icon: "iphone", disabled: false, expandedByDefault: false),
        .init(id: "mtp", label: "MTP Devices", colorIndex: 0, icon: "externaldrive.connected.to.line.below", disabled: false, expandedByDefault: false),
        .init(id: "recent", label: "Recent files", colorIndex: 0, icon: "clock", disabled: false, expandedByDefault: false),
        .init(id: "tags", label: "Tags", colorIndex: 0, icon: "circlebadge.2", disabled: false, expandedByDefault: false),
        .init(id: "ratings", label: "Star ratings", colorIndex: 0, icon: "star.circle", disabled: false, expandedByDefault: false),
        .init(id: "searches", label: "Saved searches", colorIndex: 0, icon: "magnifyingglass", disabled: false, expandedByDefault: false),
        .init(id: "trash", label: "Trash", colorIndex: 0, icon: "trash", disabled: false, expandedByDefault: false),
    ]
}

// MARK: - Table columns

public struct ColumnSetting: Codable, Hashable, Sendable {
    public var order: Int
    public var isHidden: Bool
    public var width: Double
    public init(order: Int, isHidden: Bool, width: Double) { self.order = order; self.isHidden = isHidden; self.width = width }
}

public enum TableColumnID: String, Codable, CaseIterable, Sendable {
    case fileName, dateModified, dateCreated, dateAdded, dateOpened, size, fileType, tags, rating, originalSize, compressedSize, git
    public var title: String {
        switch self {
        case .fileName: return "Name"; case .dateModified: return "Date Modified"; case .dateCreated: return "Date Created"
        case .dateAdded: return "Date Added"; case .dateOpened: return "Date Last Opened"; case .size: return "Size"
        case .fileType: return "Kind"; case .tags: return "Tags"; case .rating: return "Rating"
        case .originalSize: return "Original Size"; case .compressedSize: return "Compressed Size"; case .git: return "Source Control"
        }
    }
    public var sortKey: SortKey? {
        switch self {
        case .fileName: return .name; case .dateModified: return .dateModified; case .dateCreated: return .dateCreated
        case .dateAdded: return .dateAdded; case .dateOpened: return .dateOpened; case .size, .originalSize: return .size
        case .fileType: return .kind; case .tags: return .tags; case .rating: return .rating
        case .compressedSize, .git: return nil
        }
    }
    public static let tableDefaults: [String: ColumnSetting] = [
        "fileName": .init(order: 0, isHidden: false, width: 217), "dateModified": .init(order: 1, isHidden: false, width: 154),
        "size": .init(order: 2, isHidden: false, width: 94), "fileType": .init(order: 3, isHidden: false, width: 131),
        "dateCreated": .init(order: 4, isHidden: true, width: 150), "dateAdded": .init(order: 5, isHidden: true, width: 150),
        "dateOpened": .init(order: 6, isHidden: true, width: 150), "tags": .init(order: 7, isHidden: true, width: 100),
        "rating": .init(order: 8, isHidden: true, width: 80), "git": .init(order: 9, isHidden: true, width: 40),
    ]
    public static let archiveDefaults: [String: ColumnSetting] = [
        "fileName": .init(order: 0, isHidden: false, width: 225), "dateModified": .init(order: 1, isHidden: false, width: 130),
        "originalSize": .init(order: 2, isHidden: false, width: 80), "compressedSize": .init(order: 3, isHidden: false, width: 80),
        "fileType": .init(order: 4, isHidden: false, width: 120),
    ]
}

// MARK: - Preferences store

/// Typed facade over UserDefaults. Observable from SwiftUI; posts `objectWillChange` on every write
/// and when defaults change externally (e.g. iCloud pull).
public final class Preferences: ObservableObject {
    public static let shared = Preferences()
    public let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // Generic accessors
    func get<T>(_ key: String, _ def: T) -> T { (defaults.object(forKey: key) as? T) ?? def }
    func set<T>(_ key: String, _ value: T) { objectWillChange.send(); defaults.set(value, forKey: key) }
    func getEnum<E: RawRepresentable>(_ key: String, _ def: E) -> E { (defaults.object(forKey: key) as? E.RawValue).flatMap(E.init(rawValue:)) ?? def }
    func setEnum<E: RawRepresentable>(_ key: String, _ v: E) { set(key, v.rawValue) }
    public func getJSON<T: Decodable>(_ key: String, _ def: T) -> T {
        guard let d = defaults.data(forKey: key), let v = try? JSONDecoder().decode(T.self, from: d) else { return def }
        return v
    }
    public func setJSON<T: Encodable>(_ key: String, _ v: T) {
        objectWillChange.send()
        defaults.set(try? JSONEncoder().encode(v), forKey: key)
    }

    // MARK: General
    public var appearance: Appearance { get { getEnum("appearance", .system) } set { setEnum("appearance", newValue) } }
    public var themeColor: ThemeColor { get { getEnum("themeColor", .accent) } set { setEnum("themeColor", newValue) } }
    public var fontSizeDelta: Int { get { get("fontSizeDelta", 0) } set { set("fontSizeDelta", newValue) } }
    public var sounds: SoundsMode { get { getEnum("sounds", .inApp) } set { setEnum("sounds", newValue) } }
    public var pathBarStyle: PathBarStyle { get { getEnum("pathBarStyle", .interactive) } set { setEnum("pathBarStyle", newValue) } }
    public var pathBarPosition: PathBarPosition { get { getEnum("pathBarPosition", .top) } set { setEnum("pathBarPosition", newValue) } }
    public var showShelf: Bool { get { get("showShelf", true) } set { set("showShelf", newValue) } }
    public var returnAction: ReturnAction { get { getEnum("returnAction", .open) } set { setEnum("returnAction", newValue) } }
    public var backWithDelete: Bool { get { get("backWithDelete", false) } set { set("backWithDelete", newValue) } }
    public var trashWithDelete: Bool { get { get("trashWithDelete", false) } set { set("trashWithDelete", newValue) } }
    public var goToLastFolder: Bool { get { get("goToLastFolder", false) } set { set("goToLastFolder", newValue) } }
    public var remountPinnedShares: Bool { get { get("remountPinnedShares", false) } set { set("remountPinnedShares", newValue) } }
    public var cutViaTrash: Bool { get { get("cutViaTrash", true) } set { set("cutViaTrash", newValue) } }
    public var internalCutForCloud: Bool { get { get("internalCutForCloud", true) } set { set("internalCutForCloud", newValue) } }
    public var usePrivateTrash: Bool { get { get("usePrivateTrash3", true) } set { set("usePrivateTrash3", newValue) } }
    public var dragBehavior: DragBehavior { get { getEnum("dragBehavior", .alwaysMove) } set { setEnum("dragBehavior", newValue) } }
    public var linking: LinkKind { get { getEnum("linking", .symlink) } set { setEnum("linking", newValue) } }
    public var openArchives: OpenArchives { get { getEnum("openArchives", .within) } set { setEnum("openArchives", newValue) } }
    public var terminalAppPath: String { get { get("terminalAppPath", "/System/Applications/Utilities/Terminal.app") } set { set("terminalAppPath", newValue) } }
    public var inheritViewOptions: Bool { get { get("inheritViewOptions", false) } set { set("inheritViewOptions", newValue) } }
    public var notifyUpdates: Bool { get { get("notifyUpdates", true) } set { set("notifyUpdates", newValue) } }
    public var autoQuit: Bool { get { get("autoQuit", false) } set { set("autoQuit", newValue) } }
    public var restoreLastWindow: Bool { get { get("restoreLastWindow", false) } set { set("restoreLastWindow", newValue) } }
    public var syncWithICloud: Bool { get { get("syncWithICloud", false) } set { set("syncWithICloud", newValue) } }
    public var searchWithSpotlight: Bool { get { get("searchWithSpotlight", true) } set { set("searchWithSpotlight", newValue) } }
    public var persistentThumbnailCache: Bool { get { get("persistentThumbnailCache", false) } set { set("persistentThumbnailCache", newValue) } }
    public var showProgressStripe: Bool { get { get("showProgressStripe", true) } set { set("showProgressStripe", newValue) } }
    public var removeShelfItemsAfterUse: Bool { get { get("removeShelfItemsAfterUse", true) } set { set("removeShelfItemsAfterUse", newValue) } }
    public var warnPasswordArchives: Bool { get { get("warnPasswordArchives", true) } set { set("warnPasswordArchives", newValue) } }
    public var lastCompressFormat: String { get { get("lastCompressFormat", "zip") } set { set("lastCompressFormat", newValue) } }

    // MARK: Folder tree
    public var reorderFavorites: Bool { get { get("reorderFavorites", false) } set { set("reorderFavorites", newValue) } }
    public var showTextTags: Bool { get { get("showTextTags", false) } set { set("showTextTags", newValue) } }
    public var recentDays: Int { get { get("recentDays", 30) } set { set("recentDays", newValue) } }
    public var treeSpacing: Double { get { get("treeSpacing", 2.0) } set { set("treeSpacing", newValue) } }
    public var boldTopLevel: Bool { get { get("boldTopLevel", false) } set { set("boldTopLevel", newValue) } }
    public var truncateFolders: Truncation { get { getEnum("truncateFolders", .end) } set { setEnum("truncateFolders", newValue) } }
    public var showIndentGuides: Bool { get { get("showIndentGuides", false) } set { set("showIndentGuides", newValue) } }
    public var showCustomFolderIcons: Bool { get { get("showCustomFolderIcons", true) } set { set("showCustomFolderIcons", newValue) } }
    public var showFolderLabelColor: Bool { get { get("showFolderLabelColor", true) } set { set("showFolderLabelColor", newValue) } }
    public var foldersInheritColor: Bool { get { get("foldersInheritColor", false) } set { set("foldersInheritColor", newValue) } }
    public var autoScrollTree: Bool { get { get("autoScrollTree", true) } set { set("autoScrollTree", newValue) } }
    public var autoExpandTree: Bool { get { get("autoExpandTree", true) } set { set("autoExpandTree", newValue) } }
    public var shareTreeExpansion: Bool { get { get("shareTreeExpansion", false) } set { set("shareTreeExpansion", newValue) } }
    public var defaultPath: String { get { get("defaultPath", "") } set { set("defaultPath", newValue) } }
    public var homePath: String { get { get("homePath", "") } set { set("homePath", newValue) } }
    public var showHiddenInTree: Bool { get { get("showHiddenDir", false) } set { set("showHiddenDir", newValue) } }
    public var showPackagesInTree: Bool { get { get("showPackages", false) } set { set("showPackages", newValue) } }
    public var showArchivesInTree: Bool { get { get("showZipDir", false) } set { set("showZipDir", newValue) } }
    public var showAppDirectories: Bool { get { get("showAppDirectories", false) } set { set("showAppDirectories", newValue) } }

    // MARK: File views
    public var showExtension: ExtensionVisibility { get { getEnum("showExtension", .respectFinder) } set { setEnum("showExtension", newValue) } }
    public var preferPathNames: Bool { get { get("preferPathNames", false) } set { set("preferPathNames", newValue) } }
    public var truncateFiles: Truncation { get { getEnum("truncateFiles", .middle) } set { setEnum("truncateFiles", newValue) } }
    public var truncateInfoNames: Bool { get { get("truncateInfoNames", false) } set { set("truncateInfoNames", newValue) } }
    public var boldRecentChanges: Bool { get { get("boldRecentChanges", true) } set { set("boldRecentChanges", newValue) } }
    public var dateLength: DateLength { get { getEnum("dateLength", .medium) } set { setEnum("dateLength", newValue) } }
    public var dateMode: DateDisplayMode { get { getEnum("dateMode", .relative) } set { setEnum("dateMode", newValue) } }
    public var rowHeight: Double { get { get("rowHeight", 22.0) } set { set("rowHeight", newValue) } }
    public var alternatingRows: Bool { get { get("alternatingTableBackground", true) } set { set("alternatingTableBackground", newValue) } }
    public var listLayout: ListLayout { get { getEnum("listLayout", .adaptive) } set { setEnum("listLayout", newValue) } }
    public var listSpacing: Double { get { get("listSpacing", 2.0) } set { set("listSpacing", newValue) } }
    public var folderThumbnails: FolderThumbnails { get { getEnum("folderThumbnails", .systemIcon) } set { setEnum("folderThumbnails", newValue) } }
    public var iconSpacing: Double { get { get("iconSpacing", 12.0) } set { set("iconSpacing", newValue) } }
    public var showTimeInDates: Bool { get { get("showTimeInDates", true) } set { set("showTimeInDates", newValue) } }

    // MARK: Window chrome
    public var showSidebar: Bool { get { get("showSidebar", true) } set { set("showSidebar", newValue) } }
    public var showPathBar: Bool { get { get("showPathBar", true) } set { set("showPathBar", newValue) } }
    public var showStatusBar: Bool { get { get("showStatusBar", true) } set { set("showStatusBar", newValue) } }
    public var showActionToolbar: Bool { get { get("showActionToolbar", false) } set { set("showActionToolbar", newValue) } }

    // MARK: Default view options (when a folder has none remembered)
    public var defaultViewOptions: ViewOptions { get { getJSON("defaultViewOptions", ViewOptions()) } set { setJSON("defaultViewOptions", newValue) } }
    public var archiveViewOptions: ViewOptions {
        get { getJSON("archiveViewOptions", ViewOptions(view: .table, sortKey: .dateModified, folders: .first)) }
        set { setJSON("archiveViewOptions", newValue) }
    }

    // MARK: JSON-backed
    public var sidebarSections: [SidebarSection] {
        get {
            var s = getJSON("treeOrderByType2", SidebarSection.defaults)
            // Add any sections introduced later
            for d in SidebarSection.defaults where !s.contains(where: { $0.id == d.id }) { s.append(d) }
            return s
        }
        set { setJSON("treeOrderByType2", newValue) }
    }
    public var tableColumns: [String: ColumnSetting] { get { getJSON("tableSettings", TableColumnID.tableDefaults) } set { setJSON("tableSettings", newValue) } }
    public var archiveColumns: [String: ColumnSetting] { get { getJSON("archiveTableSettings", TableColumnID.archiveDefaults) } set { setJSON("archiveTableSettings", newValue) } }
    public var favoritesOrder: [String] { get { getJSON("favoritesOrder", []) } set { setJSON("favoritesOrder", newValue) } }
    public var history: [String] { get { getJSON("recentFolders", []) } set { setJSON("recentFolders", newValue) } }
    public var hiddenTipIDs: [String] { get { getJSON("hiddenTips", []) } set { setJSON("hiddenTips", newValue) } }

    public func addToHistory(_ path: String) {
        var h = history.filter { $0 != path }
        h.insert(path, at: 0)
        history = Array(h.prefix(10))
    }

    // MARK: Resolved locations
    public var homeURL: URL {
        homePath.isEmpty ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: homePath, isDirectory: true)
    }
    public var defaultURL: URL {
        if !defaultPath.isEmpty, FileManager.default.fileExists(atPath: defaultPath) { return URL(fileURLWithPath: defaultPath, isDirectory: true) }
        if sidebarSections.first(where: { $0.id == "home" })?.disabled == true { return URL(fileURLWithPath: "/", isDirectory: true) }
        return homeURL
    }
}

// MARK: - App Support locations

public enum AppPaths {
    public static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Explorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    public static var favorites: URL { dir("Favorites") }
    public static var privateTrash: URL { dir("Trash") }
    public static var temp: URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("com.halp.explorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    public static var caches: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.halp.explorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func dir(_ name: String) -> URL {
        let u = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
