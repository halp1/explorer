import Foundation

/// What a tab is currently showing.
public enum Location: Hashable, Codable, Sendable {
    case directory(URL)
    /// An archive opened as a folder. `inner` is the entry path inside the archive ("" = root, otherwise "a/b/").
    case archive(URL, inner: String)
    case search(SearchSpec)
    case smart(SmartNode)
    case trash
    /// A folder on a connected iOS device's AFC filesystem.
    case device(udid: String, path: String)

    public var url: URL? {
        switch self {
        case .directory(let u): return u
        case .archive(let u, _): return u
        case .trash: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        default: return nil
        }
    }

    public var isFileSystem: Bool {
        if case .directory = self { return true }
        return false
    }

    public var title: String {
        switch self {
        case .directory(let u): return FileNaming.displayName(of: u)
        case .archive(let u, let inner):
            if inner.isEmpty { return u.lastPathComponent }
            return (inner as NSString).lastPathComponent
        case .search(let s): return String(format: "Searching “%@”", s.text)
        case .smart(let n): return n.title
        case .trash: return "Trash"
        case .device(_, let p): return p == "/" ? "iOS Device" : (p as NSString).lastPathComponent
        }
    }

    /// The location one level up, if any.
    public var parent: Location? {
        switch self {
        case .directory(let u):
            return u.parentDirectory.map { .directory($0) }
        case .archive(let u, let inner):
            if inner.isEmpty { return .directory(u.deletingLastPathComponent()) }
            let trimmed = inner.hasSuffix("/") ? String(inner.dropLast()) : inner
            let up = (trimmed as NSString).deletingLastPathComponent
            return .archive(u, inner: up.isEmpty ? "" : up + "/")
        case .search(let s): return .directory(s.scope)
        case .device(let id, let p):
            guard p != "/" else { return nil }
            let up = (p as NSString).deletingLastPathComponent
            return .device(udid: id, path: up.isEmpty ? "/" : up)
        default: return nil
        }
    }
}

public struct SearchSpec: Hashable, Codable, Sendable {
    public var text: String
    public var scope: URL
    public var useSpotlight: Bool
    public var rawQuery: String?
    public init(text: String, scope: URL, useSpotlight: Bool, rawQuery: String? = nil) {
        self.text = text; self.scope = scope; self.useSpotlight = useSpotlight; self.rawQuery = rawQuery
    }
}

public enum SmartNode: Hashable, Codable, Sendable {
    case recent(days: Int)
    case colorTag(Int)          // 1...7 Finder label number
    case textTag(String)
    case rating(Int)            // 1...5
    case savedSearch(URL)

    public var title: String {
        switch self {
        case .recent: return "Recent Files"
        case .colorTag(let i): return FinderColor(rawValue: i)?.name ?? "Tag"
        case .textTag(let t): return t
        case .rating(let r): return String(repeating: "★", count: r)
        case .savedSearch(let u): return u.deletingPathExtension().lastPathComponent
        }
    }
}

/// Finder label colors, numbered like `URLResourceValues.labelNumber`.
public enum FinderColor: Int, CaseIterable, Codable, Sendable {
    case gray = 1, green, purple, blue, yellow, red, orange
    public var name: String {
        switch self {
        case .gray: return "Gray"; case .green: return "Green"; case .purple: return "Purple"
        case .blue: return "Blue"; case .yellow: return "Yellow"; case .red: return "Red"; case .orange: return "Orange"
        }
    }
    /// Order shown in menus/info panel (like Finder): red, orange, yellow, green, blue, purple, gray.
    public static let menuOrder: [FinderColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]
}
